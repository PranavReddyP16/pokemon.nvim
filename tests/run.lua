-- Headless logic tests: nvim -l tests/run.lua
-- Exercises the grid math and actor FSM with synthetic occupancy — no
-- terminal graphics needed.

vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local grid_mod = require("pokemon.grid")
local util = require("pokemon.util")
local actor_mod = require("pokemon.actor")
local config = require("pokemon.config")

config.setup({})

local failures = 0
local function check(name, cond)
  if cond then
    print("PASS  " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name)
  end
end

-- 20x60 screen, all free except row 5 cols 1..30 (a "line of text")
local function make_grid()
  local g = grid_mod.Grid.new(20, 60)
  for r = 1, 20 do
    for c = 1, 60 do
      g:set_free(r, c, true)
    end
  end
  for c = 1, 30 do
    g:set_free(5, c, false)
  end
  return g
end

-- fits -----------------------------------------------------------------
local g = make_grid()
check("fits in open space", g:fits(10, 10, 4, 2))
check("does not fit on text", not g:fits(5, 10, 4, 2))
check("does not fit straddling text row", not g:fits(4, 10, 4, 2))
check("fits right of the text", g:fits(5, 35, 4, 2))
check("does not fit out of bounds", not g:fits(20, 59, 4, 2))

-- rightmost_fit_on_row ---------------------------------------------------
local dest = g:rightmost_fit_on_row(5, 1, 4, 2)
check("pushed to the end lands at right edge", dest and dest.c == 57 and dest.r == 5)
-- fill the whole row 5..6 → no room on that row
for c = 1, 60 do
  g:set_free(5, c, false)
  g:set_free(6, c, false)
end
check("no room on row returns nil", g:rightmost_fit_on_row(5, 1, 4, 2) == nil)

-- nearest_fit ------------------------------------------------------------
local near = g:nearest_fit(5, 20, 4, 2, 30)
check("nearest fit found off the filled rows", near ~= nil and g:fits(near.r, near.c, 4, 2))

-- region_size ------------------------------------------------------------
g = make_grid()
check("region size counts open area", g:region_size(10, 40, 100) >= 100)
local tiny = grid_mod.Grid.new(4, 4)
tiny:set_free(1, 1, true)
check("region size of lone cell is 1", tiny:region_size(1, 1, 50) == 1)

-- rect helpers ------------------------------------------------------------
check("rect gap touching", util.rect_gap({ r = 1, c = 1, w = 2, h = 1 }, { r = 1, c = 3, w = 2, h = 1 }) == 0)
check("rect gap one apart", util.rect_gap({ r = 1, c = 1, w = 2, h = 1 }, { r = 1, c = 4, w = 2, h = 1 }) == 1)
check("rects overlap", util.rects_overlap({ r = 1, c = 1, w = 4, h = 2 }, { r = 2, c = 4, w = 2, h = 1 }))
check("rects disjoint", not util.rects_overlap({ r = 1, c = 1, w = 4, h = 2 }, { r = 5, c = 1, w = 2, h = 1 }))

-- actor push semantics -----------------------------------------------------
local world_stub = {
  spot_clear = function()
    return true
  end,
}
local ctx = { grid = make_grid(), cfg = config.options, world = world_stub }

local a = actor_mod.new(387, false, 210387, { r = 5, c = 32 }, { w = 4, h = 2 })
-- simulate text growing over it: occupy its cells
for c = 31, 40 do
  ctx.grid:set_free(5, c, false)
end
local result = a:push(ctx)
check("push relocates", result == "moved")
check("push goes rightward on the row", a.pos.r == 5 and a.pos.c > 40)
check("pushed actor is angry", a.state == "angry")
check("pushed actor faces the screen", a.dir == "down")
check("pushed actor shows angry emote", a.emote and a.emote.kind == "angry")

-- push with a fully blocked screen → gone
local blocked = grid_mod.Grid.new(10, 20) -- all occupied by default
local b = actor_mod.new(390, false, 210390, { r = 3, c = 3 }, { w = 4, h = 2 })
local ctx2 = { grid = blocked, cfg = config.options, world = world_stub }
check("push with nowhere to go despawns", b:push(ctx2) == "gone" and b.state == "gone")

-- chat facing ---------------------------------------------------------------
local p1 = actor_mod.new(25, false, 210025, { r = 8, c = 10 }, { w = 4, h = 2 })
local p2 = actor_mod.new(133, false, 210133, { r = 8, c = 15 }, { w = 4, h = 2 })
p1:chat_with(p2, ctx, "chat")
p2:chat_with(p1, ctx, "chat")
check("chat pair face each other", p1.dir == "right" and p2.dir == "left")
check("chat emotes shown", p1.emote.kind == "chat" and p2.emote.kind == "chat")

-- wander respects occupancy: tick many times, never stand on text ----------
g = make_grid()
local wanderer = actor_mod.new(1, false, 210001, { r = 10, c = 10 }, { w = 4, h = 2 })
local ctx3 = { grid = g, cfg = config.options, world = world_stub }
local ok_all = true
for _ = 1, 400 do
  wanderer:tick(ctx3)
  if not g:fits(wanderer.pos.r, wanderer.pos.c, 4, 2) then
    ok_all = false
    break
  end
end
check("400 wander ticks never overlap text", ok_all)

print(("\n%s"):format(failures == 0 and "ALL TESTS PASSED" or (failures .. " FAILURES")))
os.exit(failures == 0 and 0 or 1)
