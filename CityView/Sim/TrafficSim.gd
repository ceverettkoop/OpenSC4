extends RefCounted

# Monthly commute assignment over the car graph -- step 4 of
# dev_notes/simulation_plan.md. Writes SimGrids.DERIVED_TRAFFIC: trips per
# tile, in "lot tiles that commute through here" units.
#
# Demand is the plan's: one commute per residential lot, weighted by the
# lot's footprint (bigger lot, more sims), from the lot's own commute tile
# (LotRecord.commute_x/z -- the save's "where this lot meets the road")
# toward the NEAREST job, where jobs are commercial and industrial lots'
# commute tiles.
#
# Routing is exact shortest-path over the NetworkGraph's car arcs with
# travel time = length_m / driving speed for the arc's network, speeds from
# the Traffic Simulator exemplar's "Driving Speed" 13-element per-network
# array (T 0x6534284A G 0xE7E2C2DB I 0xC9133286, property 0x491332E8 --
# see dev_notes/save_file_analysis §11). One multi-source Dijkstra runs
# BACKWARDS from every job portal, giving each node its time-to-nearest-job;
# each residential origin then descends that gradient, adding its weight to
# every cell its path crosses. That is one O(E log V) pass total instead of
# one search per lot.
#
# What this deliberately is not yet: capacity/congestion (SC4's per-network
# capacities live in the EXE, not the DATs -- §11 "Not found"), mode choice
# (everyone drives), or trip chaining. Volumes are therefore comparable to
# the save's TRAFFIC_CAR in SHAPE, not in absolute units, which is what the
# harness gates: where we put traffic, SC4 put traffic (precision), and
# busier-here-than-there mostly agrees (rank correlation).
class_name TrafficSim

const TRAFFIC_SIM_GROUP : int = 0xe7e2c2db
const TRAFFIC_SIM_INSTANCE : int = 0xc9133286
const PROP_DRIVING_SPEED : int = 0x491332e8

# Fallback = the shipped exemplar's values, so a missing DAT does not zero
# every speed (index = NetworkSubfile network type).
const DRIVING_SPEED_FALLBACK : Array = [31.0, 0.0, 82.0, 21.0, 0.0, 0.0, 40.0, 0.0, 0.0, 0.0, 31.0, 0.0, 82.0]

var city = null
var _speeds : Array = []

func _init(city_):
    city = city_

func tick(_month : int) -> void:
    var grids : SimGrids = city.sim_grids_model()
    var side : int = grids.map_tiles
    var field : Array = []
    field.resize(side * side)
    field.fill(0.0)
    var graph = city.network_graph
    var lots = city.lot_model
    if graph != null and lots != null:
        _assign(field, side, graph, lots)
    grids.commit_derived(SimGrids.DERIVED_TRAFFIC, field, side)

func _assign(field : Array, side : int, graph, lots) -> void:
    if _speeds.is_empty():
        _speeds = _load_speeds()
    # Arc travel times, indexed like graph.arcs. null = not drivable.
    var cost : Array = []
    cost.resize(graph.arcs.size())
    for i in range(graph.arcs.size()):
        var arc = graph.arcs[i]
        if arc == null or arc.transport_class != SC4PathSubfile.CLASS_CAR:
            continue
        var tile = city.network_model.get_tile(arc.cell)
        var speed : float = 0.0
        if tile != null:
            var net : int = tile.network_type()
            if net >= 0 and net < _speeds.size():
                speed = _speeds[net]
        if speed <= 0.0:
            speed = DRIVING_SPEED_FALLBACK[0]   # unknown piece: assume road
        cost[i] = maxf(arc.length_m, 0.1) / speed

    # Sinks: every job lot's attachment portals, at distance 0.
    var dist := {}
    var heap : Array = []
    for lot in lots.lots:
        if lots.lot_at(Vector2i(lot.min_x, lot.min_z)) != lot:
            continue    # razed or overshadowed
        if lot.zone_type < 4 or lot.zone_type > 9:
            continue
        for node_id in _attachment_nodes(graph, lot):
            if not dist.has(node_id):
                dist[node_id] = 0.0
                _heap_push(heap, [0.0, node_id])

    # Multi-source Dijkstra over REVERSED car arcs: dist[n] = travel time
    # from n forward to the nearest job.
    var incoming_cost := {}    # node id -> Array of [arc_idx, from_node]
    for i in range(graph.arcs.size()):
        if cost[i] == null:
            continue
        var arc = graph.arcs[i]
        if not incoming_cost.has(arc.to_node):
            incoming_cost[arc.to_node] = []
        incoming_cost[arc.to_node].append(i)
    while not heap.is_empty():
        var top : Array = _heap_pop(heap)
        var d : float = top[0]
        var u : String = top[1]
        if d > dist.get(u, INF):
            continue
        for i in incoming_cost.get(u, []):
            var arc = graph.arcs[i]
            var nd : float = d + cost[i]
            if nd < dist.get(arc.from_node, INF):
                dist[arc.from_node] = nd
                _heap_push(heap, [nd, arc.from_node])

    # Each residential lot descends the gradient from its commute tile.
    for lot in lots.lots:
        if lots.lot_at(Vector2i(lot.min_x, lot.min_z)) != lot:
            continue
        if lot.zone_type < 1 or lot.zone_type > 3:
            continue
        var weight : float = float(LotModel.cells_of(lot).size())
        var start : String = ""
        var best : float = INF
        for node_id in _attachment_nodes(graph, lot):
            var d : float = dist.get(node_id, INF)
            if d < best:
                best = d
                start = node_id
        if start == "":
            continue    # no route from this lot to any job
        _descend(field, side, graph, cost, dist, start, weight)

# Walks the shortest-path tree from `start` toward a sink, adding `weight`
# to every cell crossed. Each hop must strictly reduce the remaining time,
# so the walk cannot cycle; the step cap is a belt against float ties.
func _descend(field : Array, side : int, graph, cost : Array, dist : Dictionary,
        start : String, weight : float) -> void:
    var current : String = start
    for _step in range(4096):
        var remaining : float = dist.get(current, INF)
        if remaining <= 0.0:
            return
        var node = graph.nodes.get(current)
        if node == null:
            return
        var best_arc : int = -1
        var best_total : float = INF
        for i in node.outgoing:
            if cost[i] == null:
                continue
            var total : float = cost[i] + dist.get(graph.arcs[i].to_node, INF)
            if total < best_total:
                best_total = total
                best_arc = i
        if best_arc < 0 or best_total >= remaining + 0.001:
            return
        var arc = graph.arcs[best_arc]
        var cell : Vector2i = arc.cell
        if cell.x >= 0 and cell.y >= 0 and cell.x < side and cell.y < side:
            field[cell.x * side + cell.y] += weight
        current = arc.to_node

# The car portals a lot can enter/leave the network by: every car arc's
# endpoints on the lot's commute tile, widening to the four neighbours when
# the commute tile itself carries no arcs (the record points at the lot's
# road-facing tile on some saves and at the road itself on others).
func _attachment_nodes(graph, lot) -> Array:
    var commute := Vector2i(lot.commute_x, lot.commute_z)
    var out := {}
    for cell in [commute, commute + Vector2i(1, 0), commute + Vector2i(-1, 0),
            commute + Vector2i(0, 1), commute + Vector2i(0, -1)]:
        for i in graph.arcs_by_cell.get(cell, []):
            var arc = graph.arcs[i]
            if arc != null and arc.transport_class == SC4PathSubfile.CLASS_CAR:
                out[arc.from_node] = true
                out[arc.to_node] = true
        if not out.is_empty():
            break    # nearest ring with any car access wins
    return out.keys()

func _load_speeds() -> Array:
    var ex = null
    if Core.subfile_indices.has(SubfileTGI.TGI2str(0x6534284a, TRAFFIC_SIM_GROUP, TRAFFIC_SIM_INSTANCE)):
        ex = Core.subfile(0x6534284a, TRAFFIC_SIM_GROUP, TRAFFIC_SIM_INSTANCE, ExemplarSubfile)
    if ex != null and typeof(ex.properties.get(PROP_DRIVING_SPEED)) == TYPE_ARRAY:
        return ex.properties[PROP_DRIVING_SPEED]
    return DRIVING_SPEED_FALLBACK

# --- tiny binary min-heap on [priority, value] pairs -------------------------

static func _heap_push(heap : Array, item : Array) -> void:
    heap.append(item)
    var i : int = heap.size() - 1
    while i > 0:
        var parent : int = (i - 1) >> 1
        if heap[parent][0] <= heap[i][0]:
            break
        var tmp = heap[parent]
        heap[parent] = heap[i]
        heap[i] = tmp
        i = parent

static func _heap_pop(heap : Array) -> Array:
    var top : Array = heap[0]
    var last = heap.pop_back()
    if not heap.is_empty():
        heap[0] = last
        var i : int = 0
        var n : int = heap.size()
        while true:
            var left : int = 2 * i + 1
            var right : int = left + 1
            var smallest : int = i
            if left < n and heap[left][0] < heap[smallest][0]:
                smallest = left
            if right < n and heap[right][0] < heap[smallest][0]:
                smallest = right
            if smallest == i:
                break
            var tmp = heap[smallest]
            heap[smallest] = heap[i]
            heap[i] = tmp
            i = smallest
    return top
