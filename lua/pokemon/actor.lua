-- One wandering pokemon: position, direction, walk frame, and a small state
-- machine: wander -> (pushed by text) angry -> wander, wander <-> chat.

local sprites = require("pokemon.sprites")
local util = require("pokemon.util")

local M = {}

local Actor = {}
Actor.__index = Actor
M.Actor = Actor

local next_id = 1

M.STATES = {
  WANDER = "wander",
  ANGRY = "angry",
  CHAT = "chat",
  GONE = "gone",
  -- pokeball ceremony: spawn shows ball -> burst -> pokemon; despawn plays
  -- it backwards (burst -> ball -> gone), like a trainer recall
  MATERIALIZING = "materializing",
  RETURNING = "returning",
}

-- materialize: ball while state_ticks > BURST_TICKS, then burst
M.MATERIALIZE_TICKS = 7
-- return: burst for the first RETURN_TICKS - RETURN_BALL_TICKS, then ball
M.RETURN_TICKS = 6
M.RETURN_BALL_TICKS = 4
M.BURST_TICKS = 2

-- emote vocabularies (each name is an assets/emotes/<name>.png)
M.CHAT_EMOTES = { "chat", "note", "heart", "exclaim", "question" }
M.IDLE_EMOTES = { "note", "heart", "question", "sweat", "exclaim" }

function M.new(dex, shiny, image_id, pos, footprint)
  local a = setmetatable({
    id = next_id,
    dex = dex,
    name = sprites.name_of(dex),
    shiny = shiny,
    image_id = image_id,
    pos = { r = pos.r, c = pos.c },
    w = footprint.w,
    h = footprint.h,
    dir = "down",
    frame = 0,
    state = M.STATES.MATERIALIZING,
    state_ticks = M.MATERIALIZE_TICKS,
    idle_ticks = 0,
    target = nil,
    emote = nil, -- { kind, ticks }
    age = 0, -- total ticks lived; drives the idle animation phase
    dirty = true, -- needs re-place this flush
  }, Actor)
  next_id = next_id + 1
  return a
end

function Actor:rect()
  return { r = self.pos.r, c = self.pos.c, w = self.w, h = self.h }
end

function Actor:set_emote(kind, ticks)
  self.emote = { kind = kind, ticks = ticks }
  self.dirty = true
end

--- Face toward a screen point (dominant axis).
function Actor:face(r, c)
  local dr = r - self.pos.r
  local dc = c - self.pos.c
  if math.abs(dc) >= math.abs(dr) then
    self.dir = dc >= 0 and "right" or "left"
  else
    self.dir = dr >= 0 and "down" or "up"
  end
  self.dirty = true
end

--- Pick a new wander target from free positions within a radius.
local function retarget(self, ctx)
  local candidates = ctx.grid:free_positions(self.w, self.h, 3)
  local near = {}
  for _, p in ipairs(candidates) do
    local d = math.max(math.abs(p.r - self.pos.r), math.abs(p.c - self.pos.c))
    if d > 2 and d < 45 and ctx.world:spot_clear(self, p.r, p.c) then
      near[#near + 1] = p
    end
  end
  self.target = util.pick(near) -- may be nil; we idle until space opens up
end

--- One step toward the target. Steps are 1 cell, axis-at-a-time, and only
--- onto cells that are free and not another pokemon.
local function step(self, ctx)
  local t = self.target
  if not t then
    return false
  end
  local dr = t.r ~= self.pos.r and (t.r > self.pos.r and 1 or -1) or 0
  local dc = t.c ~= self.pos.c and (t.c > self.pos.c and 1 or -1) or 0
  -- try horizontal first (reads better with wide cells), then vertical
  local tries = {}
  if dc ~= 0 then
    tries[#tries + 1] = { r = self.pos.r, c = self.pos.c + dc, dir = dc > 0 and "right" or "left" }
  end
  if dr ~= 0 then
    tries[#tries + 1] = { r = self.pos.r + dr, c = self.pos.c, dir = dr > 0 and "down" or "up" }
  end
  for _, try in ipairs(tries) do
    if ctx.grid:fits(try.r, try.c, self.w, self.h) and ctx.world:spot_clear(self, try.r, try.c) then
      -- terminal cells are ~2x taller than wide, so a row step covers twice
      -- the distance of a column step; take vertical steps at half rate or
      -- they look like they're sprinting up/downhill
      if try.r ~= self.pos.r and not util.chance(0.5) then
        return false -- skip this tick, keep the target
      end
      self.pos.r, self.pos.c = try.r, try.c
      self.dir = try.dir
      self.frame = (self.frame + 1) % sprites.FRAMES
      self.dirty = true
      if self.pos.r == t.r and self.pos.c == t.c then
        self.target = nil
      end
      return true
    end
  end
  self.target = nil -- blocked: pick something else next tick
  return false
end

--- HGSS followers never stop animating: a standing pokemon keeps cycling its
--- sheet frames (that's articuno's wing flap, magmar's flame, a ground mon
--- marching in place — exactly like the games). Slower than the walk rate;
--- phase staggered by actor id so the party isn't in lockstep.
local function idle_animate(self)
  if (self.age + self.id) % 3 == 0 then
    self.frame = (self.frame + 1) % sprites.FRAMES
    self.dirty = true
  end
end

function Actor:tick(ctx)
  self.age = self.age + 1
  if self.emote then
    self.emote.ticks = self.emote.ticks - 1
    if self.emote.ticks <= 0 then
      self.emote = nil
      self.dirty = true
    end
  end

  if self.state == M.STATES.GONE then
    return
  end

  if self.state == M.STATES.MATERIALIZING or self.state == M.STATES.RETURNING then
    self.state_ticks = self.state_ticks - 1
    self.dirty = true -- ball/burst phase changes every tick
    if self.state_ticks <= 0 then
      if self.state == M.STATES.MATERIALIZING then
        self.state = M.STATES.WANDER
      else
        self.state = M.STATES.GONE
      end
    end
    return
  end

  if self.state == M.STATES.ANGRY or self.state == M.STATES.CHAT then
    self.state_ticks = self.state_ticks - 1
    if self.state_ticks <= 0 then
      self.state = M.STATES.WANDER
      self.dirty = true
    elseif self.state == M.STATES.CHAT and util.chance(0.1) then
      -- conversations move: swap bubbles mid-chat
      self:set_emote(util.pick(M.CHAT_EMOTES), math.min(self.state_ticks, 10))
    end
    idle_animate(self)
    return
  end

  -- wander: occasionally a mood bubble pops up out of nowhere, like a
  -- follower in the games (zzz when parked, anything else on the move)
  if not self.emote and util.chance(ctx.cfg.emotes.idle_chance) then
    local kind = self.idle_ticks > 0 and "zzz" or util.pick(M.IDLE_EMOTES)
    self:set_emote(kind, 12)
  end
  if self.idle_ticks > 0 then
    self.idle_ticks = self.idle_ticks - 1
    idle_animate(self)
    return
  end
  local cfg = ctx.cfg.wander
  if util.chance(cfg.idle_chance) then
    self.idle_ticks = util.rand(cfg.idle_ticks[2] - cfg.idle_ticks[1]) + cfg.idle_ticks[1]
    self.frame = 0
    self.dirty = true
    return
  end
  if not self.target then
    retarget(self, ctx)
  end
  local moved = false
  if util.chance(cfg.step_chance) then
    moved = step(self, ctx)
  end
  if not moved then
    idle_animate(self) -- blocked or waiting between steps: keep animating
  end
end

--- Text invaded our footprint. Relocate per spec: to the end of this row's
--- free space; failing that, nearest free spot; failing that, leave the
--- screen. Returns "moved" | "gone".
function Actor:push(ctx)
  local dest = ctx.grid:rightmost_fit_on_row(self.pos.r, self.pos.c, self.w, self.h)
  if dest and not ctx.world:spot_clear(self, dest.r, dest.c) then
    dest = nil
  end
  if not dest then
    dest = ctx.grid:nearest_fit(self.pos.r, self.pos.c, self.w, self.h, 60)
    if dest and not ctx.world:spot_clear(self, dest.r, dest.c) then
      -- nearest spot is another pokemon; search a bit more broadly
      local candidates = ctx.grid:free_positions(self.w, self.h, 2)
      dest = nil
      for _, p in ipairs(candidates) do
        if ctx.world:spot_clear(self, p.r, p.c) then
          dest = p
          break
        end
      end
    end
  end

  if not dest then
    self.state = M.STATES.GONE
    self.emote = nil
    self.dirty = true
    return "gone"
  end

  self.pos.r, self.pos.c = dest.r, dest.c
  self.target = nil
  self.state = M.STATES.ANGRY
  self.state_ticks = math.floor(ctx.cfg.angry.duration_sec * ctx.cfg.fps)
  self.dir = "down" -- face the screen, glaring at you
  self.frame = 0
  self:set_emote("angry", self.state_ticks)
  return "moved"
end

--- Recall into the pokeball (animated despawn). The world removes us once
--- the animation reaches GONE.
function Actor:recall()
  if self.state == M.STATES.GONE or self.state == M.STATES.RETURNING then
    return
  end
  self.state = M.STATES.RETURNING
  self.state_ticks = M.RETURN_TICKS
  self.emote = nil
  self.target = nil
  self.dirty = true
end

--- Enter chat state facing a partner.
function Actor:chat_with(partner, ctx, kind)
  self.state = M.STATES.CHAT
  self.state_ticks = math.floor(ctx.cfg.chat.duration_sec * ctx.cfg.fps)
  self:face(partner.pos.r, partner.pos.c)
  -- chatting pokemon face each other on the horizontal axis when side by side
  if self.pos.r == partner.pos.r then
    self.dir = partner.pos.c >= self.pos.c and "right" or "left"
  end
  self.frame = 0
  self:set_emote(kind, self.state_ticks)
end

return M
