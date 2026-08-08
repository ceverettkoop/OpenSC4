extends DBPFSubfile

# Parses SC4's simulation data grids -- the per-tile layers behind every data
# view: pollution, land value, crime, traffic volume and about 130 more.
#
# Six savegame types share one record layout, differing only in cell width:
#
#   0x49B9E602 SimGridUint8     0x49B9E603 SimGridSint8
#   0x49B9E604 SimGridUint16    0x49B9E605 SimGridSint16
#   0x49B9E606 SimGridUint32    0x49B9E60A SimGridFloat32
#
# Each subfile holds SEVERAL grids, one record each, keyed by a dataId -- the
# game's GUID for that layer. Big City Tutorial has 136 grids across the six
# types, at 128x128 (one cell per tile), 64x64, 32x32 and 16x16.
#
# What makes this worth parsing now is that the traffic layers are SC4's own
# simulation output, saved per tile. That gives the network graph a ground truth
# to check itself against: a tile the graph calls unreachable that SC4 gave
# nonzero traffic is a graph bug, and the reverse likewise. See TRAFFIC_* below.
#
# Header offsets verified against all 136 grids of Big City Tutorial -- every
# one satisfies xSize * zSize * cell_size == remaining bytes.
class_name SimGridSubfile

const TYPE_UINT8 : int = 0x49b9e602
const TYPE_SINT8 : int = 0x49b9e603
const TYPE_UINT16 : int = 0x49b9e604
const TYPE_SINT16 : int = 0x49b9e605
const TYPE_UINT32 : int = 0x49b9e606
const TYPE_FLOAT32 : int = 0x49b9e60a

const ALL_TYPES : Array = [
    TYPE_UINT8, TYPE_SINT8, TYPE_UINT16, TYPE_SINT16, TYPE_UINT32, TYPE_FLOAT32,
]

# Bytes per cell, by subfile type.
const CELL_SIZE : Dictionary = {
    TYPE_UINT8: 1, TYPE_SINT8: 1, TYPE_UINT16: 2,
    TYPE_SINT16: 2, TYPE_UINT32: 4, TYPE_FLOAT32: 4,
}

# Fixed offsets within a record. The 55-byte header is
#   u32 size, u32 crc, u32 mem, u16 major, u8, u32 ownType, u32 dataId,
#   u32 ?, u32 ?, u32 xSize, u32 zSize, u32 ?, f32 16.0, f32 0.0625, u32 ?
# then raw cells.
const OFF_DATA_ID : int = 19
const OFF_X_SIZE : int = 31
const OFF_Z_SIZE : int = 35
const HEADER_SIZE : int = 55

# Traffic layers, identified by correlating each 128x128 grid's nonzero
# footprint against the city's actual network tiles. On Big City Tutorial these
# five score a Jaccard index of 0.951 to 0.998 against the 3,335 network tiles,
# where the next-best non-network grid scores 0.269 -- so the identification is
# not marginal. The names are inferred from that footprint and from how the
# values distribute across road, street and rail, NOT read from a label, so
# treat them as "the grid that behaves like X" rather than as gospel.
#
# TRAFFIC_TOTAL is nonzero on every network tile including rail; TRAFFIC_CAR is
# near-zero on rail (4 of 139 tiles) while nonzero on every road and street,
# which is what makes it the useful one for checking the car graph.
const TRAFFIC_TOTAL : int = 0x69d5c3ac      # f32, nonzero on all 3,335 tiles
const TRAFFIC_CAR : int = 0x69d5c3e1        # f32, near-zero on rail
const TRAFFIC_CONGESTION : int = 0x69d5c40e # f32, small values, looks like a ratio
const TRAFFIC_WALK : int = 0x69d5c402       # u8, heaviest on streets
const TRAFFIC_CAR_ALT : int = 0x89d5c3a2    # u8, near-zero on rail

# Zone-occupant codes, u8 128x128 -- the save's wealth grid. No shipped save
# stores a continuous land-value layer (SC4 recomputes land value at load;
# every candidate grid was checked against per-tile lot wealth across four
# saves and none has that profile). What IS saved is this layer: which
# occupant family developed each tile, as family-base-plus-wealth codes.
# Identified the same way as TRAFFIC_*: empirically, not from a label --
# crosstabbed against per-tile lot zone_wealth over all 12 populated saves,
# every nonzero code maps to exactly one wealth class with zero exceptions.
const OCCUPANT_CODE : int = 0x49d5b678      # u8, decode with OCCUPANT_CODE_WEALTH

# Flammability, u8 128x128, a pair. Identified per building: stamping each
# building exemplar's "Flammability" property (0x29244DB5, resolved through
# the family cohort chain) over its lot rect reproduces FLAMMABILITY_BASE
# exactly on 78.6% of nonzero cells of Big City Tutorial, and the dominant
# values ARE the property values verbatim (R$ families 40, dirty industry
# 80); the remainder are small decays (38 for 40) and lot garden tiles
# carrying their trees' value instead of the house's. The two grids share
# one footprint and EFFECTIVE = BASE * 1.25 on all but 85 of 7,816 cells --
# 1.25 matching the "Flammability multiplier, summer" property family.
# NOTE: dev_notes/simulation_plan.md nominated this pair as the prime AIR
# POLLUTION candidates ("smooth twins"); that guess was wrong, and with it
# ruled out the save stores no pollution field at all.
const FLAMMABILITY_BASE : int = 0x49d5b964
const FLAMMABILITY_EFFECTIVE : int = 0x49d5b953

# Zone type per tile, u8 128x128, verbatim from the lot records: crosstab
# against lot zone_type over Big City Tutorial is single-valued on every
# zone (1->1, 4->4, 8->8, 9->9, 15->15), plus 14 on the special-zone tiles
# no lot claims. The harness gates on this equivalence.
const ZONE_TYPE : int = 0x41800000

# NOT identified, but ruled out as crime (the plan's guess for them):
# 0x49D5BB8C / 0x49D5BBA1 are a near-identical pair of small bitfields
# (values 0,1,2,3,8,9,10,11,15) that light up developed tiles and follow
# power-line corridors on Big City Tutorial -- power-ish -- but only 19% of
# Tegel's lot tiles carry a value, so no power hypothesis survives all the
# saves and no gate can be built. Left unnamed until someone explains Tegel.

# code -> wealth 0..3 (none/$/$$/$$$), from that crosstab. Families read as
# 0 vacant/abandoned, 1 plopped civic, 6/7/8 R$/R$$/R$$$, 10/11/12 CS,
# 15/16 CO$$/CO$$$, 22 farm, 27/31 heavier industry. Codes not in the table
# have never been observed; treat them as wealth 0.
const OCCUPANT_CODE_WEALTH : Dictionary = {
    0: 0, 1: 0,
    6: 1, 7: 2, 8: 3,
    10: 1, 11: 2, 12: 3,
    15: 2, 16: 3,
    22: 1, 27: 2, 31: 2,
}

class Grid:
    var data_id : int
    var width : int
    var height : int
    var values : Array = []      # row-major by the accessor below, not raw order

    # Cells are stored column-major: index = x * height + z. Verified by
    # correlation -- reading it the other way scores 0.247 against the network
    # footprint where this scores 0.998, so a transpose here would look almost
    # but not quite right.
    func at(x : int, z : int) -> float:
        if x < 0 or z < 0 or x >= width or z >= height:
            return 0.0
        return values[x * height + z]

    # Grids coarser than the map cover several tiles per cell.
    func at_tile(tile_x : int, tile_z : int, map_tiles : int) -> float:
        if map_tiles <= 0:
            return 0.0
        var scale : float = float(width) / float(map_tiles)
        return at(int(tile_x * scale), int(tile_z * scale))

    func nonzero_cells() -> Array:
        var out : Array = []
        for x in range(width):
            for z in range(height):
                if values[x * height + z] != 0:
                    out.append(Vector2i(x, z))
        return out

var grids : Dictionary = {}      # dataId -> Grid
var layout_failures : int = 0

func _init(index):
    super._init(index)

func load(file, dbdf = null):
    super.load(file, dbdf)
    var cell_size : int = CELL_SIZE.get(index.type_id, 0)
    if cell_size == 0:
        Log.warn("SimGridSubfile: type %08X is not a SimGrid" % index.type_id)
        layout_failures += 1
        return OK

    var total := raw_data.size()
    var buf := StreamPeerBuffer.new()
    buf.data_array = raw_data
    var pos := 0
    while pos + HEADER_SIZE <= total:
        var size := _u32(pos)
        if size < HEADER_SIZE or pos + size > total:
            break
        var grid := Grid.new()
        grid.data_id = _u32(pos + OFF_DATA_ID)
        grid.width = _u32(pos + OFF_X_SIZE)
        grid.height = _u32(pos + OFF_Z_SIZE)
        var payload := size - HEADER_SIZE
        if grid.width * grid.height * cell_size != payload:
            Log.warn("SimGridSubfile: grid %08X declares %dx%d but has %d payload bytes"
                % [grid.data_id, grid.width, grid.height, payload])
            layout_failures += 1
            pos += size
            continue
        buf.seek(pos + HEADER_SIZE)
        grid.values = _read_cells(buf, index.type_id, grid.width * grid.height)
        grids[grid.data_id] = grid
        pos += size
    return OK

func _read_cells(buf : StreamPeerBuffer, type_id : int, count : int) -> Array:
    var out : Array = []
    out.resize(count)
    for i in range(count):
        match type_id:
            TYPE_UINT8: out[i] = buf.get_u8()
            TYPE_SINT8: out[i] = buf.get_8()
            TYPE_UINT16: out[i] = buf.get_u16()
            TYPE_SINT16: out[i] = buf.get_16()
            TYPE_UINT32: out[i] = buf.get_u32()
            TYPE_FLOAT32: out[i] = buf.get_float()
    return out

func has_grid(data_id : int) -> bool:
    return grids.has(data_id)

func grid(data_id : int):
    return grids.get(data_id)

# Loads every SimGrid subfile of a save into one dataId -> Grid dictionary.
# `stats`, when supplied, receives {"layout_failures": int, "subfiles": int}
# so callers (the headless harness) can assert on parse health -- otherwise
# each subfile's layout_failures counter would be silently discarded here.
static func load_all(savefile, stats : Dictionary = {}) -> Dictionary:
    var out : Dictionary = {}
    var failures := 0
    var subfile_count := 0
    for type_id in ALL_TYPES:
        for idx in savefile.indices_by_type.get(type_id, []):
            var sub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, SimGridSubfile)
            if sub == null:
                continue
            subfile_count += 1
            failures += sub.layout_failures
            for data_id in sub.grids.keys():
                out[data_id] = sub.grids[data_id]
    stats["layout_failures"] = failures
    stats["subfiles"] = subfile_count
    return out
