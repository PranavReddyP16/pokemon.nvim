local M = {}

M.defaults = {
  auto_start = true,
  count = 3, -- how many pokemon wander at once (capped by max_actors)
  max_actors = 10,
  roster = { "turtwig", "chimchar", "piplup" }, -- names or dex numbers; drawn from installed sheets
  shiny = false, -- false | true | "sometimes" (~5% per spawn)
  size = "medium", -- "small" 2x1 | "medium" 4x2 | "large" 5x3 | { w = _, h = _ }
  fps = 8,
  wander = {
    step_chance = 0.55, -- probability of taking a step each tick while wandering
    idle_chance = 0.06, -- probability of stopping to idle
    idle_ticks = { 8, 32 }, -- min/max idle duration
  },
  chat = {
    chance = 0.02, -- per-tick chance when two pokemon stand adjacent
    cooldown_sec = 45, -- per-pair cooldown
    duration_sec = 4,
  },
  angry = { duration_sec = 2.5 },
  -- random mood bubbles while wandering/idling (hearts, notes, zzz...)
  emotes = { idle_chance = 0.005 }, -- per tick; ~every 25s per pokemon at 8fps
  -- tall grass field below the text — OFF by default; toggle at runtime with
  -- :Pokemon grass. density = fraction of route "super cells" that grow a
  -- patch (0 = none, 1 = solid field). zone = the bottom fraction of each
  -- window's empty space where grass may grow at all.
  grass = { enabled = false, density = 0.55, zone = 0.4 },
  backend = "auto", -- "auto" | "kitty" | "float"
  respawn_delay_sec = 2, -- how long a region must stay stable before respawning there
  debug = false,
}

M.options = vim.deepcopy(M.defaults)

local SIZES = {
  small = { w = 2, h = 1 },
  medium = { w = 4, h = 2 },
  large = { w = 5, h = 3 },
}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local o = M.options
  o.count = math.min(o.count, o.max_actors)
  local s = o.size
  local custom_ok = type(s) == "table" and type(s.w) == "number" and type(s.h) == "number" and s.w >= 1 and s.h >= 1
  if not (SIZES[s] or custom_ok) then
    vim.notify(("pokemon.nvim: invalid size %s, using medium"):format(vim.inspect(s)), vim.log.levels.WARN)
    o.size = "medium"
  end
  return o
end

--- Footprint in cells for the configured size.
function M.footprint()
  local s = M.options.size
  if type(s) == "table" then
    return { w = math.floor(s.w), h = math.floor(s.h) }
  end
  return SIZES[s] or SIZES.medium
end

return M
