# pokemon.nvim — architecture

Gen 4 pokemon overworld sprites wander the empty parts of the neovim screen.
This document is the mental model for working on the plugin: read it before
changing anything load-bearing. Every invariant here exists because something
visibly broke without it.

## Table of contents

- [The one-paragraph version](#the-one-paragraph-version)
- [Module map](#module-map)
- [Coordinate system](#coordinate-system)
- [The occupancy grid and the bias rule](#the-occupancy-grid-and-the-bias-rule)
- [Backends and the op protocol](#backends-and-the-op-protocol)
- [Kitty graphics specifics](#kitty-graphics-specifics)
- [Event wiring and the three speed tiers](#event-wiring-and-the-three-speed-tiers)
- [Actors](#actors)
- [The grass field](#the-grass-field)
- [Sprite assets](#sprite-assets)
- [Lifecycle and cleanup](#lifecycle-and-cleanup)
- [Performance](#performance)
- [Testing](#testing)
- [Gotchas that already cost a debugging cycle](#gotchas-that-already-cost-a-debugging-cycle)

## The one-paragraph version

A `vim.uv` timer ticks at 8fps (`world.lua`). Each tick consults an
**occupancy grid** (`grid.lua`) — a screen-cell map of where text is — and
advances per-pokemon state machines (`actor.lua`): wander in free cells, get
**pushed** to the end of the row when text invades (then face the screen,
angry emote), occasionally **chat** with an adjacent pokemon. A procedural
**tall-grass field** grows in the bottom fraction of the empty space below
each window's last line. Everything renders through a **backend**: kitty
graphics protocol placements (real pixel sprites, `backend/kitty.lua`) or
floating windows with half-block art (`backend/float.lua`). The world emits
abstract **ops**; backends translate them.

## Module map

| Module               | Owns                                                                       |
| -------------------- | -------------------------------------------------------------------------- |
| `init.lua`           | `setup()`, `:Pokemon` command, autocmd wiring, environment gating           |
| `config.lua`         | defaults, validation, size presets → footprint                             |
| `world.lua`          | tick loop, actor registry, collision sweeps, chat pairing, respawn queue, grass field, pause/hide, perf counters |
| `actor.lua`          | one pokemon: position, direction, walk frame, FSM (wander/angry/chat/gone) |
| `grid.lua`           | occupancy grid: build from editor state, footprint queries, typing fast-path patch |
| `sprites.lua`        | dex↔name resolution, sheet download/cache, frame sub-rects, availability   |
| `sheet_index.lua`    | GENERATED: dex → actual upstream filename (nil = source doesn't have it)   |
| `names.lua`          | GENERATED: dex → name, 1..493 (from PokeAPI)                               |
| `backend/init.lua`   | backend selection (env detection, config override)                         |
| `backend/kitty.lua`  | kitty graphics protocol: transmit, place, delete, batching, cleanup        |
| `backend/float.lua`  | floating-window fallback renderer                                          |
| `util.lua`           | debounce, rect math, seeded rand                                           |

Dependency direction: `world` → everything; backends and `grid` know nothing
about actors; `actor` knows `grid` only through the `ctx` it's handed.

## Coordinate system

**1-based screen cells**, `(row, col)`, matching vim's `screenpos()` and the
terminal's cursor addressing. `(1,1)` is the top-left of the editor. An
actor's position is its footprint's **top-left cell**; footprints are
`w x h` cells (config size preset; medium = 4x2). The float backend converts
to 0-based only at the `nvim_open_win` boundary; the kitty backend emits
1-based `CSI row;col H` directly.

## The occupancy grid and the bias rule

`grid.build()` produces a boolean per cell: occupied or free. **The bias rule
(load-bearing): when we can't cheaply know what a region contains, mark it
OCCUPIED.** Sprites render over terminal cells; a false-free cell means a
pokemon standing on code. Over-occupation just costs roaming room.

Consequences of the rule:

- The grid starts fully occupied; windows then *free* cells they can prove
  blank: right of each line's display end, empty lines, rows below the last
  buffer line (the **eob zone**, also tagged with a 0..1 depth fraction for
  the grass field).
- Wrapped lines, closed folds, and `overlay`/`right_align`/`eol_right_align`
  virtual text mark whole rows occupied rather than guessing.
- Everything unclaimed — tabline, statuslines, cmdline, msg area — simply
  stays occupied.

Details that were each a real bug (see git history):

- Line widths are measured **inside `nvim_win_call(win)`** so the scanned
  window's own `tabstop` applies, not the current window's.
- `nvim_win_get_position()` on a float returns the **border's** top-left;
  the border extends down-right (`h+2 x w+2`), not outward in all directions.
- `getwininfo().height` excludes the winbar; both the start row *and* the max
  row need the winbar offset.
- `smoothscroll` + `skipcol`: pass `start_vcol` to `nvim_win_text_height` for
  the topline or every row below it is shifted.
- `list` mode's `eol:` listchar occupies one cell past the measured width.
- eol/inline virtual text width (diagnostics!) is added to the line width.

`grid.patch_cursor_line()` is the **typing fast-path**: an in-place
single-row update so pokemon react to insert-mode keystrokes immediately
instead of after debounce + tick (~200ms). It returns nil for empty lines
(a zero-width patch once caused phantom pushes) and handles horizontal
scroll (`leftcol`) and multi-MB lines (skips measuring; occupies the row).

## Backends and the op protocol

The world renders by handing the backend a flat list of ops per flush:

```lua
{ kind = "place",  image_id = N, placement_id = N, pos = {r,c},
  rect = {x,y,w,h},     -- pixel sub-rect of the source image (sheet frame)
  cells = {w,h},        -- on-screen cell box the image is scaled into
  z = N,                -- backend z constant
  direction = "down",   -- float backend only (picks ASCII art)
  emote = "angry" }     -- float backend only (picks emoji)
{ kind = "delete", image_id = N, placement_id = N }
```

Backend contract: `supported()`, `setup()`, `ensure_image(id, png_path)`,
`flush(ops)`, `hide_all()`, `cleanup()`, `close()`, plus constants
`Z_POKEMON < Z_GRASS < Z_EMOTE` and capability flag `GRASS` (the float
backend sets false — a grass field would be hundreds of floating windows).

**Identity = (image_id, placement_id).** Image ids are offset by
`ID_BASE = 210000` (world.lua) so they can never collide with other
kitty-graphics plugins (snacks.image allocates small ids in the same
terminal-global namespace). Scheme: `210000 + dex` (normal),
`+1000` more for shiny, `219000+` for grass/emotes. Placement ids: actor id
for sprites and that actor's emote; `r*1000+c` for grass tiles.

## Kitty graphics specifics

- **Writes go to `v:stderr` via `chansend`**, NOT `/dev/tty`. Plugin Lua runs
  in nvim's embedded server process, which has no controlling terminal
  (`/dev/tty` opens fail with ENXIO); its stderr passes through to the
  terminal. This is the hologram.nvim technique.
- Images are transmitted **once** by file reference (`a=t,t=f`, payload =
  base64 of the file *path*), then placements reference them. Animation and
  direction changes are just re-placements with a different source sub-rect —
  re-placing the same (image_id, placement_id) replaces atomically.
- All ops in a flush are concatenated into **one write**, wrapped in
  DECSC/DECRC cursor save/restore, with `q=2` (suppress responses) and `C=1`
  (don't move the cursor) on every graphics escape.
- **Negative z**: placements render *below text glyphs but above background
  highlights*. Even if the grid is ever wrong, a sprite cannot cover code —
  the text draws over it. This is the final safety net behind the bias rule.
- Deletes are **per-placement, never global** (`a=d,d=i`). Kitty's global
  delete (`d=a`/`d=A`) would destroy other plugins' images. The backend
  tracks its live placements and its transmitted image ids and deletes
  exactly those on `hide_all()`/`cleanup()`.
- Placements are **screen-anchored**: when nvim scrolls, text slides but
  placements stay. This is why scrolling has a dedicated fast-path (below).

## Event wiring and the three speed tiers

All autocmds live in one group (`init.lua`), routing into three tiers by
how fast the response must be:

1. **Immediate — typing** (`TextChangedI/P` → `world.on_typing`): cheap
   precheck (any actor near the cursor row?), then `patch_cursor_line` +
   push. Runs per keystroke; must stay O(actors) in the common case.
2. **Immediate, throttled — layout changes** (`WinScrolled`, `TextChanged`,
   `InsertLeave` → `world.resync`): full grid rebuild + collision sweep +
   grass resync, at most once per 50ms. Needed because placements are
   screen-anchored (see above); waiting for the debounced path leaves
   grass/pokemon floating over moved text for ~200ms.
3. **Debounced (80ms) — everything else** (`WinResized`, `WinNew/Closed`,
   `BufWinEnter`, `VimResized`, `OptionSet` → `mark_dirty`): sets a flag;
   the next tick rebuilds the grid. This is also the safety net behind
   tiers 1 and 2.

Pause reasons (a set, not a boolean): `cmdline` (Cmdline events) and `hidden`
(TabLeave/VimSuspend → `hide()` deletes all placements; TabEnter/VimResume →
`unhide()` re-marks everything dirty). The tick is a no-op while any reason
is present.

## Actors

FSM per pokemon (`actor.lua`): `wander ⇄ chat`, `wander → angry → wander`,
`any → gone`.

- **Wander**: pick a free target within radius, step 1 cell/tick toward it
  (horizontal preferred; vertical steps at half rate because cells are ~2x
  taller than wide — full-rate vertical looks like sprinting). Walk frame
  advances only on actual steps. Random idle pauses.
- **Push** (the showcase interaction, spec'd behavior): when text invades
  the footprint — rightmost fit on the same row, else nearest fit (ring
  search), else `gone` + respawn queue. After relocating: face `down`
  (toward the viewer), `angry` state, angry emote, ~2.5s.
- **Chat**: two wandering actors adjacent (rect gap ≤ 1) roll a per-tick
  chance with a per-pair cooldown; both face each other, emote bubbles.
- **Gone/respawn**: respawn scan runs every 16 ticks with **hysteresis** — a
  candidate spot must be free on two consecutive scans before spawning, so
  pokemon don't flicker back into a gap mid-typing-burst. Respawns respect
  `max_actors`.

Ordering invariant: GONE actors are dropped from the registry **only after
the flush that emitted their delete ops** (end of `tick()`). Dropping them
earlier orphans their placement on screen forever (was a real bug: the
respawn scan filtered them pre-flush).

Actor-vs-actor overlap is the world's job (`spot_clear`), not the grid's —
the grid describes the environment only.

## The grass field

Route-style tall-grass patches in the empty space below each window's last
line. **Off by default** — `:Pokemon grass` toggles it live (`world.toggle_grass`
flips the flag and forces a resync; the diff in `grass_sync` does the rest,
since a disabled field's desired set is simply empty). Key design: **the
layout is a pure function of (session seed, zone shape)** — nothing is
remembered between rebuilds.

- The grid tags eob cells with a depth fraction (0 just under the text → 1
  at the window bottom). Grass may only grow where depth > `1 - zone`
  (default: the bottom 40%), plus a clear margin (2 rows / 6 cols) from any
  text.
- Two-octave hash noise: a coarse super-cell hash (~10x3 cells) decides
  where patches are (`density` config), a fine per-tile hash pokes rare
  holes (0.92) so patches read as mostly-solid route rectangles. The hash
  is xorshift-mixed — a plain multiplicative hash correlates along
  diagonals and the field visibly streaked.
- Because the layout is deterministic, text growing into the zone prunes
  exactly the affected tiles and *the same tiles* grow back when the text
  retreats. No reshuffle flicker. (`grass_sync` diffs desired-vs-current and
  emits only the changes; it runs only on rebuild ticks.)
- **Rustle**: tiles under a pokemon's footprint alternate between the two
  sheet frames at 4Hz (`grass_rustle`, every tick, emits ops only on frame
  changes). Grass draws *above* pokemon (z order), so walking through
  half-hides the sprite — the gen 4 encounter-grass effect.

## Sprite assets

- **Pokemon sheets**: HGSS follower overworlds from
  `baptiste-ro/pokemon-followers-sprites` (GitHub). 128x128 PNG, RPG-Maker
  charset layout: 4 rows = down/left/right/up, 4 columns = walk frames,
  32x32 each. Never sliced — backends render sub-rects.
- **`sheet_index.lua` is generated from the repo's file listing** and maps
  dex → actual upstream filename per variant. This exists because the
  upstream naming is irregular: 17 pokemon use variant names (trailing-dash
  typos, gendered Wobbuffet `202-m/f`, form suffixes `422_1`) and **29 dex
  numbers — mostly legendaries — have no sheet at all** (mew, lugia, ho-oh,
  celebi, the regis, most Sinnoh legendaries, arceus...). The legendary
  birds and beasts have shiny-only sheets; `world.spawn` silently swaps
  variant when only the other exists, and errors clearly when neither does.
- Sheets download on demand (`:Pokemon install`, or auto on spawn) to
  `stdpath("data")/pokemon.nvim/sprites/<dex>-<n|s>.png` — note the *local*
  name is normalized even when the upstream name is irregular. Downloads are
  atomic (curl to `.part`, rename on success) so a killed nvim can't leave a
  truncated PNG that `is_installed()` would trust.
- **Grass**: `assets/grass.png`, 2 frames of 22x20 — frame 0 is the authentic
  DPPt Long Grass tile (Bulbagarden Archives), frame 1 is a synthesized
  rustle (halves splayed outward, squashed to 85%). **Emotes**:
  `assets/emotes/*.png`, generated pixel art.
- Licensing: Pokémon is © Nintendo/Game Freak. Game-derived assets are
  downloaded to the user's machine; the repo ships only the generated
  emotes and the grass sheet.

## Lifecycle and cleanup

`world.stop()` is **idempotent by design** — no early return. Every cleanup
path routes through it: `:Pokemon stop/cleanup`, `VimLeavePre`, and the tick
crash handler (a tick exception does full teardown, so the screen is never
left with stranded placements and the world is restartable). Kitty
placements outlive nvim if not deleted — cleanup is not optional.

`hide()`/`unhide()` (tab switches, suspend) delete placements but keep actor
state; unhide marks everything dirty and the next tick re-places.

## Performance

Numbers from a ~140x55 terminal, 3 actors, ~500-1000 grass tiles (see
`:Pokemon status`, which live-reports these):

- tick avg ~1ms (≈0.9% of a core at 8fps); idle ticks with no movement emit
  zero escapes
- grid rebuild ~1.4ms, debounced, never per-tick unless dirty
- worst tick ~10ms — the one-time initial grass field flush
- per-keystroke: O(actors) comparisons unless a pokemon is on the cursor row

Perf-sensitive spots, deliberately shaped:

- `find_spawn_spot` samples ≤25 candidates instead of flood-filling every
  free position (was 17-31ms stalls).
- `on_typing` prechecks actor rows before doing any O(line) work, and never
  measures lines > 4x window width.
- `on_scroll` is throttled to 50ms.
- `grass_rustle` is O(tiles) per tick in lookups only; ops only on change.

## Testing

- `nvim -l tests/run.lua` — headless logic tests (grid math, push semantics,
  chat facing, wander-never-overlaps-text). No terminal graphics needed.
- Live verification pattern (no screen-recording permission needed): drive a
  kitty window via `kitty @ --to unix:<socket> send-text`, have nvim write
  state to a temp file (`:lua vim.fn.writefile(...)`), read it back. The
  write-stats in `:Pokemon status` (flushes / bytes) prove escapes are
  actually reaching the terminal — internal state alone once hid a
  completely dead render path.

## Gotchas that already cost a debugging cycle

1. `/dev/tty` is ENXIO from plugin Lua (embedded server process) — use
   `chansend(vim.v.stderr, ...)`.
2. Kitty placements are screen-anchored; scrolling needs the fast-path.
3. Never use kitty's global delete; snacks.image shares the id namespace.
4. GONE actors must outlive the flush that deletes their placements.
5. `strdisplaywidth` is context-sensitive (tabstop) — measure in
   `nvim_win_call`.
6. Multiplicative hashes streak diagonally — xorshift-mix anything that
   drives visible patterns.
7. The upstream sprite repo is incomplete and irregularly named — trust
   `sheet_index.lua`, never construct filenames.
8. Downloads must be atomic; `is_installed` trusts file existence.
