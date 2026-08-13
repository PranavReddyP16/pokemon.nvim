-- Sprite sheet registry + downloader.
--
-- Sheets are HGSS follower overworlds in RPG-Maker charset layout: 128x128 px,
-- 4 rows of directions (down, left, right, up) x 4 walk frames of 32x32 px.
-- The kitty backend renders sub-rectangles, so sheets are used as-is —
-- no slicing step exists anywhere.

local names = require("pokemon.names")
local sheet_index = require("pokemon.sheet_index")
local util = require("pokemon.util")

local M = {}

M.FRAME_PX = 32
-- %s is the source repo's actual filename for a (dex, variant) — looked up in
-- sheet_index, NOT constructed: 17 pokemon use nonstandard filenames upstream
-- and 29 (mostly legendaries) don't exist there at all.
M.SHEET_URL = "https://raw.githubusercontent.com/baptiste-ro/pokemon-followers-sprites/main/followsprites/%s"

M.DIR_ROW = { down = 0, left = 1, right = 2, up = 3 }
M.FRAMES = 4

M.GENS = { gen1 = { 1, 151 }, gen2 = { 152, 251 }, gen3 = { 252, 386 }, gen4 = { 387, 493 } }

local dex_by_name = {}
for dex, name in pairs(names) do
  dex_by_name[name] = dex
end

function M.dir()
  return vim.fn.stdpath("data") .. "/pokemon.nvim/sprites"
end

--- Resolve a user-supplied name or dex number to { dex, name } or nil.
function M.resolve(id)
  local dex = tonumber(id)
  if dex and names[dex] then
    return { dex = dex, name = names[dex] }
  end
  local name = tostring(id):lower()
  if dex_by_name[name] then
    return { dex = dex_by_name[name], name = name }
  end
  return nil
end

function M.sheet_path(dex, shiny)
  return ("%s/%d-%s.png"):format(M.dir(), dex, shiny and "s" or "n")
end

--- Does the upstream sprite source have a sheet for this (dex, variant)?
function M.is_available(dex, shiny)
  local entry = sheet_index[dex]
  return entry ~= nil and entry[shiny and "s" or "n"] ~= nil
end

--- Upstream filename for a (dex, variant), or nil when unavailable.
function M.source_filename(dex, shiny)
  local entry = sheet_index[dex]
  return entry and entry[shiny and "s" or "n"] or nil
end

function M.is_installed(dex, shiny)
  return vim.uv.fs_stat(M.sheet_path(dex, shiny)) ~= nil
end

--- All installed dex numbers (normal variant).
function M.installed()
  local out = {}
  local handle = vim.uv.fs_scandir(M.dir())
  if not handle then
    return out
  end
  while true do
    local fname = vim.uv.fs_scandir_next(handle)
    if not fname then
      break
    end
    local dex = fname:match("^(%d+)%-n%.png$")
    if dex then
      out[#out + 1] = tonumber(dex)
    end
  end
  table.sort(out)
  return out
end

--- Source sub-rectangle (pixels) for a direction + walk frame.
function M.frame_rect(direction, frame)
  local row = M.DIR_ROW[direction] or 0
  local col = frame % M.FRAMES
  return { x = col * M.FRAME_PX, y = row * M.FRAME_PX, w = M.FRAME_PX, h = M.FRAME_PX }
end

--- Download sheets for a list of { dex, shiny } specs. Calls
--- on_done(ok_count, fail_count) when all finish. Concurrency-limited.
function M.install(specs, on_done)
  vim.fn.mkdir(M.dir(), "p")
  local pending = {}
  for _, spec in ipairs(specs) do
    if not M.is_installed(spec.dex, spec.shiny) then
      pending[#pending + 1] = spec
    end
  end
  if #pending == 0 then
    if on_done then
      on_done(0, 0)
    end
    return
  end

  local ok_count, fail_count, launched, finished = 0, 0, 0, 0
  local MAX_CONCURRENT = 6

  local function launch_next()
    launched = launched + 1
    local spec = pending[launched]
    if not spec then
      return
    end
    local url = M.SHEET_URL:format(M.source_filename(spec.dex, spec.shiny))
    local dest = M.sheet_path(spec.dex, spec.shiny)
    -- atomic download: curl writes a .part file which is renamed only on
    -- success, so an interrupted nvim can never leave a truncated sheet that
    -- is_installed() would mistake for a real one
    local part = dest .. ".part"
    vim.system(
      { "curl", "--silent", "--fail", "--location", "--output", part, url },
      {},
      vim.schedule_wrap(function(res)
        finished = finished + 1
        if res.code == 0 and vim.uv.fs_rename(part, dest) then
          ok_count = ok_count + 1
        else
          fail_count = fail_count + 1
          pcall(vim.uv.fs_unlink, part)
        end
        if launched < #pending then
          launch_next()
        elseif finished == #pending and on_done then
          on_done(ok_count, fail_count)
        end
      end)
    )
  end

  for _ = 1, math.min(MAX_CONCURRENT, #pending) do
    launch_next()
  end
end

--- Expand an install argument ("all", "gen1".."gen4", name, dex) into specs.
--- Second return: dex numbers the source simply doesn't have (skipped).
function M.expand_install_arg(arg, shiny)
  local specs, unavailable = {}, {}
  local function add(dex)
    if M.is_available(dex, shiny) then
      specs[#specs + 1] = { dex = dex, shiny = shiny }
    else
      unavailable[#unavailable + 1] = dex
    end
  end
  if arg == "all" then
    for dex = 1, 493 do
      add(dex)
    end
  elseif M.GENS[arg] then
    for dex = M.GENS[arg][1], M.GENS[arg][2] do
      add(dex)
    end
  else
    local resolved = M.resolve(arg)
    if resolved then
      add(resolved.dex)
    end
  end
  return specs, unavailable
end

--- Pick shiny-ness for a spawn given config ("sometimes" ~= 5%).
function M.roll_shiny(cfg_shiny)
  if cfg_shiny == true then
    return true
  end
  if cfg_shiny == "sometimes" then
    return util.chance(0.05)
  end
  return false
end

function M.name_of(dex)
  return names[dex]
end

--- Command-line completion candidates.
function M.complete(prefix)
  local out = { "all", "gen1", "gen2", "gen3", "gen4" }
  for _, name in pairs(names) do
    out[#out + 1] = name
  end
  return vim.tbl_filter(function(item)
    return vim.startswith(item, prefix:lower())
  end, out)
end

return M
