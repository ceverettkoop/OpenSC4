extends DBPFSubfile

# Parses SC4's network index subfile (type 0x6A0F82B2, cSC4TrafficNetworkMap)
# from a city save: the game's own index from city tiles to the network
# occupants sitting on them, spanning every network subfile at once (ground
# networks, pipes, power lines, bridges).
#
# HONEST LIMITS. This subfile is a single multi-megabyte record and is only
# partially decoded by the community -- SC4Parser's own implementation calls its
# tail "trying to parse some unknown reference stuff" and cannot always keep the
# cursor aligned. What IS solid, and what this parser exposes:
#
#   * the header: record size, CRC, memory address, version, city tile count
#     (128x128 = 16384) and network tile count;
#   * the reference table: one {tile_number, mem, subfile_type} triple per
#     network tile, where `mem` matches the memory address in that occupant's
#     own record and `subfile_type` says which subfile to find it in.
#
# Between consecutive triples sits a variable-length payload (a block table plus
# fields nobody has decoded). Rather than guess at its width and silently
# desynchronise, we resynchronise: after each triple we scan forward for the
# next one, recognising it by a known network subfile type id in the third
# dword. Verified to recover exactly the declared number of references in every
# populated save in Regions/, with strictly increasing tile numbers.
#
# What `tile_number` means is still open. It is NOT a plain row-major tile index
# -- tested against the actual tile coordinates of the ground-network records,
# both (n-1)%128/(n-1)/128 and its transpose match only about half the entries.
# It is exposed raw; do not read a coordinate out of it without checking first.
class_name NetworkIndexSubfile

# Subfile type ids a reference may point at. Used to recognise the start of a
# reference triple during resynchronisation.
const NETWORK_SUBFILE_TYPES : Array = [
    0xc9c05c6e,   # ground networks
    0x49c05b9f,   # pipes
    0xc9c05c5d,   # power lines
    0xca16374f,   # bridges / elevated
    0x8a4bd52b,   # tunnels
    0x49c1a034,   # prebuilt networks
]

# How far past a reference we are willing to scan before giving up. The largest
# gap observed in the shipped saves is a few hundred bytes.
const RESYNC_WINDOW : int = 8192

class TileReference:
    var tile_number : int         # the game's own tile key; meaning undecoded
    var mem : int                 # memory address of the occupant record
    var subfile_type : int        # which network subfile holds that record

var major : int = 0
var city_tile_count : int = 0     # 16384 on a 2x2 km map
var network_tile_count : int = 0  # references the index claims to hold
var tile_refs : Array = []

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)
    var n = raw_data.size()
    if n < 22:
        Log.warn("NetworkIndexSubfile: record is only %d bytes" % n)
        return OK
    var buf = StreamPeerBuffer.new()
    buf.data_array = raw_data

    var size = buf.get_u32()
    buf.get_u32()                 # crc
    buf.get_u32()                 # mem
    major = buf.get_u16()
    city_tile_count = buf.get_u32()
    network_tile_count = buf.get_u32()
    if size != n:
        Log.warn("NetworkIndexSubfile: declared size %d but subfile is %d bytes" % [size, n])

    var cursor = buf.get_position()
    while tile_refs.size() < network_tile_count:
        var at = _find_reference(cursor, n)
        if at < 0:
            break
        buf.seek(at)
        var ref = TileReference.new()
        ref.tile_number = buf.get_u32()
        ref.mem = buf.get_u32()
        ref.subfile_type = buf.get_u32()
        tile_refs.append(ref)
        cursor = buf.get_position()

    if tile_refs.size() != network_tile_count:
        Log.warn("NetworkIndexSubfile: recovered %d of %d declared tile references"
            % [tile_refs.size(), network_tile_count])
    return OK

# Scans forward from `from` for the next reference triple, recognising it by a
# known network subfile type id in the third dword and a plausible tile number.
# Returns the offset, or -1 if none turns up inside the resync window.
func _find_reference(from : int, to : int) -> int:
    var limit = min(to - 12, from + RESYNC_WINDOW)
    var o = from
    while o <= limit:
        if NETWORK_SUBFILE_TYPES.has(_u32(o + 8)) and _u32(o) < city_tile_count:
            return o
        o += 1
    return -1

# {subfile type id: reference count}, for logging and harness assertions.
func type_histogram() -> Dictionary:
    var hist = {}
    for ref in tile_refs:
        var key = "0x%08x" % ref.subfile_type
        hist[key] = hist.get(key, 0) + 1
    return hist
