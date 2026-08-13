-- Screen occupancy grid. Cells are 1-based (row, col) on the editor screen.
--
-- Bias rule: when we can't cheaply know what a screen region contains, we mark
-- it OCCUPIED. Sprites render over terminal cells, so a false-free cell means a
-- pokemon standing on the user's text — strictly worse than lost roaming room.
-- We therefore start from "everything occupied" and only free cells we can
-- prove are blank: the area right of a line's end, empty lines, and rows below
-- the last line of a buffer.

local M = {}

local Grid = {}
Grid.__index = Grid

function Grid.new(rows, cols)
  return setmetatable({ rows = rows, cols = cols, occ = {}, below = {}, generation = 0 }, Grid)
end

--- Cells in the "below the last line" region of a window (the eob zone).
--- Stores the cell's DEPTH into that zone as a fraction: ~0 just under the
--- text, 1.0 at the window bottom. The grass field uses this to grow only in
--- the deep end, well away from the code.
function Grid:set_below(r, c, depth)
  self.below[self:idx(r, c)] = depth
end

--- Zone depth fraction, or nil when the cell isn't below a buffer's last line.
function Grid:below_depth(r, c)
  if r < 1 or c < 1 or r > self.rows or c > self.cols then
    return nil
  end
  return self.below[self:idx(r, c)]
end

function Grid:idx(r, c)
  return (r - 1) * self.cols + c
end

function Grid:is_free(r, c)
  if r < 1 or c < 1 or r > self.rows or c > self.cols then
    return false
  end
  return self.occ[self:idx(r, c)] == false
end

function Grid:set_free(r, c, free)
  if r >= 1 and c >= 1 and r <= self.rows and c <= self.cols then
    self.occ[self:idx(r, c)] = not free
  end
end

--- Is the w x h footprint with top-left (r, c) entirely free?
function Grid:fits(r, c, w, h)
  for rr = r, r + h - 1 do
    for cc = c, c + w - 1 do
      if not self:is_free(rr, cc) then
        return false
      end
    end
  end
  return true
end

--- All top-left positions where a w x h footprint fits. Sampled with a stride
--- to keep the candidate list small on big screens.
function Grid:free_positions(w, h, stride)
  stride = stride or 2
  local out = {}
  for r = 1, self.rows - h + 1, stride do
    for c = 1, self.cols - w + 1, stride do
      if self:fits(r, c, w, h) then
        out[#out + 1] = { r = r, c = c }
      end
    end
  end
  return out
end

--- Nearest position (Chebyshev ring search) where footprint fits, from (r, c).
function Grid:nearest_fit(r, c, w, h, max_radius)
  max_radius = max_radius or math.max(self.rows, self.cols)
  if self:fits(r, c, w, h) then
    return { r = r, c = c }
  end
  for radius = 1, max_radius do
    for cc = c - radius, c + radius do
      if self:fits(r - radius, cc, w, h) then
        return { r = r - radius, c = cc }
      end
      if self:fits(r + radius, cc, w, h) then
        return { r = r + radius, c = cc }
      end
    end
    for rr = r - radius + 1, r + radius - 1 do
      if self:fits(rr, c - radius, w, h) then
        return { r = rr, c = c - radius }
      end
      if self:fits(rr, c + radius, w, h) then
        return { r = rr, c = c + radius }
      end
    end
  end
  return nil
end

--- "Pushed to the end": rightmost position on the same row where the footprint
--- fits, at column >= from_c. Returns nil if the row has no room.
function Grid:rightmost_fit_on_row(r, from_c, w, h)
  for c = self.cols - w + 1, from_c, -1 do
    if self:fits(r, c, w, h) then
      return { r = r, c = c }
    end
  end
  return nil
end

--- Are all in-bounds cells within a margin around the rect free? Used to keep
--- scenery far from text. Out-of-bounds cells don't count against it — the
--- screen edge isn't code.
function Grid:clear_margin(r, c, w, h, mr, mc)
  for rr = r - mr, r + h - 1 + mr do
    for cc = c - mc, c + w - 1 + mc do
      if rr >= 1 and cc >= 1 and rr <= self.rows and cc <= self.cols and not self:is_free(rr, cc) then
        return false
      end
    end
  end
  return true
end

--- Rough size of the free region around (r, c): bounded flood fill.
--- Used to prefer roomy spawn spots and to place grass in open areas.
function Grid:region_size(r, c, cap)
  cap = cap or 200
  if not self:is_free(r, c) then
    return 0
  end
  local seen, stack, count = {}, { { r, c } }, 0
  while #stack > 0 and count < cap do
    local cell = table.remove(stack)
    local rr, cc = cell[1], cell[2]
    local key = rr * 10000 + cc
    if not seen[key] and self:is_free(rr, cc) then
      seen[key] = true
      count = count + 1
      stack[#stack + 1] = { rr + 1, cc }
      stack[#stack + 1] = { rr - 1, cc }
      stack[#stack + 1] = { rr, cc + 1 }
      stack[#stack + 1] = { rr, cc - 1 }
    end
  end
  return count
end

-- ---------------------------------------------------------------------------
-- Build from live editor state
-- ---------------------------------------------------------------------------

--- One reserved cell after the line when 'list' shows an eol marker (it is
--- drawn one cell past the measured line width).
local function eol_listchar_pad(win)
  local ok, has = pcall(function()
    return vim.wo[win].list and vim.wo[win].listchars:match("eol:") ~= nil
  end)
  return (ok and has) and 1 or 0
end

--- Extra display width on a line from eol/inline virtual text (diagnostics
--- etc.). Chunk widths are measured inside the window's context so tabs and
--- ambiguous-width settings resolve like they render. eol_right_align and
--- overlay-style positions render at unpredictable columns -> whole row.
local function virt_text_extra(win, extmarks_by_line, lnum)
  local marks = extmarks_by_line[lnum]
  if not marks then
    return 0, false
  end
  local extra, whole_row = 0, false
  for _, details in ipairs(marks) do
    local pos = details.virt_text_pos
    if pos == "eol" or pos == "inline" then
      vim.api.nvim_win_call(win, function()
        for _, chunk in ipairs(details.virt_text or {}) do
          extra = extra + vim.fn.strdisplaywidth(chunk[1])
        end
      end)
      extra = extra + 1 -- eol virt text is drawn one cell after the line
    elseif pos == "overlay" or pos == "right_align" or pos == "win_col" or pos == "eol_right_align" then
      whole_row = true
    end
  end
  return extra, whole_row
end

--- Collect virt_text extmarks for the visible range of a buffer, keyed by lnum.
local function collect_virt_text(bufnr, top, bot)
  local by_line = {}
  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, bufnr, -1, { top - 1, 0 }, { bot - 1, -1 }, {
    details = true,
    type = "virt_text",
  })
  if not ok then
    return by_line
  end
  for _, m in ipairs(marks) do
    local lnum = m[2] + 1
    by_line[lnum] = by_line[lnum] or {}
    table.insert(by_line[lnum], m[4])
  end
  return by_line
end

--- Free the blank cells of one normal (non-floating) window into the grid.
local function scan_window(grid, win)
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return
  end
  local bufnr = info.bufnr
  local winrow, wincol = info.winrow, info.wincol -- 1-based screen pos of window top-left
  local width, height, textoff = info.width, info.height, info.textoff

  local top, bot, last_line, skipcol
  vim.api.nvim_win_call(win, function()
    top = vim.fn.line("w0")
    bot = vim.fn.line("w$")
    last_line = vim.fn.line("$")
    skipcol = vim.fn.winsaveview().skipcol
  end)

  local virt = collect_virt_text(bufnr, top, bot)
  local text_left = wincol + textoff -- first screen col of the text area
  local win_right = wincol + width - 1
  local eol_pad = eol_listchar_pad(win)

  -- getwininfo height EXCLUDES the winbar; text rows start below it
  local winbar_off = (info.winbar == 1) and 1 or 0
  local row = winrow + winbar_off
  local max_row = winrow + winbar_off + height - 1
  local lnum = top

  while row <= max_row and lnum <= math.min(bot, last_line) do
    local folded_end, line_w
    -- measure inside the window's context: 'tabstop' etc. are per-buffer/window
    vim.api.nvim_win_call(win, function()
      folded_end = vim.fn.foldclosedend(lnum)
      if folded_end == -1 then
        local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
        line_w = vim.fn.strdisplaywidth(line)
      end
    end)
    if folded_end ~= -1 then
      -- closed fold: one display row, fold text usually spans wide; keep occupied
      lnum = folded_end + 1
      row = row + 1
    else
      local th_opts = { start_row = lnum - 1, end_row = lnum - 1 }
      if lnum == top and skipcol > 0 then
        -- smoothscroll: only the topline's rows below skipcol are on screen
        th_opts.start_vcol = skipcol
      end
      local ok, th = pcall(vim.api.nvim_win_text_height, win, th_opts)
      local display_rows = ok and th.all or 1
      if display_rows == 1 then
        local extra, whole_row = virt_text_extra(win, virt, lnum)
        if not whole_row then
          local text_end = text_left + line_w + extra + eol_pad -- first free col
          for c = math.max(text_end, text_left), win_right do
            grid:set_free(row, c, true)
          end
        end
        row = row + 1
      else
        -- wrapped or has virtual lines: occupied (conservative), skip its rows
        row = row + display_rows
      end
      lnum = lnum + 1
    end
  end

  -- rows below the last buffer line: blank except the eob '~' in the window's
  -- first column
  if lnum > last_line then
    local zone_h = max_row - row + 1
    for r = row, max_row do
      local depth = (r - row + 1) / zone_h
      for c = wincol + 1, win_right do
        grid:set_free(r, c, true)
        grid:set_below(r, c, depth)
      end
    end
  end
end

--- Re-occupy the rectangle of a floating window (incl. border), unless it is
--- one of ours. nvim_win_get_position returns the BORDER's top-left corner
--- (0-based), so a bordered float extends h+2 x w+2 down-right from there.
local function occupy_float(grid, win)
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  if not ok or cfg.relative == "" or cfg.hide then
    return
  end
  if vim.w[win].pokemon_overlay then
    return
  end
  local pos = vim.api.nvim_win_get_position(win) -- 0-based; includes border
  local h = vim.api.nvim_win_get_height(win)
  local w = vim.api.nvim_win_get_width(win)
  local pad = (cfg.border and cfg.border ~= "none") and 1 or 0
  for r = pos[1] + 1, pos[1] + h + 2 * pad do
    for c = pos[2] + 1, pos[2] + w + 2 * pad do
      grid:set_free(r, c, false)
    end
  end
end

--- Build the full occupancy grid for the current tabpage.
function M.build()
  local rows = vim.o.lines
  local cols = vim.o.columns
  local grid = Grid.new(rows, cols)
  -- everything starts occupied (tabline, statuslines, cmdline, msg area,
  -- unknown UI rows); windows then free their provably blank cells

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "" then
      scan_window(grid, win)
    end
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    occupy_float(grid, win)
  end

  -- builtin popup menu (completion) isn't a window
  if vim.fn.pumvisible() == 1 then
    local pum = vim.fn.pum_getpos()
    if pum and pum.size then
      for r = pum.row + 1, pum.row + pum.height do
        for c = pum.col + 1, pum.col + pum.width + (pum.scrollbar == 1 and 1 or 0) do
          grid:set_free(r, c, false)
        end
      end
    end
  end

  return grid
end

--- Fast in-place patch: re-occupy cells of the cursor line in the current
--- window. Called per-keystroke in insert mode so pokemon react to typing
--- immediately, without waiting for the debounced rebuild. Returns the
--- invaded rect, or nil when the line contributes no occupied cells.
function M.patch_cursor_line(grid)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return nil
  end
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return nil
  end
  local lnum = vim.fn.line(".")
  local leftcol = vim.fn.winsaveview().leftcol
  -- anchor at the first VISIBLE column: col 1 is off-screen when the window
  -- is horizontally scrolled and screenpos would return zeros
  local srow = vim.fn.screenpos(win, lnum, leftcol + 1).row
  if srow == 0 then
    return nil
  end

  local text_left = info.wincol + info.textoff
  local win_right = info.wincol + info.width - 1
  local from, to

  -- a line that plausibly overflows the text area: skip the O(line) measure
  -- and occupy the whole row (the file-header bias: over-occupy when unsure)
  local line_bytes = vim.fn.col("$") - 1
  if line_bytes > info.width * 4 then
    from, to = text_left, win_right
  else
    local line = vim.api.nvim_get_current_line()
    local vis_w = math.max(vim.fn.strdisplaywidth(line) - leftcol, 0)
    local eol_pad = eol_listchar_pad(win)
    if vis_w + eol_pad == 0 then
      return nil -- empty line: nothing rendered, nothing to invade
    end
    from = text_left
    to = math.min(text_left + vis_w + eol_pad - 1, win_right)
    if to < from then
      return nil
    end
  end

  for c = from, to do
    grid:set_free(srow, c, false)
  end
  return { r = srow, c = from, w = to - from + 1, h = 1 }
end

M.Grid = Grid
return M
