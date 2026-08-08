# Simulation roadmap: from saved SimGrid snapshots to a running simulation

Written 2026-08-07, to be executed across follow-up sessions. **Steps 1–4 are DONE**
(steps 2–4 executed later the same day — see `dev_notes/save_file_analysis` §13 for the
session log and the identification corrections); step 5 (the RCI loop) remains. Read
`CLAUDE.md` (SimGrids / Data views / Simulation bullets) and `save_file_analysis` §11–§13
first — they carry the format facts and identification evidence this plan builds on.

**Corrections discovered during execution** (details in §13; the step texts below are left
as written, so read them with these in mind):

- **The "smooth twins" `0x49D5B964`/`0x49D5B953` are NOT air pollution.** They are the
  FLAMMABILITY pair: base holds each building exemplar's `Flammability` property (via its
  family cohort) stamped over its lot, effective = base × 1.25 (the summer multiplier).
  Named on `SimGridSubfile`, gated in the harness.
- **The crime candidates `0x49D5BB8C`/`0x49D5BBA1` are not crime** — a near-identical
  bitfield pair that follows power corridors on Big City but is near-empty on Tegel;
  positive identity unconfirmed, left unnamed.
- **`0x41800000` is the zone-type grid**, lot `zone_type` verbatim (≥99.6% agreement on
  every populated save). Named and gated.
- **Consequently NO shipped save stores any pollution, land-value or crime field** — SC4
  recomputes all of them at load. Pollution/crime are therefore gated on structure
  (industry outpollutes residential, $ outscores $$$, determinism, edit response) and land
  value on wealth-boundary agreement, not on saved targets.

## Where things stand (context for a fresh session)

- **Parsing/modeling done.** `addons/dbpf/SimGridSubfile.gd` parses all six SimGrid types
  (column-major, `index = x * height + z`); `CityView/SimGrids.gd` models them
  (`City.sim_grids_model()`, lazy). Identified layers so far: `TRAFFIC_*` (5) and
  `OCCUPANT_CODE` `0x49D5B678` (occupant family+wealth codes → `OCCUPANT_CODE_WEALTH`).
  **The save stores no continuous land-value grid** — SC4 recomputes it at load.
- **Data views done.** `CityView/DataViewCatalogue.gd` reads SC4's view exemplars (group
  `0x690F693F`; ramps, opacity, interpolate; "Data source" is a private enum, hand-curated
  to dataIds in `DATA_SOURCE_TO_GRID`). `City.set_data_view` paints per-tile colours into
  the terrain shader's `data_view_tex`; V cycles; `landvalue` screenshot keyword.
- **Step 1 done — live wealth view.** The wealth view renders from `LotModel` (follows
  `lots_changed`, coalesced deferred repaint in `City._repaint_data_view`); the saved grid
  is only the load-time gate. Harness: `_check_data_views` (parse health, catalogue, 100%
  decode agreement) and `_check_data_view_live` (raze → repaint, runs last in the chain).
- **Verification harnesses**: `godot --headless --import` (compile), HeadlessCity scene
  (`SWEEP COMPLETE`, exit 1 on failure), ScreenshotCity under Xvfb (see CLAUDE.md).
  `tools/dat_dump.py` (stdlib Python DBPF/QFS/exemplar reader) is the fastest way to probe
  DATs/saves offline — the identification work in §12 was done with inline scripts on it.

## Guiding principles

1. **Saved grids are ground truth, not render sources.** Every simulator we write gets
   calibrated/gated against the shipped saves' own grids, the way the network graph is
   gated on `TRAFFIC_*` (Jaccard) and the wealth view on `OCCUPANT_CODE` (decode
   agreement). Building a simulator and identifying its saved output layers are the same
   task — each step below names its target grids.
2. **In-memory only.** No DBPF write support exists and none is needed — simulation state
   lives in `SimGrids`/models and is recomputed from the save on load.
3. **One choke point per kind of state**, matching `NetworkModel`/`LotModel`: simulators
   read models, write grids, and views repaint off signals. No renderer reads simulator
   internals.

## Step 2 — Mutable grid state + a simulation tick   [DONE]

Scaffolding, no physics. Everything later hangs off this.
As built: `SimGrids.derived` + `commit_derived()` + `grids_changed`;
`CityView/Simulation.gd` (monthly step(), advance() at pause/1x/3x, **Space** cycles,
starts paused); systems registered traffic → pollution → land value → crime; the
`_check_simulation` block in the harness (fixed point over 3 months, per-field existence).

- `CityView/SimGrids.gd`: add owned, writable layers alongside the loaded snapshot —
  `derived : Dictionary` (dataId or name → Grid), `set_cell/fill`, and a
  `grids_changed(ids)` signal. Loaded snapshot grids stay immutable.
- New `CityView/Simulation.gd` (`class_name Simulation`, plain RefCounted owned by City):
  a game clock with a **monthly tick** (SC4's cadence for land value/pollution/crime) plus
  a faster minor tick if needed later. Drive it from `City._process` with a speed setting
  (pause / 1x / 3x); headless harnesses call `simulation.step()` directly — never rely on
  frame time in checks.
- Registration: `simulation.add_system(callable, cadence)`; systems run in a fixed order
  (pollution → land value → crime → …) because later fields read earlier ones.
- Data views: a view whose layer is derived repaints on `grids_changed` (same coalesced
  pattern as `_on_lots_changed_data_view`).
- Harness: a `_check_simulation_tick` — stepping N months with no edits leaves derived
  fields stable (fixed-point or bounded drift), stepping after an edit changes them.

## Step 3 — Field simulators: pollution, land value, crime   [DONE]

Grid-in/grid-out diffusion fields. All constants are on disc; parse them with
`ExemplarSubfile` (`Core.subfile(0x6534284a, <group>, <instance>, ExemplarSubfile)`).
As built: `CityView/Sim/{PollutionSim,LandValueSim,CrimeSim}.gd`; source properties are
resolved through the family COHORT chain (`Core.exemplar_prop`, CQZB support added to
`ExemplarSubfile`) because growable buildings carry almost nothing on their own exemplar.
See each file's header for the model and which constants are SC4's vs fitted.

### 3a. Air pollution (first, because land value consumes it)

- **Sources**: building exemplars' pollution properties (`exemplar_types.dict` names the
  family: "Pollution at centre", radii, "Air/Water/Garbage Pollution" etc.) for every
  occupant in `LotModel`/building records; traffic volume along `NetworkModel` tiles once
  step 4 exists (constant road factor until then).
- **Field**: sources + isotropic spread with decay per tick onto a derived grid (SC4's
  radii are small; a simple kernel or repeated relax pass is enough at 128×128).
- **Calibration targets**: the unidentified smooth twins `0x49D5B964`/`0x49D5B953`
  (u8 128×128, spread beyond lots, anti-correlate with residential wealth — §12) are the
  prime air-pollution candidates. Fit decay/radius so our field correlates strongly with
  one twin across the populated saves; that correlation becomes the identification AND the
  regression gate (add to `_check_data_views` the way `OCCUPANT_CODE` is gated). The two
  twins likely differ as instantaneous vs time-averaged — check which fits.
- **View**: wire enum 8 (`DataView: Air Pollution`) in `DATA_SOURCE_TO_GRID` to the
  derived layer; the catalogue/renderer need no changes.

### 3b. Land value

- **Inputs**: terrain altitude + water proximity (`City.height_map`, `WaterPlane`), the
  pollution field (3a), occupant effects ("Land Value Effect"-family properties from
  building exemplars — parks up, dirty industry down), and proximity curves.
- **Constants**: `Land Value Sim` exemplar T `0x6534284A` G `0xE7E2C2DB` I `0xE7E2C8D8`:
  intrinsic min/max `[1, 64]` (`0x47E2C300`), **wealth boundaries `[70, 120]`**
  (`0x47E2C301`), altitude curve (`0x47E2C320` pairs), plus the desirability-ID/factor
  properties. Property names are in `exemplar_types.dict` ("Land Value …" family).
- **Output**: the first *continuous* land-value layer OpenSC4 has ever had. Feed it to the
  Land value view — replacing the step-1 wealth-class rendering with a real gradient, which
  is what the 12-stop ramp was made for. Keep the wealth-class rendering available (it is
  the honest view of *saved* state; a config or a second catalogue entry).
- **Calibration**: no saved target grid exists, so gate indirectly — thresholding our land
  value at the wealth boundaries must agree with each lot's `zone_wealth` (the same
  agreement metric as `_check_data_views`, now testing the sim instead of the decode
  table). Expect imperfect agreement; pick a floor empirically (start ~0.7) and ratchet.
- **Consumer**: `NetworkBaseTexture.gd` currently guesses sidewalk wealth from
  neighbouring lots (`BY_WEALTH`, worst case 72.9% on Konradshohe per its header) — the
  save's `wealth_texture` byte is "simulation state over land value". Deriving it from our
  land-value field instead is a ready-made accuracy benchmark
  (`MIN_BASE_TEXTURE_AGREEMENT` in `tools/headless_city.gd`).

### 3c. Crime (same shape, later)

Sources scale with population/land value, damped by police coverage (station exemplars'
coverage radii). Candidate saved targets among the unidentified 128×128 u8 layers
(`0x49D5BB8C`/`0x49D5BBA1` — values {0,2,8,10} — and neighbours); identify by correlating
a prototype field, as with pollution. Wire enum 4 when identified.

## Step 4 — Traffic assignment   [DONE, v1]

The routable graph already exists (`NetworkGraph`: per-lane arcs, true metre lengths,
classes; every populated save passes connectivity gates).
As built: `CityView/Sim/TrafficSim.gd` — one commute per residential lot (weighted by
footprint) to the nearest job via one backwards multi-source Dijkstra + per-lot gradient
descent; speeds from the Traffic Simulator exemplar. Gated on precision vs `TRAFFIC_CAR`
(0.85 floor; measured 0.94–1.00) and volume rank correlation (0.10 floor; measured
0.14–0.94). Not done: capacity/congestion (constants in the EXE), mode choice, magnitude
calibration — `PollutionSim` still prefers the SAVE's volumes for its traffic term.

- **Demand**: one commute per residential lot from its `commute_x/z` tile (`LotRecord`)
  toward jobs (commercial/industrial lots), monthly.
- **Routing**: Dijkstra/A* over arcs with travel time = length / speed[network], speeds and
  `Pathfinding Heuristic = 0.09`, commute-time limits from the **Traffic Simulator
  exemplar** T `0x6534284A` G `0xE7E2C2DB` I `0xC9133286` (48 properties; 13-element
  per-network arrays; the 9 travel types fold to the 6 SC4Path classes — see §11 notes).
- **Known gap**: per-network *capacity* is in the EXE, not the DATs (§11 "Not found").
  Choose our own constants (NAM-style) and mark them clearly as invented; congestion
  (`TRAFFIC_CONGESTION`-like ratio) needs them, raw volumes do not.
- **Calibration**: run assignment on an unedited save and compare per-tile volume against
  `TRAFFIC_TOTAL`/`TRAFFIC_CAR` — footprint Jaccard first (should approach the existing
  0.95 gate), then rank correlation of volumes. Write results into derived grids; the
  Traffic data view (enum 9) then works, and `_check_against_simulation` gains a variant
  gating OUR simulator instead of the graph.

## Step 5 — The RCI loop (zone developer)

The step that makes wealth *change* rather than redistribute. Largest by far; break into
sub-sessions:

1. **Demand model**: regional/city RCI demand by type+wealth. The saved 32×32 grid
   families `0x01......`/`0x02/03/05/06......` share low words with SC4's RCI type+wealth
   codes (`1010`=R$ … `4400`=IHT, §Appendix A) — identify them first (occupancy,
   capacity, demand per aggregate cell) by diffing saves and correlating against lot
   populations; they are both the state to seed and the calibration target.
2. **Desirability** per type+wealth from land value, pollution, commute time (step 3+4
   outputs) — the per-RCI desirability views (enums `0x14–0x17`, `0x40–0x4B`) come free
   once these fields exist.
3. **Growth/abandonment**: pick zoned, desirable, connected lots (commute reachability via
   `NetworkGraph`) and grow/upgrade/abandon. Requires *creating* lot+building records at
   runtime — `LotModel`/`City` currently only remove; adding synthesized occupants (choose
   a building exemplar by zone/wealth/stage, place via the existing build path) is the
   main new machinery, and it must go through the `LotModel` choke point like everything
   else. The step-1 live wealth view then shows growth with zero renderer work.
4. **Gates**: replay an unedited save N months — city should stay recognizably itself
   (bounded occupancy drift); bulldoze-then-regrow produces plausible wealth patterns
   (redevelop near high land value first).

## Cross-cutting notes for whoever executes this

- Add each newly identified dataId to `SimGridSubfile` as a named const with the evidence
  in a comment (the `TRAFFIC_*`/`OCCUPANT_CODE` pattern), update §12/Appendix A, and add a
  harness gate. Identification without a gate rots.
- Keep threading as-is (single loader thread + `call_deferred`); simulators run on the
  main thread in the tick — 128×128 fields are small. Profile before reaching for
  `WorkerThreadPool` (CLAUDE.md forbids casual threading).
- The DataView catalogue/renderer should need **no structural changes** for any of this:
  new views = a `DATA_SOURCE_TO_GRID` entry (+ optional transform), which was the point of
  the framework.
- Per-step verification stays the standard trio: `--import` clean → HeadlessCity across
  the populated saves (`SWEEP COMPLETE`) → ScreenshotCity captures for anything visual.
