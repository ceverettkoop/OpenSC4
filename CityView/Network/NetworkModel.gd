extends RefCounted

# The authoritative map of which network tile sits on which city tile.
#
# Two things produce network tiles: the city save (NetworkSubfile, read once at
# load) and the build tool (drag to place, drag to bulldoze). Before this class
# they each kept their own collection -- City.gd had `network_tiles : Array` of
# save records and TransitTiles.gd had `network_tiles : Dictionary` of its own
# tile objects, two different things under one name, with nothing reconciling
# them. Everything now goes through here instead, so the graph and the renderer
# are reading the same tiles rather than two views that can drift apart.
#
# Every mutation returns, and emits, the set of cells it disturbed. That set is
# always larger than the cells actually written: removing a tile changes the
# shape of its orthogonal neighbours too, and they have to be re-resolved.
class_name NetworkModel

const PATH_TYPE : int = 0x296678f7
const GROUP_TEXTURED : int = 0x69668828     # ground networks, keyed by FSH texture id
const GROUP_3D : int = 0xa966883f           # elevated/highway pieces, keyed by S3D id

# Where a tile came from. It matters for removal: a save tile's quad lives
# inside a big batched ArrayMesh built at load time and has to be cut out of it,
# whereas a user tile is in the tool's own mesh.
enum { SOURCE_SAVE, SOURCE_USER }

# One tile is 16 metres and one world unit, so save coordinates divide by this.
const TILE_SIZE : float = 16.0

# WNES edge index -> neighbouring cell. North is -z in this project's frame:
# measured over all 3,335 tiles of Big City Tutorial, W=-x/N=-z/E=+x/S=+z scores
# 6831 hits against 9 misses, while reading north as +z scores 6309/531.
# Cell coordinates are (tile_x, tile_z).
const SIDE_DELTA : Array = [
    Vector2i(-1, 0),    # SIDE_WEST
    Vector2i(0, -1),    # SIDE_NORTH
    Vector2i(1, 0),     # SIDE_EAST
    Vector2i(0, 1),     # SIDE_SOUTH
]

class Tile:
    var cell : Vector2i
    # Every network on this tile. A level crossing is a single save record
    # carrying two: road plus rail, or road plus street.
    var network_types : Array = []
    # The piece the tile draws, which is also its SC4Path instance id. For save
    # tiles this is NetworkTile.texture_id.
    var piece_id : int = 0
    var base_texture : int = 0
    # RAW orientation byte, 0x80 flip bit included. SC4PathSubfile's transforms
    # want it unmasked.
    var orientation : int = 0
    # RUL edge code per side, unioned over every crossing. 0 means no
    # connection; non-zero values distinguish straight from diagonal.
    var wnes : PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
    # The raw per-network crossings, kept because the union above cannot say
    # WHICH network connects a given side on a crossing tile.
    var crossings : Array = []
    var base_height : float = 0.0      # world units
    var source : int = SOURCE_USER
    # Index back into the save's tile array, or -1. Lets the renderer find the
    # original record when it has to rebuild a batch.
    var save_index : int = -1

    # The tile's primary network, which is what crossings[0] describes.
    func network_type() -> int:
        return network_types[0] if not network_types.is_empty() else -1

    func connects(side : int) -> bool:
        return wnes[side] != 0

    func connected_sides() -> Array:
        var out : Array = []
        for side in range(4):
            if wnes[side] != 0:
                out.append(side)
        return out

    # A detached copy, for the undo snapshot. remove() edits a surviving
    # neighbour's wnes in place, so storing the reference would snapshot the
    # object we are about to change and undo would restore nothing.
    func clone() -> Tile:
        var copy := Tile.new()
        copy.cell = cell
        copy.network_types = network_types.duplicate()
        copy.piece_id = piece_id
        copy.base_texture = base_texture
        copy.orientation = orientation
        copy.wnes = wnes.duplicate()
        copy.crossings = crossings
        copy.base_height = base_height
        copy.source = source
        copy.save_index = save_index
        return copy

signal tiles_changed(dirty : Array)

var tiles : Dictionary = {}          # Vector2i -> Tile
# piece id -> SC4PathSubfile, or null when the piece has no path file. Cached
# because resolving a miss costs a dictionary probe in Core either way, and the
# 3,335 tiles of a real city share only a few dozen pieces.
var _path_cache : Dictionary = {}
# Each entry is the full prior state of the cells one mutation touched, so
# undo() is a straight restore rather than an inverse operation.
var _undo_stack : Array = []

func size() -> int:
    return tiles.size()

func has_tile(cell : Vector2i) -> bool:
    return tiles.has(cell)

func get_tile(cell : Vector2i):
    return tiles.get(cell)

# The neighbouring cells that hold a tile, as {side: cell}.
func occupied_neighbours(cell : Vector2i) -> Dictionary:
    var out : Dictionary = {}
    for side in range(4):
        var other : Vector2i = cell + SIDE_DELTA[side]
        if tiles.has(other):
            out[side] = other
    return out

static func opposite(side : int) -> int:
    return (side + 2) % 4

# --- seeding from a save -----------------------------------------------------

# Builds the model from a parsed NetworkSubfile. Deleted tiles are skipped: SC4
# clears the record's present bit rather than compacting the array, so the file
# still contains everything ever built here.
func seed_from_save(save_tiles : Array) -> Array:
    var dirty : Array = []
    for i in range(save_tiles.size()):
        var src = save_tiles[i]
        if not src.is_present():
            continue
        var tile = Tile.new()
        tile.cell = Vector2i(src.tile_x(), src.tile_z())
        tile.piece_id = src.texture_id
        tile.base_texture = src.base_texture
        tile.orientation = src.orientation
        tile.crossings = src.crossings
        tile.base_height = src.position.y / TILE_SIZE
        tile.source = SOURCE_SAVE
        tile.save_index = i
        _apply_crossings(tile)
        tiles[tile.cell] = tile
        dirty.append(tile.cell)
    tiles_changed.emit(dirty)
    return dirty

# Fills in network_types and the unioned WNES from the raw crossings.
#
# Reading only crossings[0] is not enough. On a level crossing the second
# network's connections live in crossings[1], and ignoring them drops agreement
# between the tile's declared edges and its path file from ~99.5% to ~94%.
func _apply_crossings(tile : Tile) -> void:
    tile.network_types = []
    var wnes := PackedInt32Array([0, 0, 0, 0])
    for crossing in tile.crossings:
        tile.network_types.append(crossing["type"])
        var codes = [crossing["west"], crossing["north"], crossing["east"], crossing["south"]]
        for side in range(4):
            if wnes[side] == 0:
                wnes[side] = codes[side]
    tile.wnes = wnes

# --- mutation ----------------------------------------------------------------

# Adds or replaces tiles. Returns every cell whose appearance or connectivity
# may have changed, which includes the orthogonal neighbours of each placement.
func place(records : Array) -> Array:
    var prior := {}
    var dirty := {}
    for tile in records:
        _remember(prior, tile.cell)
        tiles[tile.cell] = tile
        _mark(dirty, tile.cell)
    _push_undo(prior)
    var out = dirty.keys()
    tiles_changed.emit(out)
    return out

# Deletes tiles and relaxes the surviving neighbours' edge codes, so a road that
# lost its continuation no longer claims to connect that way. Returns the dirty
# set: the removed cells plus every neighbour that had to change.
func remove(cells : Array) -> Array:
    var prior := {}
    var dirty := {}
    var gone : Array = []
    for cell in cells:
        if not tiles.has(cell):
            continue
        _remember(prior, cell)
        tiles.erase(cell)
        gone.append(cell)
        _mark(dirty, cell)
    # Clear the facing edge of anything that pointed at a tile we just deleted.
    # Only the four orthogonal neighbours matter: every path endpoint in the
    # shipped data sits on an orthogonal edge, so connectivity cannot propagate
    # diagonally even where the network itself runs diagonally.
    for cell in gone:
        for side in range(4):
            var other : Vector2i = cell + SIDE_DELTA[side]
            var neighbour = tiles.get(other)
            if neighbour == null:
                continue
            var facing := opposite(side)
            if neighbour.wnes[facing] == 0:
                continue
            _remember(prior, other)
            neighbour.wnes[facing] = 0
            _mark(dirty, other)
    _push_undo(prior)
    var out = dirty.keys()
    tiles_changed.emit(out)
    return out

# Restores the state before the last place() or remove(). Returns the dirty set.
func undo() -> Array:
    if _undo_stack.is_empty():
        return []
    var prior : Dictionary = _undo_stack.pop_back()
    var dirty := {}
    for cell in prior.keys():
        var tile = prior[cell]
        if tile == null:
            tiles.erase(cell)
        else:
            tiles[cell] = tile
    # Dirty the neighbours too, not just the cells written. place() and
    # remove() both do, and the set has to be the same shape going back as it
    # was going forward: a neighbour that was re-derived when the tile went
    # away has to be re-derived again when it returns, or the graph keeps the
    # arcs it grew while the tile was missing.
    for cell in prior.keys():
        _mark(dirty, cell)
    var out = dirty.keys()
    tiles_changed.emit(out)
    return out

func can_undo() -> bool:
    return not _undo_stack.is_empty()

# Snapshots a cell before it is written, once per mutation. Records null for a
# cell that did not exist, so undo() knows to erase rather than restore.
func _remember(prior : Dictionary, cell : Vector2i) -> void:
    if prior.has(cell):
        return
    var existing = tiles.get(cell)
    prior[cell] = existing.clone() if existing != null else null

func _push_undo(prior : Dictionary) -> void:
    if not prior.is_empty():
        _undo_stack.append(prior)

# A cell and its four orthogonal neighbours all need re-resolving when it changes.
func _mark(dirty : Dictionary, cell : Vector2i) -> void:
    dirty[cell] = true
    for side in range(4):
        var other : Vector2i = cell + SIDE_DELTA[side]
        if tiles.has(other):
            dirty[other] = true

# --- path resolution ---------------------------------------------------------

# The SC4Path file for a piece, or null when the piece has none. Ground pieces
# are keyed by texture id in the textured group; elevated and highway pieces by
# model id in the 3D group, so try both.
func path_for_piece(piece_id : int):
    if _path_cache.has(piece_id):
        return _path_cache[piece_id]
    var found = null
    for group in [GROUP_TEXTURED, GROUP_3D]:
        var key = [PATH_TYPE, group]
        if not Core.sub_by_type_and_group.has(key):
            continue
        if not Core.sub_by_type_and_group[key].has(piece_id):
            continue
        found = Core.subfile(PATH_TYPE, group, piece_id, SC4PathSubfile)
        if found != null:
            break
    _path_cache[piece_id] = found
    return found

func paths_for(tile : Tile):
    return path_for_piece(tile.piece_id)

# --- reporting ---------------------------------------------------------------

func type_histogram() -> Dictionary:
    var hist : Dictionary = {}
    for tile in tiles.values():
        var t = tile.network_type()
        var name = NetworkSubfile.NETWORK_TYPE_NAMES[t] if t >= 0 and t < NetworkSubfile.NETWORK_TYPE_NAMES.size() else "0x%02x" % t
        hist[name] = hist.get(name, 0) + 1
    return hist

# RUL edge code for a median shared between the two halves of a 2-tile-wide
# network. Documented in RULSubfile.gd's field notes.
const EDGE_SHARED_MEDIAN : int = 4
const NETWORK_AVENUE : int = 6

# How well each tile's path file agrees with the edges the save says it
# connects. This is the load-bearing calibration for the whole graph: if the
# rotation convention were wrong the arcs would attach to the wrong sides and
# the result would still look like a plausible road network, so it has to be
# measured rather than eyeballed.
#
# Avenues are counted separately rather than as failures. An avenue is one
# network two tiles wide, and its lanes are split across the pair: a single
# tile's path file describes lanes that cross into its partner, and its WNES
# carries the shared-median code for the edge they share. Neither side is
# wrong, they just are not describing the same thing. Every ground tile of both
# shipped saves that is not an avenue agrees exactly.
#
# Returns {checked, agreed, deferred, no_path, mismatches}.
func orientation_report() -> Dictionary:
    var checked := 0
    var agreed := 0
    var deferred := 0
    var no_path := 0
    var mismatches : Array = []
    for tile in tiles.values():
        var paths = paths_for(tile)
        if paths == null:
            no_path += 1
            continue
        var from_paths := {}
        for side in paths.connected_sides():
            from_paths[SC4PathSubfile.transform_dir(side, tile.orientation)] = true
        var from_save := {}
        for side in tile.connected_sides():
            from_save[side] = true
        var path_sides = from_paths.keys()
        var save_sides = from_save.keys()
        path_sides.sort()
        save_sides.sort()
        if path_sides == save_sides:
            checked += 1
            agreed += 1
            continue
        if is_multi_tile_network(tile):
            deferred += 1
            continue
        checked += 1
        mismatches.append({
            "cell": tile.cell,
            "piece_id": tile.piece_id,
            "orientation": tile.orientation,
            "crossings": tile.crossings.size(),
            "from_paths": path_sides,
            "from_save": save_sides,
        })
    return {
        "checked": checked, "agreed": agreed, "deferred": deferred,
        "no_path": no_path, "mismatches": mismatches,
    }

# Whether this tile is half of a network that spans two tiles, and so cannot be
# expected to describe its own edges on its own.
func is_multi_tile_network(tile : Tile) -> bool:
    if tile.network_types.has(NETWORK_AVENUE):
        return true
    for side in range(4):
        if tile.wnes[side] == EDGE_SHARED_MEDIAN:
            return true
    return false

# Pieces with no SC4Path, split by whether the tile connects to anything.
#
# Only the connected ones matter. A tile with no path but no connections either
# cannot contribute an arc however it is handled -- Getting Started Tutorial's
# entire network is one such tile, an orphan street piece (0x00000100) with all
# four edge codes zero. A tile that does connect but has no path is a real gap,
# and is what the synthesised-arc fallback is for.
#
# Note that having a texture is not the discriminator: 0x00000100 does ship an
# FSH, in SimCity_5.dat, and only 546 of the 5,350 network texture families have
# a path at all. Most textures are not connected ground pieces.
#
# Returns {connected: {piece: tiles}, inert: {piece: tiles}}.
func unresolved_pieces() -> Dictionary:
    var connected : Dictionary = {}
    var inert : Dictionary = {}
    for tile in tiles.values():
        if path_for_piece(tile.piece_id) != null:
            continue
        var bucket = connected if not tile.connected_sides().is_empty() else inert
        bucket[tile.piece_id] = bucket.get(tile.piece_id, 0) + 1
    return {"connected": connected, "inert": inert}
