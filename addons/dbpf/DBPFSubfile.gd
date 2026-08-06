extends RefCounted
class_name DBPFSubfile

# --- Savegame record structures ---------------------------------------------
# City-save subfiles are flat arrays of length-prefixed records. Every record
# opens with the standard SC4 serialization header (size, CRC, memory address,
# version), then a class-specific payload. The helpers at the bottom of this
# file read the pieces that recur across those payloads, so the individual
# parsers in this directory do not each re-derive them.

class RecordHeader:
    var size : int                # bytes, INCLUDING the size field itself
    var crc : int
    var mem : int                 # the object's address in the saving process
    var major : int
    var minor : int

# A serialized game property attached to an occupant. Layout matches the
# open-source `sc4` savegame library: the name dword is stored twice.
class SGProp:
    var name : int
    var type : int                # 0x01 u8, 0x02 u16, 0x03 u32, 0x07 i32,
                                  # 0x08 i64, 0x09 float, 0x0B bool, 0x0C string
    var value                     # scalar, Array (keyType 0x80) or String

# One corner of a network/occupant quad, with its texture coordinate and the
# lighting colour SC4 baked at save time.
class Vertex:
    var position : Vector3        # metres; Y is up
    var uv : Vector2
    var color : Color

var index:SubfileIndex
var raw_data:PackedByteArray
var stream:StreamPeerBuffer

func _init(idx:SubfileIndex):
    self.index = idx

func load(file:FileAccess, dbdf:DBDFEntry=null):
    file.seek(index.location)
    if dbdf != null:
        raw_data = decompress(file, index.size - 9, dbdf)
    else:
        raw_data = file.get_buffer(index.size)
    stream = StreamPeerBuffer.new()
    stream.data_array = raw_data

func decompress(file : FileAccess, length : int, dbdf : DBDFEntry) -> PackedByteArray:
    var buf:PackedByteArray
    var answer:PackedByteArray = PackedByteArray()
    var numplain:int
    var numcopy:int
    var offset:int
    var byte1:int
    var byte2:int
    var byte3:int
    var fromoffset:int

    file.get_32() # 4 redundant bytes
    file.get_16() # Compression type
    var decompressed_size = file.get_8() * 256 * 256
    decompressed_size += file.get_8() * 256
    decompressed_size += file.get_8()
    if decompressed_size != dbdf.final_size:
        print("WARNING: decompressed size does not match expected size")
        print("Expected: %d" % dbdf.final_size)
    
    while (length > 0):
        var cc = file.get_8()
        length -= 1
        byte1 = 0
        byte2 = 0
        byte3 = 0
        if cc >= 252:
            numplain = cc & 0x03
            if numplain > length:
                numplain = length
            numcopy = 0
            offset = 0
        elif cc >= 224:
            numplain = (cc - 0xdf) << 2
            numcopy = 0
            offset = 0
        elif cc >= 192:
            length -= 3
            byte1 = file.get_8()
            byte2 = file.get_8()
            byte3 = file.get_8()
            numplain = cc & 0x03
            numcopy = ((cc & 0x0c) << 6) + 5 + byte3
            offset = ((cc & 0x10) << 12) + (byte1 << 8) + byte2
        elif cc >= 128:
            length -= 2
            byte1 = file.get_8()
            byte2 = file.get_8()
            numplain = (byte1 & 0xc0) >> 6
            numcopy = (cc & 0x3f) + 4
            offset = ((byte1 & 0x3f) << 8) + byte2
        else:
            length -= 1
            byte1 = file.get_8()
            numplain = (cc & 0x03)
            numcopy = ((cc & 0x1c) >> 2) + 3
            offset = ((cc & 0x60) << 3) + byte1
        
        length -= numplain
        if (numplain > 0):
            buf = file.get_buffer(numplain)
            answer.append_array(buf)
        
        fromoffset = len(answer) - (offset + 1)
        for i in range(numcopy):
            answer.append(answer[fromoffset+i])

    return answer

# --- Record-reading helpers --------------------------------------------------

# Little-endian u32 read straight from raw_data.
func _u32(o : int) -> int:
    return raw_data[o] | (raw_data[o + 1] << 8) | (raw_data[o + 2] << 16) | (raw_data[o + 3] << 24)

# First offset in [from, to) whose 4 LE bytes equal `marker`, or -1. Occupant
# records embed their Exemplar's TGI, so locating the type id is a cheap way to
# anchor field offsets without trusting a fixed layout across record variants.
func _find_marker(from : int, to : int, marker : int) -> int:
    var b0 = marker & 0xff
    var b1 = (marker >> 8) & 0xff
    var b2 = (marker >> 16) & 0xff
    var b3 = (marker >> 24) & 0xff
    var o = from
    var limit = to - 4
    while o <= limit:
        if raw_data[o] == b0 and raw_data[o + 1] == b1 and raw_data[o + 2] == b2 and raw_data[o + 3] == b3:
            return o
        o += 1
    return -1

# Reads the standard record header at the buffer's current position.
func _read_record_header(buf : StreamPeerBuffer) -> RecordHeader:
    var h = RecordHeader.new()
    h.size = buf.get_u32()
    h.crc = buf.get_u32()
    h.mem = buf.get_u32()
    h.major = buf.get_u16()
    h.minor = buf.get_u16()
    return h

# Reads a count-prefixed SGProp array at the buffer's current position.
func _read_sgprops(buf : StreamPeerBuffer) -> Array:
    var props : Array = []
    var count = buf.get_u32()
    for _i in range(count):
        var p = SGProp.new()
        buf.get_u32()                 # the name dword is stored twice
        p.name = buf.get_u32()
        buf.get_u32()                 # unknown
        p.type = buf.get_u8()
        var key_type = buf.get_u8()
        buf.get_u16()                 # unknown
        if p.type == 0x0c:
            var length = buf.get_u32()
            p.value = buf.get_utf8_string(length)
        elif key_type == 0x80:
            var n = buf.get_u32()
            var values : Array = []
            for _k in range(n):
                values.append(_read_sgprop_value(buf, p.type))
            p.value = values
        else:
            p.value = _read_sgprop_value(buf, p.type)
        props.append(p)
    return props

func _read_sgprop_value(buf : StreamPeerBuffer, type : int):
    match type:
        0x01: return buf.get_u8()
        0x02: return buf.get_u16()
        0x03: return buf.get_u32()
        0x07: return buf.get_32()
        0x08: return buf.get_64()
        0x09: return buf.get_float()
        0x0b: return buf.get_u8() != 0
    Log.warn("DBPFSubfile: unknown SGProp data type 0x%02x" % type)
    return null

# Reads a 24-byte vertex: position, texture coordinate, then an RGBA colour.
func _read_vertex(buf : StreamPeerBuffer) -> Vertex:
    var v = Vertex.new()
    var x = buf.get_float()
    var y = buf.get_float()
    var z = buf.get_float()
    v.position = Vector3(x, y, z)
    v.uv = Vector2(buf.get_float(), buf.get_float())
    v.color = Color8(buf.get_u8(), buf.get_u8(), buf.get_u8(), buf.get_u8())
    return v

# Reads six floats as an AABB. Occupants store them grouped by corner
# (minX, minY, minZ, maxX, maxY, maxZ); the network family groups them by axis
# instead (minX, maxX, minY, maxY, minZ, maxZ) -- pass range_order for those.
func _read_bbox(buf : StreamPeerBuffer, range_order : bool = false) -> AABB:
    var mins : Vector3
    var maxs : Vector3
    if range_order:
        var min_x = buf.get_float()
        var max_x = buf.get_float()
        var min_y = buf.get_float()
        var max_y = buf.get_float()
        mins = Vector3(min_x, min_y, buf.get_float())
        maxs = Vector3(max_x, max_y, buf.get_float())
    else:
        mins = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
        maxs = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
    return AABB(mins, maxs - mins)
