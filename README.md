# pokemon.nvim

Gen 4 pokemon wander the empty parts of your neovim screen. When your code
grows into the space one is standing on, it gets shoved to the end of the row,
turns to glare at you, and shows an angry emote. Sometimes two of them stop
and chat. There is tall grass.

Sprites render as real pixel art via the kitty graphics protocol (kitty,
ghostty, wezterm), always **below text** — a pokemon can never cover your
code. Other terminals get a small half-block-art fallback.

## Requirements

- neovim 0.10+
- kitty / ghostty / wezterm for pixel sprites (anything else falls back to
  floating-window art)
- `curl` for sprite downloads

## Install (lazy.nvim)

```lua
{
  "PranavReddyP16/pokemon.nvim",
  event = "VeryLazy",
  opts = {},
}
```

`:Pokemon` also works with zero config on any plugin manager (`setup()` is
only needed to change options / get auto-start). `:help pokemon` for full
docs, `:checkhealth pokemon` to verify your terminal.

## Sprites

Sheets download on demand to `stdpath("data")/pokemon.nvim/sprites/`
(~5 KB each). Grab a generation up front:

```
:Pokemon install gen4        " all of Sinnoh
:Pokemon install all         " national dex 1..493
:Pokemon install pikachu
:Pokemon install eevee shiny
```

## Commands

```
:Pokemon                     " toggle
:Pokemon spawn [names...]    " add one or many, e.g. :Pokemon spawn pikachu eevee 143
                             " (random installed if omitted; offers to download
                             " anything not installed yet)
:Pokemon despawn [name]      " remove one/all
:Pokemon install {arg}       " download sheets (name, dex, gen1..gen4, all)
:Pokemon grass               " toggle the tall grass field (off by default)
:Pokemon status              " who's here, what backend
:Pokemon cleanup             " remove everything incl. terminal image data
```

## Options (defaults)

```lua
require("pokemon").setup({
  auto_start = true,
  count = 3,                          -- concurrent wanderers
  roster = { "turtwig", "chimchar", "piplup" },
  shiny = false,                      -- true | false | "sometimes" (~5%)
  size = "medium",                    -- "medium" 4x2 cells | "small" 2x1
  fps = 8,
  grass = { enabled = false, density = 0.55, zone = 0.4 }, -- route-style field below
                                      -- the text; :Pokemon grass toggles at runtime
  backend = "auto",                   -- "auto" | "kitty" | "float"
})
```

## Architecture

`docs/ARCHITECTURE.md` is the full design document — module map, the
occupancy-grid bias rule, the backend op protocol, kitty protocol notes,
event tiers, performance numbers, and hard-won gotchas. Start there before
modifying the plugin.

## Notes

- The sprite source is missing 29 pokemon (mostly legendaries — mew, lugia,
  ho-oh, celebi, most Sinnoh legendaries...). Installs skip them with a
  notice; `:Pokemon spawn` explains. The legendary birds/beasts exist only
  as shinies and are spawned as such automatically.

- Not supported inside tmux yet (graphics passthrough): falls back to float art.
- Sprite sheets are HGSS follower overworlds fetched from
  [baptiste-ro/pokemon-followers-sprites](https://github.com/baptiste-ro/pokemon-followers-sprites);
  the tall grass is the DPPt tile from
  [Bulbagarden Archives](https://archives.bulbagarden.net/) (rustle frame
  synthesized). Pokémon is © Nintendo/Game Freak — game assets live on your
  machine, not in this repo.

## Tests

```
nvim -l tests/run.lua
```
