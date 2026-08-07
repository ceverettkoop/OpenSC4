extends RefCounted

# The transportation network as a directed graph, derived from NetworkModel.
#
# Nodes are PORTALS -- a point on a tile boundary where one lane crosses, for
# one traveller class -- rather than one node per tile side. That distinction
# is what makes the graph worth building: an avenue crosses a tile boundary at
# four separate lane offsets, and collapsing them to a single node per side
# would make the two carriageways mutually reachable at every tile, inventing
# turns SC4 forbids and destroying the one-way encoding.
#
# Arcs come straight from SC4Path: one path record is one directed arc from its
# entry portal to its exit portal, tagged with the traveller class and its true
# length in metres (a diagonal tile is ~22.6 m of road, not 16). Turn
# restrictions need no special handling -- a piece with no west-to-north path
# simply produces no such arc.
#
# Portals are matched between neighbouring tiles by POSITION, not by declared
# direction. The boundary a portal sits on comes from the path's entry/exit
# edge, which is exact, but which lane it is comes from the coordinate. Most
# pairs line up to within a centimetre; the rest are matched by proximity.
class_name NetworkGraph

# Quantum for matching lane offsets along a boundary, in steps per metre. The
# exact matches land dead on eighths of a metre.
const OFFSET_QUANTUM : float = 8.0
# How far apart two portals on the same boundary may be and still be the same
# crossing point. Generous on purpose: it also lets a synthesised arc, which
# runs through the middle of its edge, meet a real lane offset either side.
const STITCH_TOLERANCE_M : float = 2.0

const TILE_METRES : float = 16.0

class Arc:
    var cell : Vector2i
    var transport_class : int
    var path_index : int
    var from_node : String
    var to_node : String
    var length_m : float = 0.0
    var is_junction : bool = false
    # World-unit polyline, for drawing and for measuring.
    var polyline : PackedVector3Array = PackedVector3Array()
    # True when the arc was invented from the tile's edge codes because its
    # piece has no SC4Path. Connectivity is right, lane geometry is a guess.
    var synthesised : bool = false

class Portal:
    var id : String
    var pos : Vector3 = Vector3.ZERO          # world units
    var transport_class : int
    # The boundary this portal sits on, or "" for a point inside a tile where
    # a path terminates -- which is how lots and stations attach.
    var boundary : String = ""
    var incoming : Array = []                 # arc indices
    var outgoing : Array = []

    func degree() -> int:
        return incoming.size() + outgoing.size()

var arcs : Array = []                 # Array[Arc]; indices are stable between rebuilds
var nodes : Dictionary = {}           # id -> Portal
var arcs_by_cell : Dictionary = {}    # Vector2i -> Array[int]
var nodes_by_boundary : Dictionary = {}   # boundary key -> Array[node id]

var _model : NetworkModel = null
# Arc slots freed by a removal, reused before the array grows again so it does
# not creep upward over a long editing session.
var _free_slots : Array = []

func _init(model : NetworkModel = null):
    if model != null:
        attach(model)

func attach(model : NetworkModel) -> void:
    _model = model
    rebuild()

# --- boundary identity -------------------------------------------------------
#
# Both tiles sharing a boundary have to derive the same key independently, or
# rebuilding one side would fail to re-merge into the node the other side still
# holds. Canonicalise onto the lower-coordinate tile: the boundary between
# (x, z) and (x+1, z) is always "x,z,E" no matter which of the two is asking.

static func boundary_key(cell : Vector2i, side : int) -> String:
    match side:
        SC4PathSubfile.SIDE_EAST:
            return "%d,%d,E" % [cell.x, cell.y]
        SC4PathSubfile.SIDE_WEST:
            return "%d,%d,E" % [cell.x - 1, cell.y]
        SC4PathSubfile.SIDE_SOUTH:
            return "%d,%d,S" % [cell.x, cell.y]
        SC4PathSubfile.SIDE_NORTH:
            return "%d,%d,S" % [cell.x, cell.y - 1]
    return ""

# Position along a boundary, in metres. East/west boundaries run along z, north
# /south ones along x, so the offset is whichever world axis varies.
static func boundary_offset_m(world : Vector3, side : int) -> float:
    if side == SC4PathSubfile.SIDE_EAST or side == SC4PathSubfile.SIDE_WEST:
        return world.z * TILE_METRES
    return world.x * TILE_METRES

static func _quantise(metres : float) -> int:
    return int(round(metres * OFFSET_QUANTUM))

static func _portal_id(boundary : String, offset_q : int, transport_class : int) -> String:
    return "%s|%d|%d" % [boundary, offset_q, transport_class]

# A path that ends inside a tile gets a node keyed by where it ends, so several
# paths meeting at the same interior point share it.
static func _terminal_id(world : Vector3, transport_class : int) -> String:
    return "T|%d|%d|%d" % [_quantise(world.x * TILE_METRES),
        _quantise(world.z * TILE_METRES), transport_class]

# --- building ----------------------------------------------------------------

func rebuild() -> void:
    arcs = []
    nodes = {}
    arcs_by_cell = {}
    nodes_by_boundary = {}
    _free_slots = []
    if _model == null:
        return
    var boundaries := {}
    for cell in _model.tiles.keys():
        _emit_tile(cell, boundaries)
    _stitch(boundaries.keys())

# Re-derives only the cells in `dirty` and re-stitches only the boundaries they
# touch. The bulk path and the incremental path share _emit_tile and _stitch, so
# a full city load exercises the same code an edit does.
func update(dirty : Array) -> void:
    if _model == null:
        return
    # Tear down at boundary granularity rather than cell granularity. A node is
    # shared by two tiles, so dropping only one tile's half would leave a
    # half-merged node whose key came from a cell we are not rebuilding.
    var boundaries := {}
    for cell in dirty:
        for side in range(4):
            boundaries[boundary_key(cell, side)] = true
    for cell in dirty:
        _drop_cell(cell)
    for key in boundaries.keys():
        _drop_boundary(key)
    for cell in dirty:
        if _model.tiles.has(cell):
            _emit_tile(cell, boundaries)
    _stitch(boundaries.keys())

func _drop_cell(cell : Vector2i) -> void:
    if not arcs_by_cell.has(cell):
        return
    for idx in arcs_by_cell[cell]:
        var arc = arcs[idx]
        if arc == null:
            continue
        _detach(arc.from_node, idx)
        _detach(arc.to_node, idx)
        arcs[idx] = null
        _free_slots.append(idx)
    arcs_by_cell.erase(cell)

# Removes the portal nodes on one boundary. Any arc still referencing them is
# re-emitted by its own cell, so only the node bookkeeping is undone here.
#
# A node that still carries arcs has to STAY on the boundary's roster. Only the
# dirty cells are re-emitted, so a portal holding the arcs of an undisturbed
# neighbour is never passed through _ensure_node again and would never be
# re-registered -- and _stitch_boundary works from this roster, so it would then
# see only the freshly emitted half of the boundary and find nothing to pair it
# with. The two sides ended up on separate nodes a centimetre apart with no arc
# between them: a boundary that was joined before the edit and silently came
# apart after it, in a graph whose arc count and topology elsewhere were
# unchanged. Wiping the whole list was safe only while every rebuild was a full
# one.
func _drop_boundary(key : String) -> void:
    if not nodes_by_boundary.has(key):
        return
    var survivors : Array = []
    for id in nodes_by_boundary[key]:
        var node = nodes.get(id)
        if node == null:
            continue
        if node.degree() == 0:
            nodes.erase(id)
        else:
            survivors.append(id)
    if survivors.is_empty():
        nodes_by_boundary.erase(key)
    else:
        nodes_by_boundary[key] = survivors

func _detach(node_id : String, arc_idx : int) -> void:
    var node = nodes.get(node_id)
    if node == null:
        return
    node.incoming.erase(arc_idx)
    node.outgoing.erase(arc_idx)
    if node.degree() == 0:
        nodes.erase(node_id)

# Turns one tile into arcs. Falls back to synthesising them from the tile's edge
# codes when the piece has no path file, so removing a road can never leave the
# graph claiming a connection that is not there, nor drop one that is.
func _emit_tile(cell : Vector2i, boundaries : Dictionary) -> void:
    var tile = _model.tiles.get(cell)
    if tile == null:
        return
    var paths = _model.paths_for(tile)
    if paths == null:
        _emit_synthesised(tile, boundaries)
        return
    for p in range(paths.paths.size()):
        var rec = paths.paths[p]
        if rec.coords.size() < 2:
            continue
        var polyline := PackedVector3Array()
        for c in rec.coords:
            polyline.append(SC4PathSubfile.to_world(c, cell.x, cell.y,
                tile.orientation, tile.base_height))
        # A mirrored placement drives the lane backwards -- see
        # SC4PathSubfile.mirrors_traversal. to_world has already put the lane in
        # the right PLACE; what is left is which end of it cars start from, so
        # the record's entry and exit swap and the polyline runs the other way.
        #
        # This is what fragmented avenue cities. SC4 builds an avenue's two
        # carriageways from one piece placed twice, once mirrored, so at every
        # boundary between a mirrored tile and an unmirrored one both sides
        # emitted arcs pointing the same way: two lanes leaving the boundary and
        # nothing arriving, or the reverse. The stitch cannot repair that -- it
        # only pairs a portal missing its incoming half with one missing its
        # outgoing half, and these were all missing the same half.
        var entry : int = rec.entry
        var exit : int = rec.exit
        if SC4PathSubfile.mirrors_traversal(tile.orientation):
            polyline.reverse()
            var swap := entry
            entry = exit
            exit = swap
        var arc := Arc.new()
        arc.cell = cell
        arc.transport_class = rec.transport_class
        arc.path_index = rec.path_index
        arc.is_junction = rec.is_junction
        arc.polyline = polyline
        arc.length_m = rec.length_m()
        arc.from_node = _node_for(cell, tile, entry, polyline[0], rec.transport_class, boundaries)
        arc.to_node = _node_for(cell, tile, exit,
            polyline[polyline.size() - 1], rec.transport_class, boundaries)
        _add_arc(arc)

# One lane per connected pair of edges, running through the tile centre. Used
# only when the piece has no SC4Path: the topology is right, the geometry is a
# straight-line approximation, and the arcs sit at the middle of each edge so
# the stitch tolerance still joins them to real lanes either side.
func _emit_synthesised(tile : NetworkModel.Tile, boundaries : Dictionary) -> void:
    var sides = tile.connected_sides()
    if sides.size() < 2:
        return
    var cell = tile.cell
    var centre := Vector3(cell.x + 0.5, tile.base_height, cell.y + 0.5)
    for a in sides:
        for b in sides:
            if a == b:
                continue
            var arc := Arc.new()
            arc.cell = cell
            arc.transport_class = SC4PathSubfile.CLASS_CAR
            arc.path_index = 0
            arc.synthesised = true
            var from_pos := _edge_midpoint(cell, a, tile.base_height)
            var to_pos := _edge_midpoint(cell, b, tile.base_height)
            arc.polyline = PackedVector3Array([from_pos, centre, to_pos])
            arc.length_m = (from_pos.distance_to(centre) + centre.distance_to(to_pos)) * TILE_METRES
            arc.from_node = _node_for(cell, tile, a, from_pos, arc.transport_class, boundaries)
            arc.to_node = _node_for(cell, tile, b, to_pos, arc.transport_class, boundaries)
            _add_arc(arc)

static func _edge_midpoint(cell : Vector2i, side : int, base_h : float) -> Vector3:
    var half := Vector3(NetworkModel.SIDE_DELTA[side].x, 0.0, NetworkModel.SIDE_DELTA[side].y) * 0.5
    return Vector3(cell.x + 0.5, base_h, cell.y + 0.5) + half

# The node one end of an arc attaches to. `side` is the path's own entry/exit
# edge, still in the piece's frame -- it gets rotated onto the placed tile here.
func _node_for(cell : Vector2i, tile : NetworkModel.Tile, side : int, world : Vector3,
        transport_class : int, boundaries : Dictionary) -> String:
    var placed := SC4PathSubfile.transform_dir(side, tile.orientation)
    if placed == SC4PathSubfile.SIDE_NONE:
        return _ensure_node(_terminal_id(world, transport_class), world, transport_class, "")
    var key := boundary_key(cell, placed)
    boundaries[key] = true
    var offset_q := _quantise(boundary_offset_m(world, placed))
    return _ensure_node(_portal_id(key, offset_q, transport_class), world, transport_class, key)

func _ensure_node(id : String, world : Vector3, transport_class : int, boundary : String) -> String:
    if not nodes.has(id):
        var node := Portal.new()
        node.id = id
        node.pos = world
        node.transport_class = transport_class
        node.boundary = boundary
        nodes[id] = node
    # Registration is separate from creation, and idempotent. An incremental
    # update can re-emit a tile whose portal node survived the teardown on some
    # other cell's arcs, and that node still has to be on the roster the stitch
    # reads.
    if boundary != "":
        if not nodes_by_boundary.has(boundary):
            nodes_by_boundary[boundary] = []
        if not nodes_by_boundary[boundary].has(id):
            nodes_by_boundary[boundary].append(id)
    return id

func _add_arc(arc : Arc) -> void:
    var idx : int
    if _free_slots.is_empty():
        idx = arcs.size()
        arcs.append(arc)
    else:
        idx = _free_slots.pop_back()
        arcs[idx] = arc
    nodes[arc.from_node].outgoing.append(idx)
    nodes[arc.to_node].incoming.append(idx)
    if not arcs_by_cell.has(arc.cell):
        arcs_by_cell[arc.cell] = []
    arcs_by_cell[arc.cell].append(idx)

# --- stitching ---------------------------------------------------------------

# Merges portals that the two tiles either side of a boundary emitted
# separately. Exact matches have already merged by key; this pass handles the
# rest, where the two lanes meet at very nearly but not exactly the same point.
func _stitch(boundary_keys : Array) -> void:
    for key in boundary_keys:
        if not nodes_by_boundary.has(key):
            continue
        _stitch_boundary(key)

func _stitch_boundary(key : String) -> void:
    # Group this boundary's portals by class, then pair up the ones that only
    # one side reached. A node with both an incoming and an outgoing arc is
    # already a through connection and needs no help.
    var by_class := {}
    for id in nodes_by_boundary[key]:
        var node = nodes.get(id)
        if node == null:
            continue
        if not by_class.has(node.transport_class):
            by_class[node.transport_class] = []
        by_class[node.transport_class].append(node)
    for transport_class in by_class.keys():
        var dangling : Array = []
        for node in by_class[transport_class]:
            if node.incoming.is_empty() or node.outgoing.is_empty():
                dangling.append(node)
        _pair_nearest(key, dangling)

# Greedy nearest-first pairing of one-sided portals. Only pairs a node missing
# its incoming half with one missing its outgoing half, so two lanes running the
# same way never get welded together.
func _pair_nearest(key : String, dangling : Array) -> void:
    var wants_in : Array = []
    var wants_out : Array = []
    for node in dangling:
        if node.incoming.is_empty():
            wants_in.append(node)
        if node.outgoing.is_empty():
            wants_out.append(node)
    var side := _boundary_side(key)
    var pairs : Array = []
    for a in wants_in:
        for b in wants_out:
            if a.id == b.id:
                continue
            var gap : float = abs(boundary_offset_m(a.pos, side) - boundary_offset_m(b.pos, side))
            if gap <= STITCH_TOLERANCE_M:
                pairs.append({"gap": gap, "a": a, "b": b})
    pairs.sort_custom(func(x, y): return x["gap"] < y["gap"])
    var used := {}
    for pair in pairs:
        var a = pair["a"]
        var b = pair["b"]
        if used.has(a.id) or used.has(b.id) or not nodes.has(a.id) or not nodes.has(b.id):
            continue
        used[a.id] = true
        used[b.id] = true
        _merge_nodes(b, a)

# Folds `from_node` into `into`, repointing every arc that referenced it.
func _merge_nodes(from_node : Portal, into : Portal) -> void:
    if from_node.id == into.id:
        return
    for idx in from_node.outgoing:
        var arc = arcs[idx]
        if arc != null:
            arc.from_node = into.id
            into.outgoing.append(idx)
    for idx in from_node.incoming:
        var arc = arcs[idx]
        if arc != null:
            arc.to_node = into.id
            into.incoming.append(idx)
    nodes.erase(from_node.id)
    if from_node.boundary != "" and nodes_by_boundary.has(from_node.boundary):
        nodes_by_boundary[from_node.boundary].erase(from_node.id)

static func _boundary_side(key : String) -> int:
    return SC4PathSubfile.SIDE_EAST if key.ends_with(",E") else SC4PathSubfile.SIDE_SOUTH

# --- queries -----------------------------------------------------------------

func arc_count() -> int:
    var total := 0
    for arc in arcs:
        if arc != null:
            total += 1
    return total

func node_count() -> int:
    return nodes.size()

# Adjacency for one traveller class, as {node id: [reachable node ids]}.
func _adjacency(transport_class : int) -> Dictionary:
    var adj := {}
    for arc in arcs:
        if arc == null or arc.transport_class != transport_class:
            continue
        if not adj.has(arc.from_node):
            adj[arc.from_node] = []
        if not adj.has(arc.to_node):
            adj[arc.to_node] = []
        adj[arc.from_node].append(arc.to_node)
    return adj

# Number of connected components for one class, ignoring arc direction. This is
# the assertion that catches a stale-adjacency bug: degrees alone stay plausible
# when one side of a boundary failed to re-merge, but the component count does
# not.
func component_count(transport_class : int) -> int:
    var undirected := {}
    for arc in arcs:
        if arc == null or arc.transport_class != transport_class:
            continue
        for pair in [[arc.from_node, arc.to_node], [arc.to_node, arc.from_node]]:
            if not undirected.has(pair[0]):
                undirected[pair[0]] = []
            undirected[pair[0]].append(pair[1])
    var seen := {}
    var count := 0
    for start in undirected.keys():
        if seen.has(start):
            continue
        count += 1
        var stack : Array = [start]
        seen[start] = true
        while not stack.is_empty():
            var current = stack.pop_back()
            for next in undirected.get(current, []):
                if not seen.has(next):
                    seen[next] = true
                    stack.append(next)
    return count

# Component sizes for one class, measured in city tiles and sorted largest
# first. A healthy road network is one big component plus a few strays; a count
# that climbs while the tile count holds means boundaries stopped merging.
func component_cell_sizes(transport_class : int) -> Array:
    var undirected := {}
    var cells_of_node := {}
    for arc in arcs:
        if arc == null or arc.transport_class != transport_class:
            continue
        for pair in [[arc.from_node, arc.to_node], [arc.to_node, arc.from_node]]:
            if not undirected.has(pair[0]):
                undirected[pair[0]] = []
                cells_of_node[pair[0]] = {}
            undirected[pair[0]].append(pair[1])
            cells_of_node[pair[0]][arc.cell] = true
    var seen := {}
    var sizes : Array = []
    for start in undirected.keys():
        if seen.has(start):
            continue
        var cells := {}
        var stack : Array = [start]
        seen[start] = true
        while not stack.is_empty():
            var current = stack.pop_back()
            for cell in cells_of_node.get(current, {}).keys():
                cells[cell] = true
            for next in undirected.get(current, []):
                if not seen.has(next):
                    seen[next] = true
                    stack.append(next)
        sizes.append(cells.size())
    sizes.sort()
    sizes.reverse()
    return sizes

# Pairs of neighbouring cells that BOTH CLAIM THE EDGE BETWEEN THEM, both carry
# arcs of one class, and still sit in different components. Each is a boundary
# the graph failed to cross, and is a defect in a way a bare component count is
# not: a city can legitimately hold several road systems with no tile touching
# between them (Rush Hour Tutorial holds three, in disjoint corners of the map).
#
# Adjacency alone is NOT the invariant, which is why both edge codes are tested.
# Two neighbouring tiles can each carry traffic and legitimately not connect --
# a diagonal piece (edge codes 1 and 3) running past an orthogonal one (code 2)
# is the common shape, and the shipped saves hold 103 such pairs: 69 in Big
# City, 25 in Kensington, 5 in Rush Hour, 4 in Fulham. Both tiles read 0 on the
# edge they share. Demanding those be connected would be inventing a road SC4
# never drew.
#
# Returns an Array of {a, b} cell pairs, each listed once.
func disconnected_adjacencies(transport_class : int) -> Array:
    if _model == null:
        return []
    var component := {}
    var undirected := {}
    for arc in arcs:
        if arc == null or arc.transport_class != transport_class:
            continue
        for pair in [[arc.from_node, arc.to_node], [arc.to_node, arc.from_node]]:
            if not undirected.has(pair[0]):
                undirected[pair[0]] = []
            undirected[pair[0]].append(pair[1])
    var next_id := 0
    for start in undirected.keys():
        if component.has(start):
            continue
        var stack : Array = [start]
        component[start] = next_id
        while not stack.is_empty():
            var current = stack.pop_back()
            for next in undirected.get(current, []):
                if not component.has(next):
                    component[next] = next_id
                    stack.append(next)
        next_id += 1
    var of_cell := {}
    for arc in arcs:
        if arc == null or arc.transport_class != transport_class:
            continue
        if not of_cell.has(arc.cell):
            of_cell[arc.cell] = component.get(arc.from_node, -1)
    var out : Array = []
    for cell in of_cell.keys():
        var tile = _model.tiles.get(cell)
        if tile == null:
            continue
        for side in [SC4PathSubfile.SIDE_EAST, SC4PathSubfile.SIDE_SOUTH]:
            var other : Vector2i = cell + NetworkModel.SIDE_DELTA[side]
            if not of_cell.has(other) or of_cell[other] == of_cell[cell]:
                continue
            var neighbour = _model.tiles.get(other)
            if neighbour == null:
                continue
            # Neither tile need connect this way -- only a pair that both say
            # they do, and then cannot, is a failure to cross the boundary.
            if tile.wnes[side] == 0 or neighbour.wnes[NetworkModel.opposite(side)] == 0:
                continue
            out.append({"a": cell, "b": other})
    return out

# The cells reachable from `cell` following arcs of one class, respecting
# direction. Used to check that a one-way road really is one-way.
func reachable_cells(cell : Vector2i, transport_class : int) -> Dictionary:
    var adj := _adjacency(transport_class)
    var start_nodes : Array = []
    for idx in arcs_by_cell.get(cell, []):
        var arc = arcs[idx]
        if arc != null and arc.transport_class == transport_class:
            start_nodes.append(arc.from_node)
    var seen := {}
    var stack := start_nodes.duplicate()
    for id in start_nodes:
        seen[id] = true
    while not stack.is_empty():
        var current = stack.pop_back()
        for next in adj.get(current, []):
            if not seen.has(next):
                seen[next] = true
                stack.append(next)
    var cells := {}
    for arc in arcs:
        if arc == null or arc.transport_class != transport_class:
            continue
        if seen.has(arc.from_node) or seen.has(arc.to_node):
            cells[arc.cell] = true
    return cells

func classes_present() -> Array:
    var seen := {}
    for arc in arcs:
        if arc != null:
            seen[arc.transport_class] = true
    return seen.keys()

func class_histogram() -> Dictionary:
    var hist := {}
    for arc in arcs:
        if arc == null:
            continue
        var name = SC4PathSubfile.CLASS_NAMES.get(arc.transport_class, "0x%02x" % arc.transport_class)
        hist[name] = hist.get(name, 0) + 1
    return hist

# Structural problems, as a list of human-readable strings. Empty means healthy.
func validate() -> Array:
    var problems : Array = []
    var orphan_nodes := 0
    for id in nodes.keys():
        var node = nodes[id]
        if node.degree() == 0:
            orphan_nodes += 1
        for idx in node.outgoing:
            if idx >= arcs.size() or arcs[idx] == null:
                problems.append("node %s lists a dead outgoing arc %d" % [id, idx])
            elif arcs[idx].from_node != id:
                problems.append("node %s lists arc %d as outgoing but the arc says %s"
                    % [id, idx, arcs[idx].from_node])
        for idx in node.incoming:
            if idx >= arcs.size() or arcs[idx] == null:
                problems.append("node %s lists a dead incoming arc %d" % [id, idx])
            elif arcs[idx].to_node != id:
                problems.append("node %s lists arc %d as incoming but the arc says %s"
                    % [id, idx, arcs[idx].to_node])
    if orphan_nodes > 0:
        problems.append("%d node(s) with no arcs at all" % orphan_nodes)
    for i in range(arcs.size()):
        var arc = arcs[i]
        if arc == null:
            continue
        if not nodes.has(arc.from_node):
            problems.append("arc %d starts at missing node %s" % [i, arc.from_node])
        if not nodes.has(arc.to_node):
            problems.append("arc %d ends at missing node %s" % [i, arc.to_node])
        if arc.length_m <= 0.0:
            problems.append("arc %d has non-positive length %f" % [i, arc.length_m])
        if not _model.tiles.has(arc.cell):
            problems.append("arc %d belongs to cell %s which holds no tile" % [i, arc.cell])
    return problems

# Order-independent digest of the whole graph, for comparing an incremental
# update against a full rebuild.
func fingerprint() -> int:
    var total := 0
    for arc in arcs:
        if arc == null:
            continue
        total += hash("%s>%s|%d|%d|%d,%d" % [arc.from_node, arc.to_node,
            arc.transport_class, arc.path_index, arc.cell.x, arc.cell.y])
    return total

# How many portals never found a partner. A dangling portal is legitimate at a
# dead end, a map border or where a road meets a lot, so this is a number to
# watch rather than a failure.
func dangling_portals() -> int:
    return dangling_report()["total"]

# Splits the dangling portals by whether there is even a tile on the other side
# of their boundary. Only `stranded` is suspicious: a portal facing an occupied
# neighbour that it failed to pair with is a stitch failure, whereas one facing
# empty ground is just where the road stops.
func dangling_report() -> Dictionary:
    var total := 0
    var stranded := 0
    var dead_end := 0
    for id in nodes.keys():
        var node = nodes[id]
        if node.boundary == "":
            continue
        if not node.incoming.is_empty() and not node.outgoing.is_empty():
            continue
        total += 1
        if _boundary_has_both_tiles(node.boundary):
            stranded += 1
        else:
            dead_end += 1
    return {"total": total, "stranded": stranded, "dead_end": dead_end}

# Diagnostic for a failing stitch: for every portal that faces an occupied
# neighbour but found no partner, how far away the nearest candidate on that
# boundary was, and of what class. If the distances cluster just above
# STITCH_TOLERANCE_M the tolerance is too tight; if there is no candidate at
# all the two tiles are not describing the same crossing.
func stranded_diagnosis() -> Dictionary:
    var by_class := {}
    var no_candidate := 0
    var missed := 0
    var gaps : Array = []
    for id in nodes.keys():
        var node = nodes[id]
        if node.boundary == "":
            continue
        if not node.incoming.is_empty() and not node.outgoing.is_empty():
            continue
        if not _boundary_has_both_tiles(node.boundary):
            continue
        var name = SC4PathSubfile.CLASS_NAMES.get(node.transport_class, "?")
        by_class[name] = by_class.get(name, 0) + 1
        var side := _boundary_side(node.boundary)
        var mine := boundary_offset_m(node.pos, side)
        var best := -1.0
        var best_free := -1.0
        for other_id in nodes_by_boundary.get(node.boundary, []):
            if other_id == id:
                continue
            var other = nodes.get(other_id)
            if other == null or other.transport_class != node.transport_class:
                continue
            # Only a portal that could complete this one is a candidate.
            var complements = (node.incoming.is_empty() and not other.incoming.is_empty()) \
                or (node.outgoing.is_empty() and not other.outgoing.is_empty())
            if not complements:
                continue
            var gap : float = abs(boundary_offset_m(other.pos, side) - mine)
            if best < 0.0 or gap < best:
                best = gap
            # A complement that is itself still one-sided is one the stitch
            # could legitimately have taken. One that is already a complete
            # through-lane is somebody else's, and pairing with it would weld
            # two separate lanes together.
            if other.incoming.is_empty() or other.outgoing.is_empty():
                if best_free < 0.0 or gap < best_free:
                    best_free = gap
        if best < 0.0:
            no_candidate += 1
        else:
            gaps.append(best)
        if best_free >= 0.0 and best_free <= STITCH_TOLERANCE_M:
            missed += 1
    gaps.sort()
    return {
        "by_class": by_class,
        "no_candidate": no_candidate,
        "missed_pairable": missed,
        "gap_count": gaps.size(),
        "gap_median": gaps[gaps.size() / 2] if not gaps.is_empty() else -1.0,
        "gap_max": gaps[gaps.size() - 1] if not gaps.is_empty() else -1.0,
    }

# Whether both tiles either side of a boundary key hold a network tile.
func _boundary_has_both_tiles(key : String) -> bool:
    if _model == null:
        return false
    var parts = key.split(",")
    if parts.size() != 3:
        return false
    var low := Vector2i(int(parts[0]), int(parts[1]))
    var high : Vector2i = low + (Vector2i(1, 0) if parts[2] == "E" else Vector2i(0, 1))
    return _model.tiles.has(low) and _model.tiles.has(high)
