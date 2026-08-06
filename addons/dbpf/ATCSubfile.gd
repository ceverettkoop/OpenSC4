extends DBPFSubfile

# Parses SC4's animation header subfile (type 0x29A5D1EC, "ATC").
#
# Not every prop is a 3D model. Traffic lights, the roof balloons and the
# exploratorium have NO S3D reference at all: their exemplar's ResourceKeyType0
# points here instead, and SC4 draws them by blitting pre-rendered 2D sprites
# into the isometric view. This subfile is the index of that sprite set.
#
# The record is always 48 bytes -- twelve little-endian u32s:
#   0     0x29A5D1EC   own type id
#   1..3  FSH type/group/instance -- the sprite sheet holding every frame of
#         every zoom, as a set of 256x256 pages (FSH directory entries)
#   4     0x09ADCD75   AVP type id
#   5     AVP group id
#   6..10 one AVP instance id per zoom 0..4, or 0 where the prop is not drawn
#         at that zoom. The filled slots line up exactly with the exemplar's
#         AppearanceZoomsFlag (0x0ABFC024) bitmask.
#   11    animation rate (see City.gd's SPRITE_TICK_HZ)
#
# The per-zoom AVP subfile (AVPSubfile.gd) then lists the frames.
class_name ATCSubfile

const TYPE_ID : int = 0x29a5d1ec
const FSH_TYPE : int = 0x7ab50e44
const AVP_TYPE : int = 0x09adcd75
const RECORD_SIZE : int = 48
# SC4 authors sprites for five zoom levels, the same 0..4 ladder as the S3D
# impostor LODs (City.gd's S3D_ZOOM_FOR_CAMERA).
const ZOOM_COUNT : int = 5

# [type, group, instance] of the sprite sheet, or [] if the record was short.
var fsh_tgi : Array = []
var avp_group : int = 0
# ZOOM_COUNT instance ids; 0 means "this prop is not drawn at that zoom".
var avp_by_zoom : Array = []
var rate : int = 0

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)
    if raw_data.size() < RECORD_SIZE:
        Log.error("ATC %08x: %d bytes, expected %d" % [
            index.instance_id, raw_data.size(), RECORD_SIZE])
        return OK
    fsh_tgi = [_u32(4), _u32(8), _u32(12)]
    avp_group = _u32(20)
    avp_by_zoom = []
    for z in range(ZOOM_COUNT):
        avp_by_zoom.append(_u32(24 + z * 4))
    rate = _u32(44)
    return OK

# True when the record parsed and names at least one zoom's frame table.
func is_valid() -> bool:
    if fsh_tgi.size() != 3 or fsh_tgi[0] != FSH_TYPE:
        return false
    for iid in avp_by_zoom:
        if iid != 0:
            return true
    return false
