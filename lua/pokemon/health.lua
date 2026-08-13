-- :checkhealth pokemon
local M = {}

function M.check()
  local health = vim.health

  health.start("pokemon.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("neovim >= 0.10")
  else
    health.error("neovim 0.10+ required (vim.system, vim.base64, extmark APIs)")
  end

  if vim.fn.executable("curl") == 1 then
    health.ok("curl found (sprite downloads)")
  else
    health.error("curl not found — :Pokemon install cannot download sheets")
  end

  local kitty = require("pokemon.backend.kitty")
  local ok, why = kitty.supported()
  if ok then
    health.ok("kitty graphics protocol available (pixel sprites)")
  else
    health.warn(("kitty graphics unavailable: %s — falling back to float art"):format(why or "unknown"),
      { "use kitty, ghostty, or wezterm for real sprites", "tmux is not supported yet" })
  end

  if vim.v.stderr and vim.v.stderr > 0 then
    health.ok("stderr channel to terminal present")
  else
    health.error("no v:stderr channel — graphics escapes cannot reach the terminal")
  end

  local sprites = require("pokemon.sprites")
  local installed = sprites.installed()
  if #installed > 0 then
    health.ok(("%d sprite sheet(s) installed at %s"):format(#installed, sprites.dir()))
  else
    health.info("no sprites installed yet — :Pokemon install gen4 (or spawn something)")
  end

  if vim.g.vscode or vim.fn.has("gui_running") == 1 then
    health.warn("GUI/embedded environment — plugin disables itself here")
  end
end

return M
