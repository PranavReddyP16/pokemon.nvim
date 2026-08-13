-- Floating-window fallback backend (tmux, non-kitty terminals).
--
-- Same op interface as the kitty backend, but each placement is a tiny
-- floating window with half-block "sprite" art tinted per pokemon. Direction
-- is hinted by the face row. Emote ops render their emoji equivalent.

local M = {}

M.Z_POKEMON = 10
M.Z_GRASS = 9
M.Z_EMOTE = 11
M.GRASS = false -- a field of tiles = hundreds of floating windows; skip it

-- placement key -> { win, buf }
local floats = {}

local PALETTE = {
  "#e8b34b", "#7ac74c", "#6390f0", "#ee8130", "#f95587",
  "#a98ff3", "#96d9d6", "#b6a136", "#a6b91a", "#f7d02c",
}

local ART = {
  medium = {
    down = { " ▄██▄ ", " ▀••▀ " },
    up = { " ▄██▄ ", " ▀▀▀▀ " },
    left = { " ▄██▄ ", " •▀▀  " },
    right = { " ▄██▄ ", "  ▀▀• " },
  },
  small = {
    down = { "▄•▄" },
    up = { "▄▀▄" },
    left = { "•▄▄" },
    right = { "▄▄•" },
  },
}

local EMOJI = { angry = "💢", chat = "💬", note = "♪ ", grass = "🌿", ball = "◓ ", burst = "✦ " }

local function key(image_id, placement_id)
  return image_id .. ":" .. placement_id
end

function M.supported()
  return true
end

function M.setup()
  return true
end

local function hl_group_for(image_id)
  local group = "PokemonFloat" .. (image_id % #PALETTE)
  if vim.fn.hlexists(group) == 0 then
    vim.api.nvim_set_hl(0, group, { fg = PALETTE[(image_id % #PALETTE) + 1] })
  end
  return group
end

local function render(op)
  local k = key(op.image_id, op.placement_id)
  local entry = floats[k]
  local lines
  if op.emote then
    lines = { EMOJI[op.emote] or "??" }
  else
    local size = op.cells.h > 1 and "medium" or "small"
    lines = ART[size][op.direction or "down"] or ART[size].down
  end

  if not entry or not vim.api.nvim_win_is_valid(entry.win) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = op.pos.r - 1,
      col = op.pos.c - 1,
      width = op.cells.w,
      height = op.cells.h,
      style = "minimal",
      focusable = false,
      zindex = op.z or M.Z_POKEMON,
      noautocmd = true,
    })
    vim.w[win].pokemon_overlay = true
    vim.wo[win].winhighlight = "Normal:" .. hl_group_for(op.image_id) .. ",EndOfBuffer:" .. hl_group_for(op.image_id)
    vim.wo[win].winblend = 0
    entry = { win = win, buf = buf }
    floats[k] = entry
  else
    vim.api.nvim_win_set_config(entry.win, {
      relative = "editor",
      row = op.pos.r - 1,
      col = op.pos.c - 1,
      width = op.cells.w,
      height = op.cells.h,
    })
  end
  vim.api.nvim_buf_set_lines(entry.buf, 0, -1, false, lines)
end

local function delete(op)
  local k = key(op.image_id, op.placement_id)
  local entry = floats[k]
  if entry then
    pcall(vim.api.nvim_win_close, entry.win, true)
    floats[k] = nil
  end
end

function M.ensure_image(_, _) end

function M.flush(ops)
  for _, op in ipairs(ops) do
    if op.kind == "place" then
      render(op)
    elseif op.kind == "delete" then
      delete(op)
    end
  end
end

function M.hide_all()
  for _, entry in pairs(floats) do
    pcall(vim.api.nvim_win_close, entry.win, true)
  end
  floats = {}
end

M.cleanup = M.hide_all

function M.close()
  M.hide_all()
end

return M
