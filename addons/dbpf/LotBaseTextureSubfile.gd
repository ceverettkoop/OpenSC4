extends DBPFSubfile

# Parses SC4's lot base-texture subfile (type 0xC97F987C) from a city save:
# the ground textures (lawn, pavement, dirt...) drawn under each developed lot.
# One record per lot; each record carries per-TILE entries giving the FSH
# texture family, absolute city tile coordinate, rotation and a tint.
#
# The FSH itself lives at TGI (0x7AB50E44, 0x0986135E, family_iid + zoom) with
# zoom 0..4 (64x64 .. 256x256); rotation is applied at render time.
# Layout verified against every record of a developed save (and against the
# open-source `sc4` savegame library's lot-base-texture parser).
class_name LotBaseTextureSubfile

# Record-relative offsets: size(4) crc(4) mem(4) major(2) minor(2) unknown(4)
# 0x497F6D9D(4) tract(8) unknown(16) bbox(6 LE floats) unknown(1) count(4).
const OFF_BBOX : int = 48
const OFF_COUNT : int = 73
const ENTRY_SIZE : int = 14

class TextureTile:
    var iid : int                 # FSH instance family (add zoom 0..4)
    var x : int                   # absolute city tile column
    var z : int                   # absolute city tile row
    var orientation : int         # 0..3, quarter-turns
    var priority : int            # draw order within the tile
    var color : Color             # tint (usually opaque white)

var tiles : Array = []

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)        # raw_data is now decompressed
    var n = raw_data.size()
    var pos = 0
    while pos + 4 <= n:
        var size = _u32(pos)
        if size < 4 or pos + size > n:
            break
        var count = _u32(pos + OFF_COUNT)
        var entry = pos + OFF_COUNT + 4
        if entry + ENTRY_SIZE * count == pos + size:
            for k in range(count):
                var o = entry + ENTRY_SIZE * k
                var t = TextureTile.new()
                t.iid = _u32(o)
                t.x = raw_data[o + 4]
                t.z = raw_data[o + 5]
                t.orientation = raw_data[o + 6]
                t.priority = raw_data[o + 7]
                t.color = Color8(raw_data[o + 8], raw_data[o + 9], raw_data[o + 10], raw_data[o + 11])
                tiles.append(t)
        else:
            Log.warn("LotBaseTextureSubfile: record at %d failed the entry-count layout check" % pos)
        pos += size
    return OK

# Little-endian u32 read straight from raw_data.
func _u32(o : int) -> int:
    return raw_data[o] | (raw_data[o + 1] << 8) | (raw_data[o + 2] << 16) | (raw_data[o + 3] << 24)
