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
  is the case a clear-ground-only test cannot reach. Known failure: **Getting Started
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
  `tx,tz,zoom[,rot][,name]` and the bare keywords `pipes`, `graph`, `walking` and `hold`.
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
  cells are **column-major, `index = x * height + z`**. Loaded on demand via
  `City.load_sim_grids()`, not at city load. The traffic layers are SC4's own simulation
  output and are used as ground truth for the network graph — see `dev_notes` §11.
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
  `load_lot_textures/load_lots`).
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
  `City.load_networks()` and is the single choke point for mutation (`place`/`remove`/`undo`,
  each returning and emitting the dirty cell set), so the renderer and the graph cannot drift
  apart. Note a tile's connected edges are the **union of all `crossings` entries**, not just
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
  `[`/`]` change network, Ctrl+Z undo, G graph overlay.** The tool starts in NONE — before
  the split, a left-click anywhere in the city unconditionally paved a road. Everything it
  places or removes goes through `NetworkModel`, so the graph follows without the tool
  knowing the graph exists. Each drag operation also has a plain method behind it
  (`draw_line`, `bulldoze`, `bulldoze_box`, `undo`) so harnesses can drive it without a mouse.
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
  is *replaced* as well as when it is bulldozed, and `NetworkRenderer.resync` gives the cell
  back on undo. Crossing a **different** network keeps the other network's `crossings`
  entry so the model does not lose it, but the piece still comes from the drag network's
  RUL table — real level-crossing pieces are not implemented.
  The three incremental-graph defects recorded here previously (Making Money Tutorial's
  `incremental removal matches a full rebuild`, Tegel/Kensington's `undo restored the graph
  exactly`) were **one bug in `NetworkGraph._drop_boundary`**, which erased a boundary's
  whole node roster. A portal still carrying an undisturbed neighbour's arcs survived in
  `nodes` but vanished from `nodes_by_boundary`, so the next `_stitch_boundary` saw only
  the freshly emitted half and had nothing to pair it with — a boundary that was joined
  before the edit and silently came apart after it. It keeps the survivors now, and
  `_ensure_node` registers idempotently. All nine populated saves pass.
  `CityView/ClassDefinitions/` still holds the older, unwired sketches (`NetGraphNode`,
  `NetGraphEdge`, `NetTile`), kept only because `NetworkRenderer.gd` still references them.
- **DAT Explorer** (`DATExplorer/`): a `Tree` browser over loaded DBPF archives with TGI
  filters and subfile previews. Dev tool.

### Threading

Single loader `Thread` in `BootScreen` plus `call_deferred` marshaling. **No `Mutex`,
`Semaphore`, or `WorkerThreadPool` anywhere** — keep it that way unless genuinely necessary.

### Conventions
**Indentation is 4 SPACES everywhere.** Keep the Godot editor's
  `text_editor/behavior/indent/type` set to **spaces** (size 4).