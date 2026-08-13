local M = {}

--- Debounce fn by ms; trailing edge; safe to call from any context.
function M.debounce(ms, fn)
  local timer = nil
  return function(...)
    local args = { ... }
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = vim.uv.new_timer()
    timer:start(ms, 0, function()
      timer:stop()
      timer:close()
      timer = nil
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
end

function M.clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

--- Chebyshev distance between two cell rects {r, c, w, h} (gap in cells; 0 = touching/overlap).
function M.rect_gap(a, b)
  local dr = 0
  if a.r + a.h - 1 < b.r then
    dr = b.r - (a.r + a.h - 1) - 1
  elseif b.r + b.h - 1 < a.r then
    dr = a.r - (b.r + b.h - 1) - 1
  end
  local dc = 0
  if a.c + a.w - 1 < b.c then
    dc = b.c - (a.c + a.w - 1) - 1
  elseif b.c + b.w - 1 < a.c then
    dc = a.c - (b.c + b.w - 1) - 1
  end
  return math.max(dr, dc)
end

function M.rects_overlap(a, b)
  return not (a.c + a.w - 1 < b.c or b.c + b.w - 1 < a.c or a.r + a.h - 1 < b.r or b.r + b.h - 1 < a.r)
end

local seeded = false
function M.rand(n)
  if not seeded then
    math.randomseed(vim.uv.hrtime() % 2 ^ 31)
    seeded = true
  end
  return math.random(n)
end

function M.chance(p)
  if not seeded then
    M.rand(2)
  end
  return math.random() < p
end

function M.pick(list)
  if #list == 0 then
    return nil
  end
  return list[M.rand(#list)]
end

return M
