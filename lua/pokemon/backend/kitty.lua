-- Kitty graphics protocol backend.
--
-- Model: every sprite sheet / asset PNG is transmitted once (file medium,
-- t=f) under a stable image id. Each on-screen entity is a *placement*
-- (image_id, placement_id) showing a 32x32 sub-rectangle of its sheet, scaled
-- by kitty into a c x r cell box. Moving/animating = re-issuing the placement
-- (same ids replace atomically). All escapes for a tick are concatenated and
-- written to the tty in one write.
--
-- Z-order: all our placements use negative z, so they render BELOW text
-- glyphs but above background highlights. Even if the occupancy grid is ever
-- wrong, a sprite can never cover the user's code.

local M = {}

M.Z_POKEMON = -10
M.Z_GRASS = -5 -- above pokemon: walking "through" grass occludes the sprite
M.Z_EMOTE = -3
M.GRASS = true -- can render the tall grass field (hundreds of placements)

-- Writes go to v:stderr with chansend: plugin Lua runs in nvim's embedded
-- server process, which has NO controlling terminal (/dev/tty is ENXIO
-- there), but its stderr passes through to the terminal untouched.
local ready = false
local transmitted = {} -- image_id -> true
local live = {} -- "image_id:placement_id" -> { image_id, placement_id }

local function esc(payload, data)
  return "\027_G" .. payload .. (data and (";" .. data) or "") .. "\027\\"
end

function M.supported()
  if vim.env.TMUX and vim.env.TMUX ~= "" then
    return false, "tmux (passthrough not supported yet)"
  end
  if vim.env.KITTY_WINDOW_ID or (vim.env.TERM or ""):find("kitty") then
    return true
  end
  if vim.env.GHOSTTY_RESOURCES_DIR or (vim.env.TERM or ""):find("ghostty") then
    return true
  end
  if vim.env.WEZTERM_PANE then
    return true
  end
  return false, "terminal does not advertise kitty graphics support"
end

function M.setup()
  ready = vim.v.stderr ~= nil and vim.v.stderr > 0
  if not ready then
    vim.notify("pokemon.nvim: no stderr channel to the terminal", vim.log.levels.ERROR)
  end
  return ready
end

local function write(data)
  if ready then
    pcall(vim.fn.chansend, vim.v.stderr, data)
  end
end

--- Ensure a PNG file is transmitted under image_id (no-op if already sent).
function M.ensure_image(image_id, png_path)
  if transmitted[image_id] then
    return
  end
  local encoded = vim.base64.encode(png_path)
  write(esc(("a=t,f=100,t=f,i=%d,q=2"):format(image_id), encoded))
  transmitted[image_id] = true
end

--- Build (not write) the escape for placing/moving a placement.
--- pos is 1-based screen cells; rect is the pixel sub-rectangle of the sheet;
--- cells is { w, h } — the on-screen cell box kitty scales into.
--- C=1 keeps the real cursor untouched by kitty.
local function place_seq(image_id, placement_id, pos, rect, cells, z)
  local move = ("\027[%d;%dH"):format(pos.r, pos.c)
  local payload = ("a=p,i=%d,p=%d,x=%d,y=%d,w=%d,h=%d,c=%d,r=%d,z=%d,C=1,q=2"):format(
    image_id, placement_id, rect.x, rect.y, rect.w, rect.h, cells.w, cells.h, z or M.Z_POKEMON
  )
  return move .. esc(payload)
end

--- Flush a batch of ops in one tty write, cursor saved/restored around it.
--- ops: list of { kind = "place", image_id, placement_id, pos, rect, cells, z }
---           or { kind = "delete", image_id, placement_id }
M.stats = { flushes = 0, bytes = 0 }

function M.flush(ops)
  if #ops == 0 or not ready then
    return
  end
  local parts = { "\0277" } -- DECSC save cursor
  for _, op in ipairs(ops) do
    local k = op.image_id .. ":" .. op.placement_id
    if op.kind == "place" then
      parts[#parts + 1] = place_seq(op.image_id, op.placement_id, op.pos, op.rect, op.cells, op.z)
      live[k] = { image_id = op.image_id, placement_id = op.placement_id }
    elseif op.kind == "delete" then
      if live[k] then -- skip no-op deletes (most emote slots are empty)
        parts[#parts + 1] = esc(("a=d,d=i,i=%d,p=%d,q=2"):format(op.image_id, op.placement_id))
        live[k] = nil
      end
    end
  end
  parts[#parts + 1] = "\0278" -- DECRC restore cursor
  local data = table.concat(parts)
  M.stats.flushes = M.stats.flushes + 1
  M.stats.bytes = M.stats.bytes + #data
  write(data)
end

--- Delete OUR visible placements only (keeps transmitted image data). Never
--- uses kitty's global delete: other plugins (snacks.image) share the
--- terminal's graphics namespace.
function M.hide_all()
  local parts = {}
  for _, p in pairs(live) do
    parts[#parts + 1] = esc(("a=d,d=i,i=%d,p=%d,q=2"):format(p.image_id, p.placement_id))
  end
  live = {}
  if #parts > 0 then
    write(table.concat(parts))
  end
end

--- Full cleanup: our placements AND our transmitted image data.
function M.cleanup()
  M.hide_all()
  local parts = {}
  for image_id in pairs(transmitted) do
    parts[#parts + 1] = esc(("a=d,d=I,i=%d,q=2"):format(image_id))
  end
  transmitted = {}
  if #parts > 0 then
    write(table.concat(parts))
  end
end

function M.close()
  M.cleanup()
  ready = false
end

return M
