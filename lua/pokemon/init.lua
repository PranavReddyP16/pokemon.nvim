local M = {}

local function wire_autocmds()
  local world = require("pokemon.world")
  local util = require("pokemon.util")
  local group = vim.api.nvim_create_augroup("pokemon-nvim", { clear = true })
  local function au(events, opts)
    vim.api.nvim_create_autocmd(events, vim.tbl_extend("force", { group = group }, opts))
  end

  local dirty = util.debounce(80, world.mark_dirty)

  au({ "WinResized", "WinNew", "WinClosed", "BufWinEnter", "VimResized", "OptionSet" }, {
    callback = dirty,
  })

  -- scrolls and text edits get an immediate (throttled) resync: placements
  -- are screen-anchored and lag the moving text otherwise
  au({ "WinScrolled", "TextChanged", "InsertLeave" }, {
    callback = function()
      world.resync()
      dirty()
    end,
  })

  -- typing fast-path: immediate push check, then the debounced rebuild
  au({ "TextChangedI", "TextChangedP" }, {
    callback = function()
      world.on_typing()
      dirty()
    end,
  })

  au("CmdlineEnter", { callback = world.on_cmdline_enter })
  au("CmdlineLeave", { callback = world.on_cmdline_leave })

  au("TabLeave", { callback = world.hide })
  au("TabEnter", { callback = world.unhide })
  au("VimSuspend", { callback = world.hide })
  au("VimResume", { callback = world.unhide })

  au("VimLeavePre", {
    callback = function()
      world.stop()
    end,
  })
end

--- Environments where drawing over the screen makes no sense.
local function unsupported_env()
  return vim.g.vscode or vim.fn.has("gui_running") == 1
end

-- Autocmds are wired lazily on first use so the plugin/pokemon.lua command
-- stub works without setup() (plain plugin-manager installs). setup() is only
-- needed for options and auto_start.
local initialized = false
local function ensure_init()
  if initialized or unsupported_env() then
    return initialized
  end
  initialized = true
  wire_autocmds()
  return true
end

--- Handler behind the :Pokemon command (defined in plugin/pokemon.lua).
function M._run_command(cmd)
  if not ensure_init() then
    vim.notify("pokemon.nvim: unsupported environment (GUI/embedded)", vim.log.levels.WARN)
    return
  end
  local world = require("pokemon.world")
  local sprites = require("pokemon.sprites")

  do
    local args = cmd.fargs
    local sub = args[1] or "toggle"

    if sub == "start" or sub == "enable" then
      world.start()
    elseif sub == "stop" or sub == "disable" then
      world.stop()
    elseif sub == "toggle" then
      if world.state.running then
        world.stop()
      else
        world.start()
      end
    elseif sub == "spawn" then
      if not world.state.running then
        world.start()
      end
      local names = vim.list_slice(args, 2)

      if #names == 0 then
        if #sprites.installed() > 0 then
          world.spawn(nil)
          return
        end
        -- nothing installed at all: offer a starter set instead of failing
        vim.ui.select({ "gen1 (Kanto, 151)", "gen2 (Johto, 100)", "gen3 (Hoenn, 135)", "gen4 (Sinnoh, 107)", "all (1-493)" }, {
          prompt = "No sprites installed — download which set?",
        }, function(choice)
          if not choice then
            return
          end
          local specs = sprites.expand_install_arg(choice:match("^%S+"), false)
          vim.notify(("pokemon.nvim: downloading %d sheet(s)…"):format(#specs))
          sprites.install(specs, function(ok_n, fail_n)
            vim.notify(("pokemon.nvim: install done — %d new, %d failed"):format(ok_n, fail_n),
              fail_n > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
            if ok_n > 0 then
              world.spawn(nil)
            end
          end)
        end)
        return
      end

      -- multiple names allowed: spawn the installed ones now, offer to
      -- download the rest. "Installed" means EITHER variant is on disk —
      -- world.spawn swaps variant when only one exists upstream (the
      -- legendary birds are shiny-only), so a usable sheet is a usable sheet.
      local ready, missing = {}, {}
      for _, n in ipairs(names) do
        local r = sprites.resolve(n)
        if not r then
          vim.notify(("pokemon.nvim: unknown pokemon %q"):format(n), vim.log.levels.ERROR)
        elseif not (sprites.is_available(r.dex, false) or sprites.is_available(r.dex, true)) then
          -- nothing to download either: don't offer a doomed install
          vim.notify(
            ("pokemon.nvim: no sheet for %s — the sprite source is missing it (mostly legendaries)"):format(n),
            vim.log.levels.ERROR
          )
        elseif sprites.is_installed(r.dex, false) or sprites.is_installed(r.dex, true) then
          ready[#ready + 1] = n
        else
          missing[#missing + 1] = n
        end
      end
      for _, n in ipairs(ready) do
        world.spawn(n)
      end
      if #missing > 0 then
        vim.ui.select({ "Install & spawn", "Skip" }, {
          prompt = ("Not installed yet: %s — download?"):format(table.concat(missing, ", ")),
        }, function(choice)
          if choice == "Install & spawn" then
            for _, n in ipairs(missing) do
              world.spawn(n) -- spawn auto-downloads the sheet, then spawns
            end
          end
        end)
      end
    elseif sub == "despawn" then
      local names = vim.list_slice(args, 2)
      if #names == 0 then
        world.despawn(nil) -- all
      else
        for _, n in ipairs(names) do
          world.despawn(n)
        end
      end
    elseif sub == "install" then
      local targets = vim.list_slice(args, 2)
      local shiny = false
      targets = vim.tbl_filter(function(t)
        if t:lower() == "shiny" then
          shiny = true
          return false
        end
        return true
      end, targets)
      if #targets == 0 then
        vim.notify("usage: :Pokemon install {name|dex|gen1..gen4|all}... [shiny]", vim.log.levels.WARN)
        return
      end

      -- expand every target; report bogus names and source gaps, keep going
      -- with everything else
      local specs, seen, unknown, unavailable = {}, {}, {}, {}
      for _, t in ipairs(targets) do
        local expanded, missing_upstream = sprites.expand_install_arg(t, shiny)
        if #expanded == 0 and #missing_upstream == 0 then
          unknown[#unknown + 1] = t
        end
        vim.list_extend(unavailable, missing_upstream)
        for _, spec in ipairs(expanded) do
          local key = spec.dex .. (spec.shiny and "s" or "n")
          if not seen[key] then
            seen[key] = true
            specs[#specs + 1] = spec
          end
        end
      end
      if #unknown > 0 then
        vim.notify(
          ("pokemon.nvim: no such pokemon/set: %s (try a name, dex number 1-493, gen1..gen4, or all)"):format(
            table.concat(unknown, ", ")
          ),
          vim.log.levels.ERROR
        )
      end
      if #unavailable > 0 then
        local shown = {}
        for i = 1, math.min(#unavailable, 6) do
          shown[i] = sprites.name_of(unavailable[i]) or tostring(unavailable[i])
        end
        local more = #unavailable > 6 and (" +%d more"):format(#unavailable - 6) or ""
        vim.notify(
          ("pokemon.nvim: skipped %d not in the sprite source (mostly legendaries): %s%s"):format(
            #unavailable, table.concat(shown, ", "), more
          ),
          vim.log.levels.WARN
        )
      end
      if #specs == 0 then
        return
      end
      vim.notify(("pokemon.nvim: downloading %d sheet(s)…"):format(#specs))
      sprites.install(specs, function(ok_n, fail_n)
        vim.notify(("pokemon.nvim: install done — %d new, %d failed"):format(ok_n, fail_n),
          fail_n > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
      end)
    elseif sub == "grass" then
      world.toggle_grass()
    elseif sub == "status" then
      vim.notify(world.status())
    elseif sub == "cleanup" then
      world.stop()
      vim.notify("pokemon.nvim: cleaned up")
    else
      vim.notify("Pokemon: unknown subcommand " .. sub, vim.log.levels.ERROR)
    end
  end
end

--- Completion for the :Pokemon command (used by plugin/pokemon.lua).
function M._complete(prefix, line)
  local words = vim.split(vim.trim(line), "%s+")
  if #words <= 1 or (#words == 2 and prefix ~= "") then
    return vim.tbl_filter(function(s)
      return vim.startswith(s, prefix)
    end, { "start", "stop", "toggle", "spawn", "despawn", "install", "grass", "status", "cleanup" })
  end
  return require("pokemon.sprites").complete(prefix)
end

function M.setup(opts)
  local config = require("pokemon.config")
  config.setup(opts)

  if unsupported_env() then
    return
  end
  ensure_init()

  if config.options.auto_start then
    vim.api.nvim_create_autocmd("UIEnter", {
      group = vim.api.nvim_create_augroup("pokemon-nvim-start", { clear = true }),
      once = true,
      callback = function()
        -- let the dashboard/session settle before measuring the screen
        vim.defer_fn(require("pokemon.world").start, 400)
      end,
    })
    -- setup() may run after UIEnter (lazy-loaded); start directly then
    if vim.v.vim_did_enter == 1 then
      vim.defer_fn(require("pokemon.world").start, 400)
    end
  end
end

return M
