extends DBPFSubfile

# Parses SC4's network subfile 2 (type 0xCA16374F, the bridge / elevated
# network occupants) from a city save. Of the saves shipped with the game,
# only Regions/Timbuktu/City - Rush Hour Tutorial.sc4 has one -- a 16-tile
# bridge running down tile column 7.
#
# The record opens with the same family head as the pipe subfile -- version,
# zot, appearance, the 0xC772BF98 marker, tract, sgprops, Exemplar TGI -- then
# an optional 3x3 orientation matrix (present when the flag byte is 0x05),
# the deck position, and the four deck-corner vertices with their texture
# coordinates and baked lighting colour, exactly as the ground networks store
# them. That is everything needed to draw the deck.
#
# PARTIAL BY DESIGN: roughly 390 bytes at the end of each record -- pillar
# placement, side textures and whatever else SC4 keeps for a span -- are not
# decoded. The `sc4` savegame library documents a version-3 layout for this
# type; the shipped save is version 2.3 and does not match it. We stop after
# the crossings and skip to the next record using the record's own size
# prefix, which is safe. Consequence: deck and railings draw, bridge pillars
# do not.
class_name BridgeNetworkSubfile

const FAMILY_MARKER : int = 0xc772bf98
const MATRIX_PRESENT : int = 0x05
const APPEARANCE_PRESENT : int = 0x01

class BridgeTile:
    var network_type : int
    var appearance : int
    var model_id : int            # FSH family for the deck surface
    var base_texture : int
    var wealth_texture : int
    var orientation : int
    var position : Vector3        # metres, tile centre
    var vertices : Array          # 4 Vertex -- the deck quad
    var crossings : Array
    var exemplar_tgi : Array

    func tile_x() -> int:
        return int(position.x / 16.0)

    func tile_z() -> int:
        return int(position.z / 16.0)

    func is_present() -> bool:
        return (appearance & APPEARANCE_PRESENT) != 0

var tiles : Array = []
var layout_failures : int = 0

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)
    var n = raw_data.size()
    var buf = StreamPeerBuffer.new()
    buf.data_array = raw_data
    var pos = 0
    while pos + 4 <= n:
        var size = _u32(pos)
        if size < 4 or pos + size > n:
            break
        var tile = _read_tile(buf, pos, size)
        if tile != null:
            tiles.append(tile)
        pos += size
    if layout_failures > 0:
        Log.warn("BridgeNetworkSubfile: %d of %d records failed a layout check"
            % [layout_failures, tiles.size() + layout_failures])
    return OK

func _read_tile(buf : StreamPeerBuffer, pos : int, size : int):
    buf.seek(pos)
    _read_record_header(buf)
    var tile = BridgeTile.new()

    buf.get_u16()                     # zot
    buf.get_u8()                      # unknown
    buf.get_u32()                     # unknown
    tile.appearance = buf.get_u8()
    if buf.get_u32() != FAMILY_MARKER:
        Log.warn("BridgeNetworkSubfile: record at %d failed the family-marker layout check" % pos)
        layout_failures += 1
        return null
    buf.seek(buf.get_position() + 8)  # tract
    _read_sgprops(buf)
    tile.exemplar_tgi = [buf.get_u32(), buf.get_u32(), buf.get_u32()]
    if buf.get_u8() == MATRIX_PRESENT:
        buf.seek(buf.get_position() + 36)

    tile.position = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
    tile.vertices = [_read_vertex(buf), _read_vertex(buf), _read_vertex(buf), _read_vertex(buf)]

    tile.model_id = buf.get_u32()
    tile.wealth_texture = buf.get_u8()
    tile.base_texture = buf.get_u32()
    tile.orientation = buf.get_u8()
    buf.get_u16()                     # unknown

    var crossing_count = buf.get_u8() + 1
    for _i in range(crossing_count):
        if buf.get_position() + 5 > pos + size:
            Log.warn("BridgeNetworkSubfile: record at %d ran past its end reading crossings" % pos)
            layout_failures += 1
            return null
        tile.crossings.append({
            "type": buf.get_u8(),
            "west": buf.get_u8(),
            "north": buf.get_u8(),
            "east": buf.get_u8(),
            "south": buf.get_u8(),
        })
    tile.network_type = tile.crossings[0]["type"]
    # The remainder of the record is undecoded; the caller advances by `size`.
    return tile
