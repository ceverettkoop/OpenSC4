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
  (3D models), `LTEXTSubfile` (UTF-16 strings), `ImageSubfile` (PNG), `RULSubfile` (network
  rules), `CURSubfile` (cursors), `INISubfile`.
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
  plane (`CityView/Meshes/WaterPlane.gd`), and an S3D model demo. `CityView/ClassDefinitions/`
  holds the (future) transit network graph model (`NetGraphNode`, `NetGraphEdge`, etc.).
- **DAT Explorer** (`DATExplorer/`): a `Tree` browser over loaded DBPF archives with TGI
  filters and subfile previews. Dev tool.

### Threading

Single loader `Thread` in `BootScreen` plus `call_deferred` marshaling. **No `Mutex`,
`Semaphore`, or `WorkerThreadPool` anywhere** — keep it that way unless genuinely necessary.

## Conventions & gotchas

- **Indentation is TABS everywhere.** Set the Godot editor's
  `text_editor/behavior/indent/type` to **tabs**. If it's set to spaces, the editor/import
  rewrites `.gd` files and produces giant whitespace diffs.
- **Do NOT rename the `Log` autoload to `Logger`.** Godot 4.5+ ships a native `Logger` class
  that would shadow the autoload and break every `Log.*` call site.
- In Godot 4, `FileAccess.open()`, `ImageTexture.create_from_image()`, and
  `Image.create_from_data()` are **STATIC factories** that return the object (or `null` on
  failure). Never call them instance-style.

## Known issues / TODO

- `City.tscn` embedded shaders still contain **Godot 3 GLSL** (removed `DEPTH_TEXTURE`, `PI`
  redefinition) — needs a shader port before the city view renders correctly.
- `utils/debug_ui/loading_icon_spinning.tres` references `load0.png`..`load7.png` that were
  never committed — orphaned resource.
- `BootScreen.load_single_DAT` progress-bar update is marked with a
  `# this doesn't seem to actually occur` comment.
