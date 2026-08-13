local M = {}

--- Pick a backend by config + environment. Returns backend, name, reason.
function M.select(preference)
  local kitty = require("pokemon.backend.kitty")
  local float = require("pokemon.backend.float")

  if preference == "float" then
    return float, "float"
  end
  local ok, why = kitty.supported()
  if preference == "kitty" then
    if not ok then
      vim.notify("pokemon.nvim: backend=kitty forced but " .. (why or "?"), vim.log.levels.WARN)
    end
    return kitty, "kitty"
  end
  if ok then
    return kitty, "kitty"
  end
  return float, "float", why
end

return M
