extends DBPFSubfile

# Parses SC4's Lot subfile (type 0xC9BD5D4A) from a city save: one record per
# developed/plopped lot with its tile rectangle, orientation, zoning and the
# LotConfiguration exemplar reference. Unlike buildings/props/textures the lot
# has no direct visual -- SC4 denormalizes a lot's appearance into the
# Building/Prop/Flora/BaseTexture subfiles -- but it is the authority on zoning,
# wealth and lot extents (zone overlays, foundations, simulation).
# Field layout follows the open-source `sc4` savegame library's lot parser,
# validated against every record of a developed save.
class_name LotSubfile

# zone_type values (subset seen in saves): 1-3 residential low/med/high,
# 4-6 commercial, 7-9 industrial (by density), 15 plopped building.
class LotRecord:
    var config_iid : int          # LotConfiguration exemplar instance id
    var min_x : int               # tile rect, absolute city tiles, inclusive
    var min_z : int
    var max_x : int
    var max_z : int
    var commute_x : int           # commute entry tile
    var commute_z : int
    var y_pos : float             # lot base altitude (metres)
    var width : int               # tiles (per lot exemplar, pre-rotation)
    var depth : int
    var orientation : int         # 0..3, quarter-turns
    var zone_type : int
    var zone_wealth : int         # 0..3 = none/$/$$/$$$
    var building_iid : int        # building exemplar instance on this lot

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
        if size >= 52:
            var rec = LotRecord.new()
            rec.config_iid = _u32(pos + 14)
            rec.min_x = raw_data[pos + 19]
            rec.min_z = raw_data[pos + 20]
            rec.max_x = raw_data[pos + 21]
            rec.max_z = raw_data[pos + 22]
            rec.commute_x = raw_data[pos + 23]
            rec.commute_z = raw_data[pos + 24]
            buf.seek(pos + 25)
            rec.y_pos = buf.get_float()
            rec.width = raw_data[pos + 37]
            rec.depth = raw_data[pos + 38]
            rec.orientation = raw_data[pos + 39]
            rec.zone_type = raw_data[pos + 42]
            rec.zone_wealth = raw_data[pos + 43]
            rec.building_iid = _u32(pos + 48)
            records.append(rec)
        pos += size
    return OK

# Little-endian u32 read straight from raw_data.
func _u32(o : int) -> int:
    return raw_data[o] | (raw_data[o + 1] << 8) | (raw_data[o + 2] << 16) | (raw_data[o + 3] << 24)
