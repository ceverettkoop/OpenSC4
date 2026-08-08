extends RefCounted

# The city's simulation-data layers as a model: every SimGrid of the save,
# keyed by dataId, plus the map size needed to address coarse grids by tile.
# The SAVED grids are read-only -- they are SC4's own simulation output, the
# ground truth our simulators are calibrated against, and nothing in OpenSC4
# writes them back. Known dataIds are named on SimGridSubfile (TRAFFIC_*,
# OCCUPANT_CODE, FLAMMABILITY_*, ZONE_TYPE); everything else is carried
# unnamed.
#
# Alongside the snapshot live the DERIVED layers: writable grids owned by our
# own simulators (Simulation.gd systems), keyed by the DERIVED_* ids below --
# deliberately far outside the dataId range any save uses, so the two can
# never collide in value_at_tile. Systems commit a whole field per tick and
# grids_changed carries the ids, which is what the data views repaint off.
class_name SimGrids

signal grids_changed(ids : Array)

# Ids for the derived layers. Not SC4 dataIds: no saved grid uses the
# 0xFFDExxxx range (Appendix A of dev_notes/save_file_analysis inventories
# them all), so a derived id can never shadow a snapshot layer by accident.
const DERIVED_AIR_POLLUTION : int = 0xFFDE0001   # 0..1024, the air view's "maximum scale" domain
const DERIVED_LAND_VALUE : int = 0xFFDE0002      # 1..255, the land-value ramp domain
const DERIVED_CRIME : int = 0xFFDE0003           # 0..255, the crime ramp domain
const DERIVED_TRAFFIC : int = 0xFFDE0004         # commute volume per tile (step 4)
const DERIVED_POLICE_COVERAGE : int = 0xFFDE0005 # police station coverage, arbitrary units

var grids : Dictionary = {}      # dataId -> SimGridSubfile.Grid (immutable snapshot)
var derived : Dictionary = {}    # DERIVED_* id -> SimGridSubfile.Grid (simulator-owned)
var map_tiles : int = 0          # city edge length in tiles (e.g. 128)
var layout_failures : int = 0    # records whose header failed validation

static func from_save(savefile, map_tiles_ : int) -> SimGrids:
    var out := SimGrids.new()
    var stats := {}
    out.grids = SimGridSubfile.load_all(savefile, stats)
    out.layout_failures = stats.get("layout_failures", 0)
    out.map_tiles = map_tiles_
    return out

func has(data_id : int) -> bool:
    return derived.has(data_id) or grids.has(data_id)

func grid(data_id : int):
    if derived.has(data_id):
        return derived[data_id]
    return grids.get(data_id)

func size() -> int:
    return grids.size()

# Replaces (or creates) one derived layer from a flat column-major Array
# (index = x * side + z, matching the save's own layout) and announces it.
# Whole-field commits, not cell pokes: every simulator recomputes its field
# per tick, so there is nothing incremental to signal about.
func commit_derived(data_id : int, values : Array, side : int) -> void:
    var g := SimGridSubfile.Grid.new()
    g.data_id = data_id
    g.width = side
    g.height = side
    g.values = values
    derived[data_id] = g
    grids_changed.emit([data_id])

# Value of a layer at a map tile. Derived layers win over the snapshot (their
# ids never collide, so this is belt and braces, not shadowing). Grids coarser
# than the map (64x64, 32x32, 16x16) cover several tiles per cell; Grid.at_tile
# handles the scaling. Unknown layers and out-of-range tiles read as 0.
func value_at_tile(data_id : int, tile_x : int, tile_z : int) -> float:
    var g = grid(data_id)
    if g == null:
        return 0.0
    return g.at_tile(tile_x, tile_z, map_tiles)

# Largest cell value of a layer, for normalization and legends. 0 for an
# unknown or all-zero layer.
func max_value(data_id : int) -> float:
    var g = grid(data_id)
    if g == null:
        return 0.0
    var best : float = 0.0
    for v in g.values:
        if v > best:
            best = v
    return best
