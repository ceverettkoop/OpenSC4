extends DBPFSubfile

# Parses SC4's ground-network subfile (type 0xC9C05C6E, cSC4NetworkOccupant)
# from a city save: one record per network TILE -- roads, streets, avenues,
# one-way roads, dirt roads and rail, everything that lies on the ground.
#
# The key thing about these records is that SC4 has already done the hard work.
# It resolved the RUL tile-shape rules at build time and saved the result, so
# each record carries the finished quad: four vertices with position, texture
# coordinate and baked lighting colour, plus the id of the texture to stretch
# over them. Drawing the network is therefore a direct read -- no RUL
# evaluation, no WNES edge-code derivation, no tile-piece lookup.
#
# The texture ids live at TGI (0x7AB50E44, 0x1ABE787D, id + zoom) for zoom 0..4,
# the same scheme CityView/Meshes/TransitTiles.gd uses for the build tool. The
# high byte of the id is the network family documented in RULSubfile.gd:
# 0x00 road, 0x03 rail, 0x05 street, 0x04 avenue, 0x09 one-way road...
#
# Layout verified byte-exact (bytes consumed == record size for every record)
# against all 3,335 tiles of Big City Tutorial and the network subfiles of the
# seven other populated saves in Regions/. It matches the Network class of the
# open-source `sc4` savegame library.
class_name NetworkSubfile

# Sits at a fixed offset in every record of this family; used as a layout check.
const FAMILY_MARKER : int = 0xc772bf98

# networkType values, per the community's decoding of the same byte.
const NETWORK_TYPE_NAMES : Array = [
    "Road", "Rail", "Maxis El Highway", "Street", "Pipe", "Powerline",
    "Avenue", "Subway", "Light Rail", "Monorail", "One-Way Road", "Dirt Road",
]

# appearance bit 0: the tile is present in the city. Cleared means deleted --
# SC4 leaves the record behind rather than compacting the array.
const APPEARANCE_PRESENT : int = 0x01
const APPEARANCE_BURNT : int = 0x40

class NetworkTile:
    var network_type : int        # index into NETWORK_TYPE_NAMES
    var appearance : int          # bit flags, see APPEARANCE_*
    var texture_id : int          # FSH family for the network surface
    var base_texture : int        # FSH family for the ground underneath it
    var wealth_texture : int      # sidewalk wealth variant, 0..3
    var orientation : int         # 0..3 quarter-turns; 0x80 bit seen set
    var position : Vector3        # metres, tile centre; Y is up
    var vertices : Array          # 4 Vertex, corners in metres, with uv/colour
    var crossings : Array         # [{type, west, north, east, south}], >= 1
    var walls : Array             # [{texture, vertex}], embankment sides
    var bbox : AABB               # metres
    var exemplar_tgi : Array      # [type, group, instance]; all zero on ground tiles
    var construction_states : int
    var alternate_path_id : int

    # Absolute city tile coordinate (1 tile = 16 metres).
    func tile_x() -> int:
        return int(position.x / 16.0)

    func tile_z() -> int:
        return int(position.z / 16.0)

    func is_present() -> bool:
        return (appearance & APPEARANCE_PRESENT) != 0

var tiles : Array = []
# Records whose parsed length disagreed with their declared size. A non-zero
# count means the layout is wrong for this save and the tiles cannot be trusted.
var layout_failures : int = 0

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)        # raw_data is now decompressed
    var n = raw_data.size()
    var buf = StreamPeerBuffer.new()
    buf.data_array = raw_data
    var pos = 0
    while pos + 4 <= n:
        var size = _u32(pos)
        if size < 4 or pos + size > n:
            break
        var tile = _read_tile(buf, pos)
        if tile != null:
            tiles.append(tile)
        pos += size
    if layout_failures > 0:
        Log.warn("NetworkSubfile: %d of %d records failed the record-size layout check"
            % [layout_failures, tiles.size() + layout_failures])
    return OK

func _read_tile(buf : StreamPeerBuffer, pos : int):
    buf.seek(pos)
    var header = _read_record_header(buf)
    var tile = NetworkTile.new()

    buf.get_u16()                     # zot
    buf.get_u8()                      # unknown
    tile.appearance = buf.get_u8()
    if buf.get_u32() != FAMILY_MARKER:
        Log.warn("NetworkSubfile: record at %d failed the family-marker layout check" % pos)
        layout_failures += 1
        return null
    buf.seek(buf.get_position() + 8)  # tract: min/max x/z bytes, two u16 sizes
    _read_sgprops(buf)
    tile.exemplar_tgi = [buf.get_u32(), buf.get_u32(), buf.get_u32()]  # group, type, instance
    buf.get_u8()                      # unknown

    tile.position = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
    tile.vertices = [_read_vertex(buf), _read_vertex(buf), _read_vertex(buf), _read_vertex(buf)]

    tile.texture_id = buf.get_u32()
    tile.wealth_texture = buf.get_u8()
    tile.base_texture = buf.get_u32()
    tile.orientation = buf.get_u8()
    buf.get_u16()                     # unknown

    # The crossing count is stored one less than the real count; the first
    # crossing carries the tile's own network type and its WNES connections.
    var crossing_count = buf.get_u8() + 1
    for _i in range(crossing_count):
        tile.crossings.append({
            "type": buf.get_u8(),
            "west": buf.get_u8(),
            "north": buf.get_u8(),
            "east": buf.get_u8(),
            "south": buf.get_u8(),
        })
    tile.network_type = tile.crossings[0]["type"]

    var wall_count = buf.get_u32()
    for _i in range(wall_count):
        tile.walls.append({"texture": buf.get_u32(), "vertex": _read_vertex(buf)})

    tile.bbox = _read_bbox(buf, true)  # this family groups the bbox by axis
    tile.construction_states = buf.get_u32()
    tile.alternate_path_id = buf.get_u32()
    buf.seek(buf.get_position() + 12)  # unknown
    buf.get_64()                       # demolishing costs

    if buf.get_position() - pos != header.size:
        Log.warn("NetworkSubfile: record at %d consumed %d bytes, declared %d"
            % [pos, buf.get_position() - pos, header.size])
        layout_failures += 1
        return null
    return tile

# {network type name: tile count}, for logging and harness assertions.
func type_histogram() -> Dictionary:
    var hist = {}
    for tile in tiles:
        var name = NETWORK_TYPE_NAMES[tile.network_type] if tile.network_type < NETWORK_TYPE_NAMES.size() else "0x%02x" % tile.network_type
        hist[name] = hist.get(name, 0) + 1
    return hist
