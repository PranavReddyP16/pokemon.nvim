-- Standard plugin entry point: makes :Pokemon available without requiring
-- setup() (plain packer/vim-plug installs, or lazy.nvim `cmd = "Pokemon"`
-- lazy-loading). The command is a thin stub — the main module loads on first
-- use. Calling require("pokemon").setup() is only needed to change options
-- or get auto_start.
if vim.g.loaded_pokemon then
  return
end
vim.g.loaded_pokemon = 1

vim.api.nvim_create_user_command("Pokemon", function(cmd)
  require("pokemon")._run_command(cmd)
end, {
  nargs = "*",
  complete = function(prefix, line)
    return require("pokemon")._complete(prefix, line)
  end,
  desc = "pokemon.nvim: wandering desk pets",
})
