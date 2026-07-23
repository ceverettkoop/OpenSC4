extends DBPFSubfile

# Parses SC4's Flora occupant subfile (type 0xA9C05C85) from a city save:
# god/mayor-mode trees and shrubs (lot trees are props instead). Fixed 78-byte
# records in the Building/Prop record family, but with a single position point
# after the Exemplar reference rather than a bbox, then two planted-date dwords
# and the orientation byte. Offsets verified across every record of a
# developed save.
class_name FloraSubfile

const EXEMPLAR_TYPE : int = 0x6534284a
# Offsets relative to the Exemplar-type marker within a record.
const OFF_GROUP : int = -4       # exemplar group id (LE u32)
const OFF_INSTANCE : int = 4     # exemplar instance id (LE u32)
const OFF_POS : int = 12         # three LE float32s: X, Y (altitude), Z
const OFF_ORIENTATION : int = 32 # 0..3, quarter-turns

class FloraRecord:
    var exemplar_tgi : Array      # [type, group, instance]
    var pos_x : float             # world metres (X)
    var pos_z : float             # world metres (Z)
    var altitude : float          # metres (terrain is preferred for placement)
    var orientation : int         # 0..3, quarter-turns

var records : Array = []

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
        var marker = _find_marker(pos, pos + size)
        if marker >= 0 and marker + OFF_ORIENTATION < pos + size:
            var rec = FloraRecord.new()
            rec.exemplar_tgi = [
                EXEMPLAR_TYPE,
                _u32(marker + OFF_GROUP),
                _u32(marker + OFF_INSTANCE),
            ]
            buf.seek(marker + OFF_POS)
            rec.pos_x = buf.get_float()
            rec.altitude = buf.get_float()  # Y is up
            rec.pos_z = buf.get_float()
            rec.orientation = raw_data[marker + OFF_ORIENTATION]
            records.append(rec)
        pos += size
    return OK

# Little-endian u32 read straight from raw_data.
func _u32(o : int) -> int:
    return raw_data[o] | (raw_data[o + 1] << 8) | (raw_data[o + 2] << 16) | (raw_data[o + 3] << 24)

# First offset in [from, to) whose 4 LE bytes equal the Exemplar type id, or -1.
func _find_marker(from : int, to : int) -> int:
    var b0 = EXEMPLAR_TYPE & 0xff
    var b1 = (EXEMPLAR_TYPE >> 8) & 0xff
    var b2 = (EXEMPLAR_TYPE >> 16) & 0xff
    var b3 = (EXEMPLAR_TYPE >> 24) & 0xff
    var o = from
    var limit = to - 4
    while o <= limit:
        if raw_data[o] == b0 and raw_data[o + 1] == b1 and raw_data[o + 2] == b2 and raw_data[o + 3] == b3:
            return o
        o += 1
    return -1
