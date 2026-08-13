-- World: owns the tick loop, the actor registry, grass patches, chat pairing,
-- collision sweeps, respawn hysteresis, and rendering flushes.

local actor_mod = require("pokemon.actor")
local config = require("pokemon.config")
local grid_mod = require("pokemon.grid")
local sprites = require("pokemon.sprites")
local util = require("pokemon.util")

local M = {}

-- Image id space: keep far away from other kitty-graphics plugins
-- (snacks.image etc. allocate small ids).
local ID_BASE = 210000
local ID_SHINY_OFFSET = 1000
local IMG_GRASS = ID_BASE + 9000
local IMG_EMOTE = { angry = ID_BASE + 9001, chat = ID_BASE + 9002, note = ID_BASE + 9003 }
-- emote placements live on the emote images keyed by actor id; grass
-- placements live on the grass image keyed by patch id

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

local state = {
  running = false,
  backend = nil,
  backend_name = nil,
  actors = {},
  grass_tiles = {}, -- key (r*1000+c) -> { r, c, frame }
  grid = nil,
  grid_dirty = true,
  tick_count = 0,
  timer = nil,
  pause_reasons = {},
  chat_cooldown = {}, -- "id:id" -> tick when allowed again
  respawn_queue = {}, -- { dex, shiny, candidate = {r,c}|nil }
  perf = { ticks = 0, total_ms = 0, max_ms = 0, rebuild_ms = 0, rebuilds = 0 },
}
M.state = state

local function fp()
  return config.footprint()
end

local function image_id_for(dex, shiny)
  return ID_BASE + dex + (shiny and ID_SHINY_OFFSET or 0)
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Is (r, c) clear of every *other* actor's footprint (and grass is fine to
--- walk through, so grass is ignored)?
function M:spot_clear(who, r, c)
  local rect = { r = r, c = c, w = who and who.w or fp().w, h = who and who.h or fp().h }
  for _, a in ipairs(state.actors) do
    if a ~= who and a.state ~= actor_mod.STATES.GONE then
      if util.rect_gap(rect, a:rect()) == 0 and util.rects_overlap(rect, a:rect()) then
        return false
      end
    end
  end
  return true
end

local function live_actors()
  return vim.tbl_filter(function(a)
    return a.state ~= actor_mod.STATES.GONE
  end, state.actors)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function sprite_cells()
  local f = fp()
  return { w = f.w, h = f.h }
end

--- Emotes scale with the sprite: half the footprint (the classic 4x2 sprite
--- had a 2x1 emote). The PNG is square, so kitty letterboxes it inside.
local function emote_cells(a)
  return { w = math.max(2, math.ceil(a.w / 2)), h = math.max(1, math.ceil(a.h / 2)) }
end

local function emote_pos(a)
  local e = emote_cells(a)
  local c = util.clamp(a.pos.c + math.floor((a.w - e.w) / 2), 1, vim.o.columns - e.w)
  if a.pos.r > e.h then
    return { r = a.pos.r - e.h, c = c } -- directly above the head
  end
  return { r = a.pos.r + a.h, c = c } -- no room above: show below
end

local function ops_for_actor(a, ops)
  local b = state.backend
  if a.state == actor_mod.STATES.GONE then
    ops[#ops + 1] = { kind = "delete", image_id = a.image_id, placement_id = a.id }
    for _, img in pairs(IMG_EMOTE) do
      ops[#ops + 1] = { kind = "delete", image_id = img, placement_id = a.id }
    end
    return
  end
  ops[#ops + 1] = {
    kind = "place",
    image_id = a.image_id,
    placement_id = a.id,
    pos = a.pos,
    rect = sprites.frame_rect(a.dir, a.frame),
    cells = sprite_cells(),
    z = b.Z_POKEMON,
    direction = a.dir, -- used by the float backend only
  }
  for kind, img in pairs(IMG_EMOTE) do
    if a.emote and a.emote.kind == kind then
      b.ensure_image(img, plugin_root .. "/assets/emotes/" .. kind .. ".png")
      ops[#ops + 1] = {
        kind = "place",
        image_id = img,
        placement_id = a.id,
        pos = emote_pos(a),
        rect = { x = 0, y = 0, w = 32, h = 32 },
        cells = emote_cells(a),
        z = b.Z_EMOTE,
        emote = kind,
      }
    else
      ops[#ops + 1] = { kind = "delete", image_id = img, placement_id = a.id }
    end
  end
end

-- ---------------------------------------------------------------------------
-- Tall grass field
--
-- The region below each window's last line grows route-style grass patches.
-- The layout is a PURE FUNCTION of (session seed, zone shape): two-octave
-- hash noise — coarse super-cells form the rectangular route-like clumps,
-- a fine per-tile hash roughens their edges. Nothing is remembered between
-- rebuilds, so tiles near growing text vanish and the same tiles grow back
-- when the space returns; text and grass can never overlap.
-- ---------------------------------------------------------------------------

-- DPPt tall grass sheet: frame 0 = still, frame 1 = rustle (blades splayed)
local GRASS_FRAME_W, GRASS_FRAME_H = 22, 20
local GRASS_W, GRASS_H = 2, 1 -- one tile = 2x1 cells (~square on screen)
local grass_seed = nil

-- proper avalanche mixing (xorshift-style): a plain multiplicative hash
-- correlates along diagonals, which reads as diagonal streaks in the field
local bit = require("bit")
local function site_hash(a, b, salt)
  local h = bit.tobit(a * 374761393 + b * 668265263 + salt * 951274213 + grass_seed)
  h = bit.bxor(h, bit.rshift(h, 13))
  h = bit.tobit(h * 40503)
  h = bit.bxor(h, bit.rshift(h, 15))
  return bit.band(h, 0xffff) / 65536
end

local function grass_key(r, c)
  return r * 1000 + c
end

local function place_grass_tile(key, tile, ops)
  local b = state.backend
  b.ensure_image(IMG_GRASS, plugin_root .. "/assets/grass.png")
  ops[#ops + 1] = {
    kind = "place",
    image_id = IMG_GRASS,
    placement_id = key,
    pos = { r = tile.r, c = tile.c },
    rect = { x = (tile.frame or 0) * GRASS_FRAME_W, y = 0, w = GRASS_FRAME_W, h = GRASS_FRAME_H },
    cells = { w = GRASS_W, h = GRASS_H },
    z = b.Z_GRASS,
    emote = "grass", -- float backend fallback art; cosmetic only
  }
end

--- The tile set the current zone SHOULD have (deterministic).
local function desired_grass_tiles(grid)
  local out = {}
  local cfg = config.options.grass
  if not (cfg.enabled and state.backend and state.backend.GRASS) then
    return out
  end
  if not grass_seed then
    grass_seed = util.rand(1048573)
  end
  local density = cfg.density or 0.55
  -- grass lives only in the bottom `zone` fraction of each window's empty
  -- space — if the gap below the last line is x rows, only the deepest
  -- 40% (by default) may grow anything
  local min_depth = 1 - (cfg.zone or 0.4)
  for r = 1, grid.rows do
    for c = 1, grid.cols - GRASS_W + 1, GRASS_W do
      local da = grid:below_depth(r, c)
      local db = grid:below_depth(r, c + GRASS_W - 1)
      if
        da
        and db
        and da > min_depth
        and db > min_depth
        -- plus the usual side margins from any text (2 rows / 6 cols)
        and grid:clear_margin(r, c, GRASS_W, GRASS_H, 2, 6)
      then
        -- coarse clumps (~10x3 cell super-cells), mostly solid inside with
        -- the occasional gap — like the rectangular patches on real routes
        local clump = site_hash(math.floor(r / 3), math.floor(c / 10), 1)
        if clump < density and site_hash(r, c, 2) < 0.92 then
          out[grass_key(r, c)] = { r = r, c = c, frame = 0 }
        end
      end
    end
  end
  return out
end

--- Diff current tiles against the desired set; emit place/delete ops.
local function grass_sync(ops)
  local desired = desired_grass_tiles(state.grid)
  for key in pairs(state.grass_tiles) do
    if not desired[key] then
      ops[#ops + 1] = { kind = "delete", image_id = IMG_GRASS, placement_id = key }
      state.grass_tiles[key] = nil
    end
  end
  for key, tile in pairs(desired) do
    if not state.grass_tiles[key] then
      state.grass_tiles[key] = tile
      place_grass_tile(key, tile, ops)
    end
  end
end

--- Tiles under a pokemon shake at 4Hz, like the gen 4 encounter grass.
local function grass_rustle(ops)
  if next(state.grass_tiles) == nil then
    return
  end
  local shaking = {}
  for _, a in ipairs(state.actors) do
    if a.state ~= actor_mod.STATES.GONE then
      for rr = a.pos.r, a.pos.r + a.h - 1 do
        for cc = a.pos.c - (GRASS_W - 1), a.pos.c + a.w - 1 do
          local key = grass_key(rr, cc)
          if state.grass_tiles[key] then
            shaking[key] = true
          end
        end
      end
    end
  end
  local shake_frame = math.floor(state.tick_count / 2) % 2
  for key, tile in pairs(state.grass_tiles) do
    local frame = shaking[key] and shake_frame or 0
    if frame ~= tile.frame then
      tile.frame = frame
      place_grass_tile(key, tile, ops)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------------

local function spawn_actor(dex, shiny, at)
  local f = fp()
  local a = actor_mod.new(dex, shiny, image_id_for(dex, shiny), at, f)
  state.backend.ensure_image(a.image_id, sprites.sheet_path(dex, shiny))
  state.actors[#state.actors + 1] = a
  a.dirty = true
  return a
end

--- Choose a good spawn spot: free footprint in a roomy region. Bounded
--- random sampling — region_size flood-fills every candidate would stall the
--- tick for tens of ms on large terminals.
local function find_spawn_spot(grid)
  local f = fp()
  local candidates = grid:free_positions(f.w, f.h, 3)
  local fallback
  for _ = 1, 25 do
    local p = util.pick(candidates)
    if p and M:spot_clear(nil, p.r, p.c) then
      fallback = fallback or p
      if grid:region_size(p.r, p.c, 80) >= f.w * f.h * 5 then
        return p
      end
    end
  end
  return fallback
end

--- Public: spawn one pokemon by name/dex (random installed if nil).
function M.spawn(id, opts)
  opts = opts or {}
  if #live_actors() >= config.options.max_actors then
    vim.notify("pokemon.nvim: max_actors reached", vim.log.levels.WARN)
    return
  end

  local resolved
  if id then
    resolved = sprites.resolve(id)
    if not resolved then
      vim.notify(("pokemon.nvim: unknown pokemon %q"):format(id), vim.log.levels.ERROR)
      return
    end
  else
    local installed = sprites.installed()
    if #installed == 0 then
      vim.notify("pokemon.nvim: no sprites installed — :Pokemon install gen4", vim.log.levels.WARN)
      return
    end
    resolved = { dex = util.pick(installed) }
  end

  local shiny = opts.shiny
  if shiny == nil then
    shiny = sprites.roll_shiny(config.options.shiny)
  end
  -- the upstream source is incomplete: swap variant when only the other
  -- exists (the legendary birds have shiny-only sheets), error when neither
  if not sprites.is_available(resolved.dex, shiny) then
    if sprites.is_available(resolved.dex, not shiny) then
      shiny = not shiny
    else
      vim.notify(
        ("pokemon.nvim: no sheet for %s — the sprite source is missing it (mostly legendaries)"):format(
          sprites.name_of(resolved.dex)
        ),
        vim.log.levels.ERROR
      )
      return
    end
  end

  local function do_spawn()
    if not state.running then
      return
    end
    state.grid = state.grid or grid_mod.build()
    local at = find_spawn_spot(state.grid)
    if not at then
      -- no room right now; let the respawn scanner find space later
      state.respawn_queue[#state.respawn_queue + 1] = { dex = resolved.dex, shiny = shiny }
      return
    end
    spawn_actor(resolved.dex, shiny, at)
  end

  if sprites.is_installed(resolved.dex, shiny) then
    do_spawn()
  else
    sprites.install({ { dex = resolved.dex, shiny = shiny } }, function(ok_n, fail_n)
      if fail_n > 0 then
        vim.notify(
          ("pokemon.nvim: failed to download sprite #%d (offline?)"):format(resolved.dex),
          vim.log.levels.ERROR
        )
        return
      end
      do_spawn()
    end)
  end
end

function M.despawn(id)
  if not state.backend then
    return -- world never started; nothing can be on screen
  end
  local ops = {}
  for _, a in ipairs(state.actors) do
    if id == nil or a.name == tostring(id):lower() or tostring(a.dex) == tostring(id) then
      a.state = actor_mod.STATES.GONE
      ops_for_actor(a, ops)
    end
  end
  state.backend.flush(ops)
  state.actors = vim.tbl_filter(function(a)
    return a.state ~= actor_mod.STATES.GONE
  end, state.actors)
end

-- ---------------------------------------------------------------------------
-- Chat pairing
-- ---------------------------------------------------------------------------

local function pair_key(a, b)
  return math.min(a.id, b.id) .. ":" .. math.max(a.id, b.id)
end

local function chat_scan(ctx)
  local cfg = config.options.chat
  local live = live_actors()
  for i = 1, #live do
    for j = i + 1, #live do
      local a, b = live[i], live[j]
      if
        a.state == actor_mod.STATES.WANDER
        and b.state == actor_mod.STATES.WANDER
        and util.rect_gap(a:rect(), b:rect()) <= 1
        and (state.chat_cooldown[pair_key(a, b)] or 0) <= state.tick_count
        and util.chance(cfg.chance)
      then
        local kind_a = util.chance(0.25) and "note" or "chat"
        a:chat_with(b, ctx, kind_a)
        b:chat_with(a, ctx, "chat")
        state.chat_cooldown[pair_key(a, b)] = state.tick_count + math.floor(cfg.cooldown_sec * config.options.fps)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Collision + respawn
-- ---------------------------------------------------------------------------

local function collision_sweep(ctx)
  for _, a in ipairs(state.actors) do
    if a.state ~= actor_mod.STATES.GONE and not ctx.grid:fits(a.pos.r, a.pos.c, a.w, a.h) then
      local result = a:push(ctx)
      if result == "gone" then
        state.respawn_queue[#state.respawn_queue + 1] = { dex = a.dex, shiny = a.shiny }
      end
    end
  end
end

local function respawn_scan()
  if #state.respawn_queue == 0 or state.tick_count % 16 ~= 7 then
    return
  end
  local f = fp()
  local remaining = {}
  for _, item in ipairs(state.respawn_queue) do
    local spawned = false
    -- hysteresis: only respawn where the same spot was free on the previous
    -- scan too — space must be stable, not a gap mid-keystroke. Queued items
    -- also respect max_actors (the user may have spawned up to the cap since).
    if
      item.candidate
      and #live_actors() < config.options.max_actors
      and state.grid:fits(item.candidate.r, item.candidate.c, f.w, f.h)
      and M:spot_clear(nil, item.candidate.r, item.candidate.c)
    then
      spawn_actor(item.dex, item.shiny, item.candidate)
      spawned = true
    else
      item.candidate = find_spawn_spot(state.grid)
    end
    if not spawned then
      remaining[#remaining + 1] = item
    end
  end
  state.respawn_queue = remaining
end

-- ---------------------------------------------------------------------------
-- Tick loop
-- ---------------------------------------------------------------------------

local function tick()
  if not state.running or next(state.pause_reasons) ~= nil then
    return
  end
  state.tick_count = state.tick_count + 1
  local t0 = vim.uv.hrtime()

  local rebuilt = false
  if state.grid_dirty or not state.grid then
    local tb = vim.uv.hrtime()
    state.grid = grid_mod.build()
    state.perf.rebuild_ms = state.perf.rebuild_ms + (vim.uv.hrtime() - tb) / 1e6
    state.perf.rebuilds = state.perf.rebuilds + 1
    state.grid_dirty = false
    rebuilt = true
  end

  local ctx = { grid = state.grid, cfg = config.options, world = M }

  collision_sweep(ctx)
  chat_scan(ctx)
  for _, a in ipairs(state.actors) do
    a:tick(ctx)
  end
  respawn_scan()

  local ops = {}
  if rebuilt then
    grass_sync(ops) -- the field only changes when the layout does
  end
  grass_rustle(ops)
  for _, a in ipairs(state.actors) do
    if a.dirty then
      ops_for_actor(a, ops)
      a.dirty = false
    end
  end
  state.backend.flush(ops)

  -- drop GONE actors only AFTER their delete ops flushed (dropping earlier —
  -- e.g. in respawn_scan — leaves a ghost placement on screen forever)
  for i = #state.actors, 1, -1 do
    if state.actors[i].state == actor_mod.STATES.GONE then
      table.remove(state.actors, i)
    end
  end

  local ms = (vim.uv.hrtime() - t0) / 1e6
  state.perf.ticks = state.perf.ticks + 1
  state.perf.total_ms = state.perf.total_ms + ms
  state.perf.max_ms = math.max(state.perf.max_ms, ms)
end

-- ---------------------------------------------------------------------------
-- External events (wired from init.lua)
-- ---------------------------------------------------------------------------

function M.mark_dirty()
  state.grid_dirty = true
end

--- Layout-change fast-path (scrolls AND text edits). Text moves instantly
--- but our placements are screen-anchored, so waiting for debounce + next
--- tick leaves grass (and pokemon) floating over changed text for ~200ms.
--- Resync immediately, throttled to 50ms; the debounced rebuild still
--- follows as a safety net.
local last_resync_ms = 0
function M.resync()
  if not state.running or next(state.pause_reasons) ~= nil then
    return
  end
  local now = vim.uv.now()
  if now - last_resync_ms < 50 then
    state.grid_dirty = true
    return
  end
  last_resync_ms = now

  state.grid = grid_mod.build()
  state.grid_dirty = false
  local ctx = { grid = state.grid, cfg = config.options, world = M }
  collision_sweep(ctx)
  local ops = {}
  grass_sync(ops)
  for _, a in ipairs(state.actors) do
    if a.dirty then
      ops_for_actor(a, ops)
      a.dirty = false
    end
  end
  state.backend.flush(ops)
end

--- Immediate reaction to typing: patch the grid for the cursor line only and
--- push anyone standing there. The full rebuild follows via debounce.
function M.on_typing()
  if not state.running or not state.grid or #state.actors == 0 then
    return
  end
  -- cheap precheck: skip the O(line) patch when no actor is anywhere near the
  -- cursor's screen row (the overwhelmingly common case, every keystroke)
  local wpos = vim.api.nvim_win_get_position(0)
  local crow = wpos[1] + vim.fn.winline()
  local near = false
  for _, a in ipairs(state.actors) do
    if a.state ~= actor_mod.STATES.GONE and crow >= a.pos.r - 1 and crow <= a.pos.r + a.h then
      near = true
      break
    end
  end
  if not near then
    return
  end
  local invaded = grid_mod.patch_cursor_line(state.grid)
  if not invaded then
    return
  end
  local ctx = { grid = state.grid, cfg = config.options, world = M }
  local ops = {}
  for _, a in ipairs(state.actors) do
    if a.state ~= actor_mod.STATES.GONE and util.rects_overlap(invaded, a:rect()) then
      local result = a:push(ctx)
      if result == "gone" then
        state.respawn_queue[#state.respawn_queue + 1] = { dex = a.dex, shiny = a.shiny }
      end
      ops_for_actor(a, ops)
      a.dirty = false
    end
  end
  state.backend.flush(ops)
end

function M.pause(reason)
  state.pause_reasons[reason] = true
end

function M.resume(reason)
  state.pause_reasons[reason] = nil
end

--- Runtime grass switch. grass_sync diffs against the desired set, and with
--- enabled=false the desired set is empty — so flipping the flag and forcing
--- a resync places or clears the whole field.
function M.toggle_grass()
  local cfg = config.options.grass
  cfg.enabled = not cfg.enabled
  M.resync()
  vim.notify("pokemon.nvim: grass " .. (cfg.enabled and "on" or "off"))
end

--- Cmdline: the kitty backend keeps running (its flush is pure escape bytes
--- from the main loop — no nvim window APIs, so nothing cmdline-restricted).
--- The float backend must pause: window open/close/move calls error (E11)
--- while the cmdline-window is open.
function M.on_cmdline_enter()
  if state.backend_name ~= "kitty" then
    M.pause("cmdline")
  end
end

function M.on_cmdline_leave()
  M.resume("cmdline")
end

--- Hide everything (tab switch away, suspend). Placements are deleted;
--- actors keep their state for unhide().
function M.hide()
  if not state.running then
    return
  end
  M.pause("hidden")
  local ops = {}
  for _, a in ipairs(state.actors) do
    ops[#ops + 1] = { kind = "delete", image_id = a.image_id, placement_id = a.id }
    for _, img in pairs(IMG_EMOTE) do
      ops[#ops + 1] = { kind = "delete", image_id = img, placement_id = a.id }
    end
  end
  for key in pairs(state.grass_tiles) do
    ops[#ops + 1] = { kind = "delete", image_id = IMG_GRASS, placement_id = key }
  end
  state.grass_tiles = {}
  state.backend.flush(ops)
end

function M.unhide()
  if not state.running then
    return
  end
  M.resume("hidden")
  state.grid_dirty = true -- next tick rebuilds and re-syncs the grass field
  for _, a in ipairs(state.actors) do
    a.dirty = true
  end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.start()
  if state.running then
    return
  end
  local backends = require("pokemon.backend")
  local b, name, why = backends.select(config.options.backend)
  if not b.setup() then
    return
  end
  state.backend = b
  state.backend_name = name
  if why and config.options.debug then
    vim.notify("pokemon.nvim: using float backend (" .. why .. ")", vim.log.levels.INFO)
  end

  state.running = true
  state.grid_dirty = true
  state.timer = vim.uv.new_timer()
  local interval = math.floor(1000 / config.options.fps)
  state.timer:start(interval, interval, vim.schedule_wrap(function()
    local ok, err = pcall(tick)
    if not ok then
      -- full teardown: clears placements and leaves the world restartable
      M.stop()
      vim.notify("pokemon.nvim: crashed, stopping: " .. tostring(err), vim.log.levels.ERROR)
    end
  end))

  -- initial roster (empty roster = random picks from installed sheets)
  local roster = config.options.roster or {}
  for i = 1, config.options.count do
    M.spawn(#roster > 0 and roster[((i - 1) % #roster) + 1] or nil)
  end
end

-- Idempotent: every cleanup path (:Pokemon stop/cleanup, VimLeavePre, the
-- tick crash handler) must be able to clear the screen regardless of state.
function M.stop()
  state.running = false
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
  if state.backend then
    pcall(state.backend.close)
  end
  state.actors = {}
  state.grass_tiles = {}
  state.respawn_queue = {}
  state.pause_reasons = {}
end

function M.status()
  local stats = state.backend and state.backend.stats
  local lines = {
    ("backend: %s%s"):format(
      state.backend_name or "-",
      stats and ("  (flushes: %d, bytes written: %d)"):format(stats.flushes, stats.bytes) or ""
    ),
    ("running: %s  paused: %s"):format(tostring(state.running), table.concat(vim.tbl_keys(state.pause_reasons), ",")),
    state.perf.ticks > 0
        and ("tick avg %.2fms  max %.2fms  |  grid rebuild avg %.2fms over %d rebuilds"):format(
          state.perf.total_ms / state.perf.ticks,
          state.perf.max_ms,
          state.perf.rebuilds > 0 and state.perf.rebuild_ms / state.perf.rebuilds or 0,
          state.perf.rebuilds
        )
      or "tick: no data yet",
    ("actors: %d  grass tiles: %d  respawn queue: %d"):format(
      #state.actors,
      vim.tbl_count(state.grass_tiles),
      #state.respawn_queue
    ),
  }
  for _, a in ipairs(state.actors) do
    lines[#lines + 1] = ("  #%d %s%s [%s] at (%d,%d) facing %s"):format(
      a.id, a.name, a.shiny and " (shiny)" or "", a.state, a.pos.r, a.pos.c, a.dir
    )
  end
  return table.concat(lines, "\n")
end

return M
