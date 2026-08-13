# pokemon.nvim — agent notes

**Read `docs/ARCHITECTURE.md` before changing anything load-bearing.** It is
the full mental model: module map, the occupancy-grid bias rule, the backend
op protocol, kitty graphics specifics, event tiers, and a list of gotchas
that each cost a real debugging cycle.

The invariants most likely to save you:

- **Bias rule**: unknown screen content is OCCUPIED. Never "free" a cell you
  can't prove blank — a sprite over the user's code is the one unforgivable
  bug. (Kitty backend renders at negative z as a second safety net.)
- Terminal writes go to `v:stderr` via `chansend`. `/dev/tty` does NOT work
  from plugin Lua (nvim's server process has no controlling terminal).
- Kitty deletes are per-placement only — global deletes (`d=a`) nuke other
  plugins' images (snacks.image shares the terminal's id namespace).
- GONE actors leave the registry only AFTER the flush that emitted their
  placement deletes, or the sprite is orphaned on screen forever.
- The grass layout is a pure function of (seed, zone shape) — do not add
  state to it; determinism is what makes it prune/regrow without flicker.
- `sheet_index.lua` and `names.lua` are GENERATED — the upstream sprite repo
  has irregular filenames and 29 missing pokemon; never construct filenames.

Tests: `nvim -l tests/run.lua` (headless, no graphics needed). For live
verification drive a kitty window over its remote-control socket and have
nvim write state to a file — internal state alone can lie about rendering;
check the flush/byte counters in `:Pokemon status`.
