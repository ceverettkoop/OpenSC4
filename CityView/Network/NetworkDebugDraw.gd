extends MeshInstance3D

# Draws the network graph over the city as coloured lines: every arc's polyline,
# a chevron showing which way it runs, and a marker at every portal.
#
# This is not decoration. The graph is derived through a chain of conventions --
# a rotation, a mirror, a north axis, a lane offset -- each of which produces a
# plausible-looking road network when wrong. A 90-degree path rotation looks
# fine on a four-way intersection and only shows up as arcs cutting the corner.
# Seeing the lanes on top of the road texture is how those get caught.
#
# Parented to the world Node3D rather than to City: CameraAnchor3D rotates that
# node on a view rotate (not the camera), so anything parented higher would
# drift away from the terrain the moment the player turns the view.
class_name NetworkDebugDraw

# Clear of NETWORK_SURFACE_LIFT (0.075) so the lines read on top of the road.
const LIFT : float = 0.12
# Fraction along each arc where the direction chevron sits.
const CHEVRON_AT : float = 0.75
const CHEVRON_SIZE : float = 0.06      # world units
const PORTAL_SIZE : float = 0.05

# One colour per traveller class. Sim is deliberately dim: pedestrian arcs
# outnumber car arcs almost 1:1 and would otherwise swamp the picture.
const CLASS_COLOURS : Dictionary = {
    SC4PathSubfile.CLASS_CAR: Color(1.0, 1.0, 1.0),
    SC4PathSubfile.CLASS_SIM: Color(0.85, 0.75, 0.2),
    SC4PathSubfile.CLASS_TRAIN: Color(0.6, 0.6, 0.65),
    SC4PathSubfile.CLASS_SUBWAY: Color(0.3, 0.5, 1.0),
    SC4PathSubfile.CLASS_ELTRAIN: Color(0.3, 0.9, 0.4),
    SC4PathSubfile.CLASS_MONORAIL: Color(0.9, 0.3, 0.9),
}
const SYNTHESISED_COLOUR : Color = Color(1.0, 0.2, 0.8)
# A portal that never found a partner. Mostly legitimate -- dead ends, sidewalks
# with no continuation -- but a rash of them along a straight road means the
# stitch is failing, which is exactly what you want to see rather than read.
const DANGLING_COLOUR : Color = Color(1.0, 0.25, 0.25)
const PORTAL_COLOUR : Color = Color(0.2, 0.9, 0.9)

var graph : NetworkGraph = null
# Classes to draw. Everything except pedestrians by default -- Sim arcs roughly
# double the line count for little insight once the roads are confirmed.
var visible_classes : Dictionary = {
    SC4PathSubfile.CLASS_CAR: true,
    SC4PathSubfile.CLASS_TRAIN: true,
    SC4PathSubfile.CLASS_SUBWAY: true,
    SC4PathSubfile.CLASS_ELTRAIN: true,
    SC4PathSubfile.CLASS_MONORAIL: true,
}
var show_portals : bool = true

var _rebuild_queued : bool = false

func _init():
    visible = false

func attach(network_graph : NetworkGraph) -> void:
    graph = network_graph
    _make_material()
    if visible:
        rebuild()

func _make_material() -> void:
    var mat := StandardMaterial3D.new()
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.vertex_color_use_as_albedo = true
    mat.cull_mode = BaseMaterial3D.CULL_DISABLED
    # Lines are thin enough that depth fighting with the road quads reads as
    # dashes; drawing on top is more useful than being strictly correct.
    mat.no_depth_test = true
    mat.render_priority = 20
    material_override = mat

# Rebuilds on the next idle frame rather than immediately, so a drag that
# dirties the same cells many times in one frame only costs one rebuild.
func queue_rebuild() -> void:
    if _rebuild_queued or not visible:
        return
    _rebuild_queued = true
    _do_rebuild.call_deferred()

func _do_rebuild() -> void:
    _rebuild_queued = false
    rebuild()

func set_shown(on : bool) -> void:
    visible = on
    if on:
        rebuild()

func toggle() -> bool:
    set_shown(not visible)
    return visible

func toggle_class(transport_class : int) -> void:
    visible_classes[transport_class] = not visible_classes.get(transport_class, false)
    if visible:
        rebuild()

func rebuild() -> void:
    if graph == null:
        return
    var verts := PackedVector3Array()
    var colours := PackedColorArray()

    for arc in graph.arcs:
        if arc == null or not visible_classes.get(arc.transport_class, false):
            continue
        if arc.polyline.size() < 2:
            continue
        var colour : Color = SYNTHESISED_COLOUR if arc.synthesised \
            else CLASS_COLOURS.get(arc.transport_class, Color.WHITE)
        for i in range(1, arc.polyline.size()):
            verts.append(_lift(arc.polyline[i - 1]))
            verts.append(_lift(arc.polyline[i]))
            colours.append(colour)
            colours.append(colour)
        _append_chevron(verts, colours, arc, colour)

    if show_portals:
        for id in graph.nodes.keys():
            var node = graph.nodes[id]
            if not visible_classes.get(node.transport_class, false):
                continue
            var dangling : bool = node.incoming.is_empty() or node.outgoing.is_empty()
            _append_cross(verts, colours, _lift(node.pos),
                DANGLING_COLOUR if dangling else PORTAL_COLOUR,
                PORTAL_SIZE * (1.6 if dangling else 1.0))

    if verts.is_empty():
        mesh = null
        return
    var arrays := []
    arrays.resize(ArrayMesh.ARRAY_MAX)
    arrays[ArrayMesh.ARRAY_VERTEX] = verts
    arrays[ArrayMesh.ARRAY_COLOR] = colours
    var built := ArrayMesh.new()
    built.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
    mesh = built

static func _lift(p : Vector3) -> Vector3:
    return Vector3(p.x, p.y + LIFT, p.z)

# A two-stroke arrowhead partway along the arc. Without it a one-way street and
# a two-way one look identical, which is most of what there is to check.
func _append_chevron(verts : PackedVector3Array, colours : PackedColorArray,
        arc, colour : Color) -> void:
    var count : int = arc.polyline.size()
    var idx : int = clampi(int(count * CHEVRON_AT), 1, count - 1)
    var tip := _lift(arc.polyline[idx])
    var back := _lift(arc.polyline[idx - 1])
    var dir := (tip - back)
    if dir.length() < 0.0001:
        return
    dir = dir.normalized()
    var side := Vector3(-dir.z, 0.0, dir.x)
    for wing in [side, -side]:
        verts.append(tip)
        verts.append(tip - dir * CHEVRON_SIZE * 1.5 + wing * CHEVRON_SIZE)
        colours.append(colour)
        colours.append(colour)

static func _append_cross(verts : PackedVector3Array, colours : PackedColorArray,
        at : Vector3, colour : Color, size : float) -> void:
    for axis in [Vector3(size, 0, 0), Vector3(0, 0, size), Vector3(0, size, 0)]:
        verts.append(at - axis)
        verts.append(at + axis)
        colours.append(colour)
        colours.append(colour)

# {what: count} for logging, so the harness can say what it drew.
func stats() -> Dictionary:
    if graph == null:
        return {}
    var drawn := 0
    for arc in graph.arcs:
        if arc != null and visible_classes.get(arc.transport_class, false):
            drawn += 1
    return {"arcs_drawn": drawn, "arcs_total": graph.arc_count(),
        "nodes": graph.node_count(), "visible": visible}
