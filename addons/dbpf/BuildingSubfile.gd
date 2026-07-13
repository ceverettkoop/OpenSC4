extends DBPFSubfile

# Parses SC4's Building occupant subfile (type 0xA9BD882D) from a city save.
# The subfile is a flat array of length-prefixed records, one per placed
# building. Each record embeds a reference to the building's Exemplar (a TGI,
# stored little-endian) and a 3D bounding box (six floats, stored BIG-endian).
# Field offsets were reverse-engineered with tools/dat_dump.py; rather than trust
# a fixed layout across the (variable-length) record types, we locate the
# Exemplar type marker inside each record and read the neighbouring fields
# relative to it -- verified to resolve all records across every building type.
class_name BuildingSubfile

const EXEMPLAR_TYPE : int = 0x6534284a
# Offsets relative to the Exemplar-type marker within a record.
const OFF_GROUP : int = -4       # exemplar group id (LE u32)
const OFF_INSTANCE : int = 4     # exemplar instance id (LE u32)
# The bbox is six big-endian float32s: minX, minY, minZ, maxX, maxY, maxZ.
# In SC4's coordinate system Y is UP (altitude); X and Z are the ground plane.
const OFF_MIN_X : int = 0x10
const OFF_MIN_Y : int = 0x14     # altitude (metres)
const OFF_MIN_Z : int = 0x18

class BuildingRecord:
    var exemplar_tgi : Array      # [type, group, instance]
    var pos_x : float             # world metres (X)
    var pos_z : float             # world metres (Z)
    var altitude : float          # metres, from the bbox (terrain is preferred for placement)

var records : Array = []

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)        # raw_data is now decompressed
    var n = raw_data.size()
    var be = StreamPeerBuffer.new()
    be.data_array = raw_data
    be.big_endian = true
    var pos = 0
    while pos + 4 <= n:
        var size = _u32(pos)
        if size < 4 or pos + size > n:
            break
        var marker = _find_marker(pos, pos + size)
        if marker >= 0:
            var rec = BuildingRecord.new()
            rec.exemplar_tgi = [
                EXEMPLAR_TYPE,
                _u32(marker + OFF_GROUP),
                _u32(marker + OFF_INSTANCE),
            ]
            be.seek(marker + OFF_MIN_X)
            rec.pos_x = be.get_float()
            rec.altitude = be.get_float()   # OFF_MIN_Y: Y is up
            rec.pos_z = be.get_float()      # OFF_MIN_Z
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
