extends DBPFSubfile

# Parses SC4's path files (type 0x296678F7) -- the per-tile-piece description of
# where vehicles and pedestrians actually travel inside one network tile.
#
# This is the file that turns a drawn network into a graph. A network tile on
# its own only knows which of its four edges are connected; the path file says
# which *lane* runs from which edge to which other edge, for which kind of
# traveller. One-way roads, banned turns and the two carriageways of an avenue
# are all encoded here and nowhere else.
#
# Unlike almost everything else in a DBPF this is a PLAIN TEXT format, CRLF
# terminated:
#
#   SC4PATHS
#   1.2                 version: 1.0, 1.1 or 1.2
#   1                   number of path records
#   0                   number of stop records   <-- 1.1 and 1.2 ONLY
#   1                   terrain variance flag
#   -- car_a_3_2        optional comment naming the path (class, lane, entry, exit)
#   1                   class: 1 Car 2 Sim 3 Train 4 Subway 6 ElTrain 7 Monorail
#   15                  path index -- distinguishes parallel lanes (the _a/_b/_c)
#   2                   entry edge, 0..3 WNES, or 255 for none
#   0                   exit edge
#   0                   junction flag            <-- 1.2 ONLY
#   4                   coordinate count
#   8,-5.141864,15.723011      ... that many "x,y,z" lines
#
# Stop records follow the path records and have the same shape in both 1.1 and
# 1.2 -- five fields and exactly one coordinate.
#
# Where they live. Ground networks are in group 0x69668828 (TEXTURED_NETWORK_PATH)
# keyed by the FSH texture id, which is exactly NetworkSubfile.NetworkTile's
# `texture_id`; every ground tile of both shipped saves resolves. Elevated and
# highway pieces are in group 0xA966883F (3D_NETWORK_PATH) keyed by an S3D model
# id. Grammar verified against all 3,411 records in SimCity_1.dat with zero
# parse failures (160 v1.0, 378 v1.1, 2873 v1.2).
class_name SC4PathSubfile

# Edge indices. The same 0..3 WNES ordering RULSubfile.gd keys on and that
# NetworkSubfile's crossings dict uses, so no translation is ever needed.
const SIDE_WEST : int = 0
const SIDE_NORTH : int = 1
const SIDE_EAST : int = 2
const SIDE_SOUTH : int = 3
# An entry/exit of 255 means the path does not reach a tile edge on that end --
# it terminates inside the tile, which is how lots and stations attach.
const SIDE_NONE : int = 255

# Path classes. Derived from the files' own comment names rather than guessed:
# class 1 always names itself "car*", 2 "sim*", 3 "train*", 4 "subway", and so
# on. 5 never occurs in the base game.
const CLASS_CAR : int = 1
const CLASS_SIM : int = 2
const CLASS_TRAIN : int = 3
const CLASS_SUBWAY : int = 4
const CLASS_ELTRAIN : int = 6
const CLASS_MONORAIL : int = 7

const CLASS_NAMES : Dictionary = {
    1: "Car", 2: "Sim", 3: "Train", 4: "Subway", 6: "ElTrain", 7: "Monorail",
}

# Stop kinds. UK stops are the left-hand-drive mirror of the normal ones; SC4
# picks between them by the driving-side setting.
const STOP_NORMAL : int = 1
const STOP_UK : int = 2

# One tile is 16 metres, and path coordinates are tile-local metres spanning
# -8..+8 on both horizontal axes.
const TILE_METRES : float = 16.0

# The 0x80 bit of a tile's orientation mirrors the piece about x, so west and
# east swap while north and south stay put -- and it applies AFTER the quarter
# turns, not before. The two do not commute, and the order is not a detail:
# scored against the edges the save itself declares for every ground tile of
# both shipped saves, the four candidate compositions give
#
#   flip_x(rot)   3335/3335 = 100.00%   <- this one, all 48 flipped tiles included
#   rot(flip_x)   3318/3335 =  99.49%
#   rot(flip_y)   3311/3335 =  99.28%
#   flip_y(rot)   3294/3335 =  98.77%
#
# and the three losers each fail on a different subset of rotations, which is
# what makes a wrong order look like scattered noise rather than a bug.

# One lane through the tile: a directed run from one edge to another.
class PathRecord:
    var name : String = ""        # the "--" comment, "" when absent
    var transport_class : int     # see CLASS_*
    var path_index : int          # which parallel lane this is
    var entry : int               # SIDE_*, or SIDE_NONE
    var exit : int
    var is_junction : bool        # 1.2 only; the comment then ends in "_J"
    var coords : PackedVector3Array = PackedVector3Array()

    # Polyline length in metres. This is the routing cost numerator -- a
    # diagonal tile really is ~22.6 m of road, not 16.
    func length_m() -> float:
        var total := 0.0
        for i in range(1, coords.size()):
            total += coords[i].distance_to(coords[i - 1])
        return total

# Where a vehicle stops within the tile: bus stops, stations, signals.
class StopRecord:
    var name : String = ""
    var stop_type : int           # STOP_NORMAL or STOP_UK
    var transport_class : int
    var path_index : int
    var entry : int
    var exit : int
    var position : Vector3 = Vector3.ZERO

var version_major : int = 0
var version_minor : int = 0
# Whether the piece follows sloped terrain. Not used yet; kept because it tells
# a future renderer whether it may reproject the polyline onto the heightmap.
var terrain_variance : bool = false
var paths : Array = []
var stops : Array = []
# Non-zero means the declared record counts disagreed with what was read, so
# nothing in this file should be trusted. Mirrors NetworkSubfile.
var layout_failures : int = 0

func _init(index):
    super._init(index)

func load(file, dbdf = null):
    super.load(file, dbdf)        # raw_data is now decompressed
    var text = raw_data.get_string_from_ascii()
    # Keep only meaningful lines. Blank lines are padding; everything else is
    # either a "--" comment, a bare integer field or an "x,y,z" triple.
    var lines : Array = []
    for raw_line in text.split("\n"):
        var line = raw_line.strip_edges(true, true)
        if not line.is_empty():
            lines.append(line)

    if lines.size() < 3 or lines[0] != "SC4PATHS":
        Log.warn("SC4PathSubfile: %s is not an SC4PATHS file" % _tgi_label())
        layout_failures += 1
        return OK

    var version = lines[1].split(".")
    version_major = int(version[0])
    version_minor = int(version[1]) if version.size() > 1 else 0

    var i := 2
    var path_count := int(lines[i])
    i += 1
    # The stop-record count line exists from 1.1 onwards. Branch on the number
    # rather than string-matching the version so a 1.3 from a mod degrades to
    # the closest layout we know instead of failing outright.
    var stop_count := 0
    if version_minor >= 1:
        stop_count = int(lines[i])
        i += 1
    terrain_variance = int(lines[i]) != 0
    i += 1

    # Field count per path record: 1.2 inserts the junction flag before the
    # coordinate count. Stop records are five fields in both 1.1 and 1.2.
    var path_fields := 6 if version_minor >= 2 else 5

    for _p in range(path_count):
        if i >= lines.size():
            break
        var rec = PathRecord.new()
        if lines[i].begins_with("--"):
            rec.name = lines[i].substr(2).strip_edges(true, true)
            i += 1
        if i + path_fields > lines.size():
            break
        rec.transport_class = int(lines[i])
        rec.path_index = int(lines[i + 1])
        rec.entry = int(lines[i + 2])
        rec.exit = int(lines[i + 3])
        var coord_count : int
        if version_minor >= 2:
            rec.is_junction = int(lines[i + 4]) == 1
            coord_count = int(lines[i + 5])
        else:
            coord_count = int(lines[i + 4])
        i += path_fields
        for _c in range(coord_count):
            if i >= lines.size():
                break
            rec.coords.append(_parse_coord(lines[i]))
            i += 1
        paths.append(rec)

    for _s in range(stop_count):
        if i >= lines.size():
            break
        var rec = StopRecord.new()
        if lines[i].begins_with("--"):
            rec.name = lines[i].substr(2).strip_edges(true, true)
            i += 1
        if i + 5 >= lines.size():
            break
        rec.stop_type = int(lines[i])
        rec.transport_class = int(lines[i + 1])
        rec.path_index = int(lines[i + 2])
        rec.entry = int(lines[i + 3])
        rec.exit = int(lines[i + 4])
        rec.position = _parse_coord(lines[i + 5])
        i += 6
        stops.append(rec)

    if paths.size() != path_count or stops.size() != stop_count:
        Log.warn("SC4PathSubfile: %s declared %d paths / %d stops, read %d / %d"
            % [_tgi_label(), path_count, stop_count, paths.size(), stops.size()])
        layout_failures += 1
    return OK

func _parse_coord(line : String) -> Vector3:
    var parts = line.split(",")
    if parts.size() < 3:
        return Vector3.ZERO
    # Stored as (east, north, up): the THIRD component is height, not the
    # second. Kept in the file's own frame -- see to_world() for the mapping.
    return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))

func _tgi_label() -> String:
    if index == null:
        return "<no index>"
    return "%08X %08X %08X" % [index.type_id, index.group_id, index.instance_id]

# --- queries -----------------------------------------------------------------

# Every lane of one transport class.
func arcs_for_class(transport_class : int) -> Array:
    var out : Array = []
    for rec in paths:
        if rec.transport_class == transport_class:
            out.append(rec)
    return out

# The distinct transport classes this piece carries. A road tile has Car and
# Sim; a rail tile only Train.
func classes() -> Array:
    var seen : Dictionary = {}
    for rec in paths:
        seen[rec.transport_class] = true
    return seen.keys()

# The distinct tile edges any lane touches, ignoring in-tile terminations.
# Untransformed -- rotate with transform_dir() before comparing against a
# placed tile's WNES.
func connected_sides() -> Array:
    var seen : Dictionary = {}
    for rec in paths:
        if rec.entry != SIDE_NONE:
            seen[rec.entry] = true
        if rec.exit != SIDE_NONE:
            seen[rec.exit] = true
    var out = seen.keys()
    out.sort()
    return out

# Is this turn legal for this traveller? The question the graph exists to answer.
func has_arc(entry : int, exit : int, transport_class : int) -> bool:
    for rec in paths:
        if rec.transport_class == transport_class and rec.entry == entry and rec.exit == exit:
            return true
    return false

# Both ends of every lane, as the stitcher wants them: connectivity is resolved
# by matching these coordinates against the neighbouring tile's endpoints, not
# by trusting the declared entry/exit edges. Coordinates stay tile-local.
func endpoints() -> Array:
    var out : Array = []
    for p in range(paths.size()):
        var rec = paths[p]
        if rec.coords.is_empty():
            continue
        out.append({
            "path": p, "is_entry": true, "side": rec.entry,
            "local": rec.coords[0], "transport_class": rec.transport_class,
        })
        out.append({
            "path": p, "is_entry": false, "side": rec.exit,
            "local": rec.coords[rec.coords.size() - 1], "transport_class": rec.transport_class,
        })
    return out

func class_histogram() -> Dictionary:
    var hist : Dictionary = {}
    for rec in paths:
        var key = CLASS_NAMES.get(rec.transport_class, "0x%02x" % rec.transport_class)
        hist[key] = hist.get(key, 0) + 1
    return hist

# --- placement transforms ----------------------------------------------------
#
# These are static, and the parser never applies them to its own data, because
# DBPF.get_subfile() caches one parsed subfile per TGI: the 3,335 network tiles
# of Big City Tutorial share just 36 path files between them. A parser that
# rotated its own coordinates would be mutating an object several tiles hold at
# different orientations, and the second tile would corrupt the first.
#
# `orientation` is the RAW byte from NetworkTile.orientation, including the 0x80
# flip bit -- do not mask it before calling, that is where the flip gets lost.

# Rotate one WNES edge index onto a placed tile. SIDE_NONE passes through.
static func transform_dir(side : int, orientation : int) -> int:
    if side == SIDE_NONE:
        return SIDE_NONE
    var out := (side + (orientation & 3)) % 4
    if (orientation & 0x80) != 0:
        # Mirroring about x swaps West and East and leaves North/South alone.
        out = posmod(2 - out, 4)
    return out

# Rotate one tile-local coordinate the same way: quarter turns first, then the
# mirror, matching transform_dir so geometry and connectivity agree about which
# way the tile faces. Negating x is the coordinate form of swapping W and E.
static func transform_local(p : Vector3, orientation : int) -> Vector3:
    var x := p.x
    var y := p.y
    # (x, y) -> (y, -x) is one quarter turn, matching +1 on the edge index.
    for _i in range(orientation & 3):
        var nx := y
        y = -x
        x = nx
    if (orientation & 0x80) != 0:
        x = -x
    return Vector3(x, y, p.z)

# Tile-local metres to city world units. One world unit is one tile is 16 m,
# and north is -z in this project's frame -- hence the minus on the y term.
# `base_h` is the tile's own height in world units; the path's z rides on it.
static func to_world(p : Vector3, tile_x : int, tile_z : int, orientation : int,
        base_h : float) -> Vector3:
    var t := transform_local(p, orientation)
    return Vector3(
        tile_x + 0.5 + t.x / TILE_METRES,
        base_h + t.z / TILE_METRES,
        tile_z + 0.5 - t.y / TILE_METRES)
