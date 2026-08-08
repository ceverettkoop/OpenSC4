# OpenSC4

## What it is

OpenSC4 is an open-source **Godot 4.7 (GDScript)** reimplementation of *SimCity 4*. It does
**not** ship game content — instead it loads the ORIGINAL game's proprietary assets
(`.dat` / `.sc4` DBPF archives) at runtime and renders them. Licensed **GNU AGPL v3**
(per the copyright headers in the source, e.g. top of `Core.gd`; there is no standalone
`LICENSE` file).

## Requirements & setup

- A real **SimCity 4 (Deluxe Edition)** install is required.
- Per `README.md`, the user drops the entire contents of their SC4 install into the project
  directory (large `.dat` game assets like `SimCity_1.dat` .. `SimCity_5.dat`, `EP1.dat`,
  `Sound.dat`, `Intro.dat` are currently committed at the repo root — **do not touch them**).
- The chosen game folder is held in `Core.game_dir` and cached in `user://config.ini` under
  `[paths] sc4_files`. On first boot (empty config) a `FileDialog` prompts for the folder
  (see `BootScreen.gd` `_ready()`).

## Run / verify

- Import assets + compile-check scripts: `godot --headless --import`
  (expect **0 SCRIPT ERRORs**).
- Boot the app headless: `timeout -k 5 20 godot --path . --headless`
  — should reach the log line `DBPF files loaded` with zero SCRIPT ERRORs.
- City-load harness (headless): `godot --headless --path . res://tools/HeadlessCity.tscn`
  `[-- "<region>" "<city name>"]` (default Timbuktu / Big City Tutorial). Loads the DATs +
  a real save, builds terrain/buildings, asserts the network-model invariants, then sweeps
  all building view variants; a clean run ends with `SWEEP COMPLETE`. It **exits 1** if a
  network check fails, so it is usable as a regression gate. The build-tool checks draw on
  clear ground *and* drag a road across one of the save's roads (`_check_crossing`), which
  is the case a clear-ground-only test cannot reach, *and* raze lots with both the road and
  the bulldozer (`_check_lot_bulldoze` — including that a plopped lot survives a road drawn
  over it). **The checks run in sequence on one city and every edit is permanent**, so each
  captures its own before-state and later ones must not assume the city is as the save left
  it — a check that needs a fresh lot asks `_find_clear_lot` for another. Round trips are
  gone with undo; the equivalent coverage is `incremental placement matches a full rebuild`,
  which is what actually catches a boundary coming apart. Known failure: **Getting Started
  Tutorial** fails the graph checks — its entire network is one orphan street tile with no
  connections, so there are no arcs to check. Pre-existing and unrelated to the tool.
- SC4Path parser harness (headless): `godot --headless --path . res://tools/DumpPaths.tscn`
  — parses all 3,411 path records and asserts the version/class/stop-type counts and the
  placement transforms; ends with `PATH DUMP COMPLETE`.
- Harnesses must be **scenes, not `-s` scripts**: a `--script` main loop cannot compile
  scripts that reference the `Core`/`Log` autoloads. `godot --check-only` fails for the same
  reason, so `--import` is the compile check.
- Visual harness (windowed): `godot --path . --resolution 1600x900
  res://tools/ScreenshotCity.tscn -- <out_dir> ["<region>" "<city name>"]` — same load
  path, then saves `city_zoom1.png` (whole map) and `city_zoom4.png` (map centre,
  close-up) to `<out_dir>` and quits; ends with `SCREENSHOTS DONE`. Use it to eyeball
  placement/rendering changes. After the city name it also takes shot specs
  `tx,tz,zoom[,rot][,name]` and the bare keywords `pipes`, `graph`, `walking`, `landvalue`
  (simulated gradient), `wealth` (saved wealth classes), `airpollution`, `crime`,
  `months:N` (step the simulation before shooting) and `hold`.
  Under Xvfb add `--rendering-driver opengl3`.
- The same harness doubles as a **viewer**: `hold` aims at the first shot spec and then
  leaves the window open and interactive instead of capturing and quitting (it prints
  `HOLDING at tile ...` and never calls `quit()`). Nothing is written, so `hold` may
  replace the leading `<out_dir>` argument —
  `... -- hold "Timbuktu" "Big City Tutorial" graph 49,67,6`.
  Do **not** combine it with `--headless`: with no presentable surface the capture path
  blocks forever on `RenderingServer.frame_post_draw`.
- Main scene: `BootScreen.tscn`. **There is no test suite.**

## Architecture

### Autoloads (see `project.godot` `[autoload]`)

- `Boot` = `Boot.gd` — tiny global state holder (`current_city`, `load_progress_val`).
- `Core` = `Core.gd` — the central asset registry (see below).
- `Log` = `utils/logger.gd` — vendored KOBUGE godot-logger (`Log.info/warn/error/debug/verbose`).
- `DebugUtils` = `utils/debug_utils.gd` — dev print helpers.

### Boot flow (`BootScreen.gd`)

1. Validate `Core.game_dir` from `user://config.ini`; else pop the FileDialog and save.
2. Start a **single** loader `Thread` running `load_DATs()`, which iterates the hardcoded
   `dat_files` list (`Apps/SimCity 4.ini`, `Sound.dat`, `Intro.dat`, `SimCity_1..5.dat`,
   `EP1.dat`). Each file builds a `DBPF` and calls `Core.add_dbpf()`.
3. UI updates from the worker thread marshal back via `call_deferred`.
4. On completion, the user picks **Region view** (`Region.tscn`) or the **DAT Explorer**
   (`DATExplorer/DATExplorer.tscn`).

### `Core.gd` — central asset registry

Everything flows through this singleton.
- `subfile_indices`: TGI string -> `SubfileIndex` (built by `add_dbpf`).
- `dbpf_files`, `sub_by_type_and_group`: additional lookup tables.
- Hardcoded TGI dictionaries: `type_dict` / `group_dict` (name -> id) and `class_dict`
  (type name -> parser class, e.g. `FSH -> FSHSubfile`, `PNG -> ImageSubfile`; many are `null`).
- Main API:
  - `Core.subfile(type_id, group_id, instance_id, ParserClass) -> DBPFSubfile`
  - `Core.get_subfile(type_str, group_str, instance_id)` — string-friendly variant.
  - `Core.get_gamedata_path(rel) -> String` — resolves a path under `game_dir`.

### `addons/dbpf/` — DBPF format library (Godot editor plugin)

- `DBPF.gd` parses the container (header, `SubfileIndex` records, `DBDF` compressed-file
  directory).
- `DBPFSubfile.gd` (`class_name DBPFSubfile`) is the base class for parsed subfiles and
  contains a **hand-rolled QFS/RefPack decompressor** in GDScript (`decompress()`,
  performance-sensitive).
- Parser subclasses (all `extends DBPFSubfile`): `ExemplarSubfile` (EQZB property files;
  key descriptions from `exemplar_types.dict`), `FSHSubfile` (textures), `S3DSubfile`
  (3D models), `ATCSubfile`/`AVPSubfile` (2D sprite props — see below), `LTEXTSubfile`
  (UTF-16 strings), `ImageSubfile` (PNG), `RULSubfile` (network rules), `SC4PathSubfile`
  (vehicle paths — see below), `CURSubfile` (cursors), `INISubfile`.
- **SimGrids** (`SimGridSubfile`, city-save types `0x49B9E602/03/04/05/06/0A`) — the per-tile
  simulation layers behind every data view. One subfile holds many grids keyed by `dataId`;
  cells are **column-major, `index = x * height + z`**. Modeled by `CityView/SimGrids.gd`
  (`City.sim_grids_model()`, lazy; `load_sim_grids()` is the legacy dict view). The traffic
  layers are SC4's own simulation output and are used as ground truth for the network graph
  (`dev_notes` §11). Identified (each with a harness gate): `TRAFFIC_*` (5), `OCCUPANT_CODE`
  (`0x49D5B678`, occupant codes → wealth 0–3 via `OCCUPANT_CODE_WEALTH`, 100% agreement with
  lot `zone_wealth`), `FLAMMABILITY_BASE/EFFECTIVE` (`0x49D5B964/53`, building exemplars'
  Flammability over lot rects; effective = base × the 1.25 summer multiplier) and
  `ZONE_TYPE` (`0x41800000`, lot zone_type verbatim). **No shipped save stores any pollution,
  land-value, crime or desirability field** — SC4 recomputes them at load, and OpenSC4 now
  does too (see Simulation below). `SimGrids` also owns the writable **derived** layers the
  simulators produce (`DERIVED_*` ids, `commit_derived`, `grids_changed`). See `dev_notes`
  §11–§13.
- **Data views** (`CityView/DataViewCatalogue.gd`): SC4's own view exemplars (group
  `0x690F693F`, colour ramps + "Maximum scale" included) read from the DATs; their "Data
  source" is a private enum, NOT a dataId — known pairs are hand-curated in
  `DATA_SOURCE_TO_GRID`, except Crime/Police, which share enum 4 and are wired by name
  (`NAME_TO_GRID`). `City.set_data_view` paints a view through its ramp into a per-tile
  lookup texture on the terrain shader (`data_view_tex`/`data_view_on`, off by default) and
  hides the occupant roots while active (networks stay). **The Land value view renders the
  simulated continuous field by default** (`City.land_value_simulated`; repaints off
  `grids_changed`), or the live per-lot wealth classes when toggled off
  (`set_land_value_simulated(false)`, follows `lots_changed`) — the saved occupant-code grid
  is only the load-time gate. Air Pollution/Crime/Police render their derived fields (the
  air view maps its 0..1024 domain onto ramp stops 128..255); other views read their saved
  grids. **V** cycles views, skipping mapped views whose layer holds no data;
  `set_data_view_named(...)` is the harness entry; the screenshot harness takes `landvalue`,
  `wealth`, `airpollution`, `crime` and `months:N` keywords. The roadmap is
  `dev_notes/simulation_plan.md` (steps 1–4 done, step 5 remains).
- **SC4Path (0x296678F7)** — a **plain text** format (CRLF), and the network's connectivity.
  One file per network *piece*: which lanes cross that tile, which edge each enters and
  leaves by (0..3 WNES, 255 = ends inside the tile), and for which class (1 Car, 2 Sim,
  3 Train, 4 Subway, 6 ElTrain, 7 Monorail). Ground pieces are group 0x69668828 keyed by the
  FSH texture id — i.e. `NetworkSubfile.NetworkTile.texture_id`; elevated/highway pieces are
  group 0xA966883F keyed by S3D id. Coordinates are tile-local metres, **(east, north, up)**
  — the *third* component is height — and **north is -z** in the world frame. The parser
  stores them raw and exposes `transform_dir`/`transform_local`/`to_world` as statics,
  because one piece is shared by many tiles at different orientations and `DBPF.get_subfile()`
  caches one instance per TGI. Full format notes and the measurements behind the orientation
  handling are in `dev_notes/save_file_analysis` §9.
- **2D sprite props.** Some props have no S3D model at all: traffic lights, the animated
  balloons, the exploratorium crowd. Their exemplar's `ResourceKeyType0` points at an
  `ATCSubfile` (0x29A5D1EC) — a 48-byte header naming an FSH sprite sheet plus one
  `AVPSubfile` (0x09ADCD75) frame table per zoom 0..4. Each AVP frame names a sheet page,
  a pixel rectangle and an anchor pixel. `City.gd`'s "2D (sprite) props" section turns a
  frame into a camera-facing billboard quad (`_place_sprite`, `_resolve_sprite`).
- City-save subfile parsers (occupants placed in a city): `BuildingSubfile` (0xA9BD882D),
  `PropSubfile` (0x2977AA47) and `FloraSubfile` (0xA9C05C85) share one record family
  (Exemplar TGI marker + LE float bbox/position + orientation); `LotBaseTextureSubfile`
  (0xC97F987C) gives per-tile lot ground-texture FSH families (resolve at group
  0x0986135E, instance = family + zoom 0..4); `LotSubfile` (0xC9BD5D4A) is data-only
  (tile rect, zoning, wealth — SC4 denormalizes lot visuals into the other subfiles).
  All are rendered/loaded from `City.gd` (`load_buildings/load_props/load_flora/`
  `load_lot_textures/load_lots`). Because a lot's visuals are scattered over five
  subfiles with nothing linking them back to the lot, **`CityView/Lots/LotModel.gd`** is
  the authority on which lot owns which tile and the only place a lot is removed — see
  the Lots subsystem below.
- `GZWin*.gd` (`GZWin`, `GZWinBtn`, `GZWinText`, `GZWinBMP`, `GZWinFlatRect`, `GZWinGen`) —
  Godot `Control` wrappers for SC4's UI primitives.
- **To add a new SC4 file format:** create a new `extends DBPFSubfile` class in `addons/dbpf/`
  and register it in `Core.type_dict` / `Core.class_dict`.

### Subsystems

- **Region view** (`Region.gd`, `Region.tscn`): scans `Regions/<NAME>/` for `.sc4` city saves,
  reads `config.bmp` (via static `FileAccess.open`) for grid layout, and instantiates a
  `RegionCityView` (`RegionUI/RegionCityView.tscn`) per city from the `SC4ReadRegionalCity`
  subfile (location/size/population). Cities are placed on a `TileMapLayer` `BaseGrid`
  (`RegionGrid.gd`). `SC4UISubfile.gd` parses SC4's XML-like `.UI` layout DSL into a `Control`
  tree; `Region.gd`'s `custom_ui_classes` maps SC4 UI element hex IDs -> scripts in `RegionUI/`
  (one per widget).
- **City view** (`CityView/CityScene/City.gd`, `City.tscn`): builds a 3D terrain `ArrayMesh`
  from the `cSTETerrain__SaveAltitudes` heightmap (or a `FastNoiseLite` fallback), textures
  from FSH via `Texture2DArray` + a terrain shader (`CityView/Meshes/Terrain.gd`), a water
  plane (`CityView/Meshes/WaterPlane.gd`), and an S3D model demo.
- **Transport network** (`CityView/Network/`): `NetworkModel.gd` is the authoritative
  `Vector2i -> Tile` map of what network sits where. It is seeded from the save in
  `City.load_networks()` and is the single choke point for mutation (`place`/`remove`, each
  returning and emitting the dirty cell set), so the renderer and the graph cannot drift
  apart. **Edits are one-way — there is no undo anywhere in the editing stack** (not in
  `NetworkModel`, `LotModel` or `NetworkTool`), so nothing snapshots prior state and
  `remove()` relaxes surviving neighbours' edge codes in place. Note a tile's connected edges are the **union of all `crossings` entries**, not just
  `crossings[0]` — a level crossing puts its second network in `crossings[1..]`. Avenues are
  one network two tiles wide and are handled as a special case throughout.
  `NetworkGraph.gd` derives the routable graph from it and follows every later edit off
  `tiles_changed`. Nodes are **portals** — one lane crossing one boundary, for one traveller
  class — not one node per tile side, so one-way roads and banned turns survive. Arcs come
  one per SC4Path record with class and true length in metres. Neighbouring tiles' portals
  are matched by position, not by declared direction. A tile placed with the **0x80 mirror
  bit drives its lanes backwards** (`SC4PathSubfile.mirrors_traversal`): a mirror reverses
  handedness, and SC4 uses it to build the second carriageway of a two-tile network from the
  same piece, so the record's entry and exit swap and the polyline runs the other way.
  Missing that was what fragmented avenue cities. Big City Tutorial yields 16,770 arcs over
  14,800 nodes, largest car component **100%** of drivable tiles in one component; every
  populated save passes "no two neighbouring drivable tiles in different components", which
  is the assertion the harness makes — a bare component count is not a defect, since Rush
  Hour Tutorial genuinely holds three road systems in disjoint corners of the map.
  `NetworkDebugDraw.gd` draws the graph over the city
  (**G** to toggle, **H** to add pedestrian lanes) — build it before trusting any change to
  the conventions, since a wrong rotation still renders a plausible road network.
  `NetworkPieceDB.gd` loads the 24 RUL files into a piece catalogue keyed by network and
  WNES signature, `NetworkRenderer.gd` (was `TransitTiles.gd`) solves a drag into tiles and
  meshes, and `NetworkTool.gd` owns input and modes. **Keys: R draw, B bulldoze, Esc off,
  `,`/`.` change network (brackets belong to camera rotation), G graph overlay; the HUD
  label lists every hotkey.** The tool starts in NONE — before
  the split, a left-click anywhere in the city unconditionally paved a road. Everything it
  places or removes goes through `NetworkModel`, so the graph follows without the tool
  knowing the graph exists. Each drag operation also has a plain method behind it
  (`draw_line`, `bulldoze`, `bulldoze_box`) so harnesses can drive it without a mouse.
  Drawn roads used to render solid black: the face normals were inverted (`v.cross(u)` on
  two counter-clockwise windings), so a sun overhead lit nothing and this scene's ambient
  comes from a background with a 0 energy multiplier. The transit shader is `unshaded` now
  as well, matching the save's own network quads; see the header of `NetworkRenderer.gd`.
  **Drawing across an existing road** makes a real intersection. The drag solver
  reconciles a drag against `network_tiles` (what this renderer drew) *and* `NetworkModel`
  (which is the only record of the save's roads) — see `NetworkRenderer._existing_edges`.
  Consulting `network_tiles` alone laid a straight piece over the crossed road: the road
  still looked continuous, because the save's own quad was still drawn underneath, while
  the model record claimed two edges instead of four, so its arcs stopped dead at the
  junction. `City._on_network_tiles_changed` therefore withdraws a save quad when the tile
  is *replaced* as well as when it is bulldozed. Crossing a **different** network keeps the
  other network's `crossings` entry so the model does not lose it, but the piece still comes
  from the drag network's RUL table — real level-crossing pieces are not implemented.
  The three incremental-graph defects recorded here previously (Making Money Tutorial's
  `incremental removal matches a full rebuild`, Tegel/Kensington's `undo restored the graph
  exactly`, back when undo existed) were **one bug in `NetworkGraph._drop_boundary`**,
  which erased a boundary's
  whole node roster. A portal still carrying an undisturbed neighbour's arcs survived in
  `nodes` but vanished from `nodes_by_boundary`, so the next `_stitch_boundary` saw only
  the freshly emitted half and had nothing to pair it with — a boundary that was joined
  before the edit and silently came apart after it. It keeps the survivors now, and
  `_ensure_node` registers idempotently. All nine populated saves pass.
  `CityView/ClassDefinitions/` still holds the older, unwired sketches (`NetGraphNode`,
  `NetGraphEdge`, `NetTile`), kept only because `NetworkRenderer.gd` still references them.
- **Lots** (`CityView/Lots/LotModel.gd`): `Vector2i -> LotRecord`, and the single choke
  point for removing a lot — the same role `NetworkModel` plays for network tiles, for the
  same reason. A lot draws through **five** subfiles (buildings, props, flora, base
  textures, foundations/retaining walls) and none of them records which lot it belongs to,
  so removal has to happen in one place or a bulldozed lot leaves its building standing on
  the road, or its lawn, or its foundations. `City.gd` follows `lots_changed`
  (`_on_lots_changed`) and rebuilds only the affected batches: `lot_texture_tiles` /
  `lot_structure_items` keep their membership so a family can be re-emitted minus the dead
  cells, and `occupant_nodes` indexes every placed occupant node by tile, which is the only
  route from "bulldoze this lot" to the geometry that has to go.
  **Only growable lots are bulldozable by the tools.** `zone_type` 1–9 (R/C/I by density)
  is growable; 15 and the special zones are plopped and a road will not eat them —
  `LotModel.is_growable` is the whole test. A lot always comes out **whole**, even when a
  road only clips its corner: half a lot has no meaning in any of the subfiles.
  `NetworkTool` razes lots on both paths — a drag calls `_raze_lots(renderer.pending_cells())`
  before committing the tiles, and the bulldozer boxes over lots whether or not a network
  tile is there (`bulldoze_box_cells` is the whole box now; `bulldoze_cells` is the subset
  holding tiles). Razing is **permanent** — there is no undo, so a bulldozed lot's
  occupants are freed outright rather than kept for a restore.
  **Not implemented:** the draw preview highlights the road but not the lots it is about
  to flatten (the bulldoze preview does show them, whole lots included).
- **Simulation** (`CityView/Simulation.gd` + `CityView/Sim/`): the game clock and the field
  simulators — `dev_notes/simulation_plan.md` steps 2–4, executed 2026-08-07 (session log:
  `dev_notes/save_file_analysis` §13). `Simulation` is a monthly tick owned by City
  (`city.simulation`, systems kept in `city.sim_systems`); systems run in dependency order
  **traffic → pollution → land value → crime**, each reading the models (LotModel,
  `building_records`, NetworkModel/graph) and committing whole derived fields into
  `SimGrids` (`DERIVED_*`), off whose `grids_changed` the data views repaint. The clock
  starts **paused**; **Space** cycles pause/1x/3x (5 s per month at 1x); one tick runs at
  city load so the fields exist; harnesses call `simulation.step()` directly and never rely
  on frame time. Simulation properties (pollution magnitudes/radii, flammability, police
  coverage) live on the building FAMILY'S COHORT, not its exemplar — `Core.exemplar_prop`
  walks the parent chain (CQZB cohort support in `ExemplarSubfile`). What is SC4's data vs
  our invention is documented per file: Land Value Sim exemplar curves + boundaries [70,120]
  and Traffic Simulator speeds are authentic; `PollutionSim.SOURCE_SCALE` (2.0),
  `LandValueSim` base 5 / neighbourhood-wealth ×45 / pollution −30 (fitted offline: mean
  0.82 / worst 0.57 wealth agreement) and the crime scaling are ours. TrafficSim assigns one
  commute per residential lot to the nearest job via one backwards multi-source Dijkstra +
  gradient descent over car arcs. Harness gates (`_check_simulation`): fixed point over 3
  edit-free months (byte-identical fields), land value ≥0.50 agreement, dirty industry
  (zones 8–9 ONLY — zone 7 farms absorb) outpollutes residential, $ crime > $$$ crime,
  traffic precision ≥0.85 + rank correlation ≥0.10 vs `TRAFFIC_CAR`, and razing a polluting
  lot lowers the field at its tile (the victim must stamp positively AND sit inside the
  clamp range). All 12 populated saves pass.
- **DAT Explorer** (`DATExplorer/`): a `Tree` browser over loaded DBPF archives with TGI
  filters and subfile previews. Dev tool.

### Threading

Single loader `Thread` in `BootScreen` plus `call_deferred` marshaling. **No `Mutex`,
`Semaphore`, or `WorkerThreadPool` anywhere** — keep it that way unless genuinely necessary.

### Conventions
**Indentation is 4 SPACES everywhere.** Keep the Godot editor's
  `text_editor/behavior/indent/type` set to **spaces** (size 4).