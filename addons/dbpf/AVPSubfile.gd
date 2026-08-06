extends DBPFSubfile

# Parses SC4's sprite frame table (type 0x09ADCD75, "AVP"). One of these exists
# per zoom level of an animated/sprite prop; ATCSubfile.gd names them.
#
# Header (nine little-endian u32s, 0x24 bytes):
#   0     0x09ADCD75  own type id
#   1     frame count
#   2, 3  always 1 across every AVP in the shipped DATs
#   4..7  zero
#   8     frame count, repeated
# then `count` eight-byte frame records:
#   0     page  -- which FSH directory entry (256x256) holds this frame
#   1     always 8
#   2..3  u16, the frame's top-left PIXEL offset within that page, so the corner
#         is (offset % page_width, offset / page_width). Every animation page in
#         the game is 256x256, which is exactly what 16 bits of offset covers.
#   4     width
#   5     height
#   6..7  anchor x, y (SIGNED: the sprite pixel that sits on the prop's world
#         position; a handful of frames anchor outside their own rectangle)
class_name AVPSubfile

const TYPE_ID : int = 0x09adcd75
const HEADER_SIZE : int = 0x24
const FRAME_SIZE : int = 8

class AVPFrame:
    var page : int          # FSH directory entry index
    var offset : int        # pixel offset of the top-left corner within the page
    var width : int
    var height : int
    var anchor_x : int      # signed
    var anchor_y : int      # signed

var frames : Array = []

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)
    if raw_data.size() < HEADER_SIZE:
        Log.error("AVP %08x: %d bytes, too short for a header" % [
            index.instance_id, raw_data.size()])
        return OK
    var count = _u32(4)
    for i in range(count):
        var o = HEADER_SIZE + i * FRAME_SIZE
        if o + FRAME_SIZE > raw_data.size():
            Log.error("AVP %08x: claims %d frames but holds %d" % [
                index.instance_id, count, i])
            break
        var f = AVPFrame.new()
        f.page = raw_data[o]
        f.offset = raw_data[o + 2] | (raw_data[o + 3] << 8)
        f.width = raw_data[o + 4]
        f.height = raw_data[o + 5]
        f.anchor_x = _s8(raw_data[o + 6])
        f.anchor_y = _s8(raw_data[o + 7])
        frames.append(f)
    return OK

func _s8(b : int) -> int:
    return b - 256 if b > 127 else b
