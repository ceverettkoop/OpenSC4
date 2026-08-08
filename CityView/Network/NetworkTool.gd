extends Node3D

# The build tool: draw roads, bulldoze them, and keep the network model in step.
#
# Split out of TransitTiles.gd, which handled input inside the same node that
# owned the RUL database and the meshes. Two things made that worth separating
# beyond tidiness. Bulldozing needs a different interaction from drawing -- a
# rectangle, not a direction-snapped run -- and none of it could be driven from
# a headless harness, because every path into the tool started at a mouse
# event. Everything here has a plain method behind it that tests can call.
#
# Keys: R draw, B bulldoze, Escape none, Ctrl toggles drag-vs-existing priority
# at intersections, and the mode is shown in the corner.
#
# Edits are PERMANENT. There is no undo in the editing stack -- neither here nor
# in NetworkModel or LotModel -- so a committed drag or bulldoze is the end of
# it.
class_name NetworkTool

enum Mode { NONE, DRAW, BULLDOZE }

# How far a click ray reaches, in world units. The map is 128 tiles across, so
# this clears it from any camera position.
const RAY_LENGTH : float = 2000.0

# Returned by pick_tile() when the ray missed the terrain or landed off the map.
# The old code returned Vector2() for a miss, which is indistinguishable from
# tile (0, 0), and callers tested it for truthiness -- so a click on the skybox
# quietly built a road in the map corner.
const NO_TILE : Vector2i = Vector2i(-2147483648, -2147483648)

signal mode_changed(mode : int)

var mode : int = Mode.NONE
var network : String = "Road"

var model : NetworkModel = null
var renderer : Node = null              # NetworkRenderer
var piece_db : NetworkPieceDB = null
var lots : LotModel = null

# Drag state. `drag_from` is NO_TILE when no drag is in progress.
var drag_from : Vector2i = NO_TILE
var drag_to : Vector2i = NO_TILE
# Whether a new drag overrides the existing tiles at an intersection, or defers
# to them. Toggled with Ctrl, as before.
var drag_first : bool = true

var _map_w : int = 0
var _map_h : int = 0

func setup(network_model : NetworkModel, network_renderer : Node,
        db : NetworkPieceDB, map_w : int, map_h : int,
        lot_model : LotModel = null) -> void:
    model = network_model
    renderer = network_renderer
    piece_db = db
    _map_w = map_w
    _map_h = map_h
    lots = lot_model

# --- input -------------------------------------------------------------------
#
# On _unhandled_input rather than _input, so the camera (which stays on _input)
# keeps right-drag orbit and wheel zoom, and any UI gets first refusal on a
# click. The tool only sees what nothing else claimed.

func _unhandled_input(event : InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo:
        if _handle_key(event.keycode):
            get_viewport().set_input_as_handled()
        return
    if mode == Mode.NONE:
        return
    # The free-orbit inspection camera uses the mouse for looking around.
    var camera_rig = get_parent().get_node_or_null("CameraHandler")
    if camera_rig != null and camera_rig.get("free_mode"):
        return

    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
        if event.pressed:
            var tile := pick_tile()
            if tile == NO_TILE:
                return
            drag_from = tile
            drag_to = tile
            _preview()
        elif drag_from != NO_TILE:
            commit()
        get_viewport().set_input_as_handled()
    elif event is InputEventMouseMotion and drag_from != NO_TILE:
        var tile := pick_tile()
        if tile == NO_TILE or tile == drag_to:
            return
        drag_to = tile
        _preview()

func _handle_key(keycode : int) -> bool:
    match keycode:
        KEY_R:
            set_mode(Mode.DRAW)
            return true
        KEY_B:
            set_mode(Mode.BULLDOZE)
            return true
        KEY_ESCAPE:
            set_mode(Mode.NONE)
            return true
        # Comma/period rather than the brackets, which the camera already
        # uses for rotation -- the tool was shadowing it while active.
        KEY_COMMA when mode != Mode.NONE:
            cycle_network(-1)
            return true
        KEY_PERIOD when mode != Mode.NONE:
            cycle_network(1)
            return true
        # Only while a drag is live, so it cannot be flipped by accident between
        # drags.
        KEY_CTRL when drag_from != NO_TILE:
            drag_first = not drag_first
            _preview()
            return true
    return false

func set_mode(new_mode : int) -> void:
    if new_mode == mode:
        return
    _cancel_drag()
    mode = new_mode
    mode_changed.emit(mode)
    Log.info("Network tool: %s%s" % [mode_name(), (" (%s)" % network) if mode == Mode.DRAW else ""])

func mode_name() -> String:
    match mode:
        Mode.DRAW: return "draw"
        Mode.BULLDOZE: return "bulldoze"
    return "off"

func cycle_network(step : int) -> void:
    var list = NetworkPieceDB.BUILDABLE
    var idx = list.find(network)
    network = list[posmod(idx + step, list.size())]
    Log.info("Network tool: %s" % network)
    mode_changed.emit(mode)

# --- picking -----------------------------------------------------------------

# The city tile under the mouse, or NO_TILE. Only the terrain has collision, so
# this is a ray against the terrain trimesh built in City.create_terrain().
func pick_tile() -> Vector2i:
    var camera := get_viewport().get_camera_3d()
    if camera == null:
        return NO_TILE
    var mouse := get_viewport().get_mouse_position()
    var from := camera.project_ray_origin(mouse)
    var to := from + camera.project_ray_normal(mouse) * RAY_LENGTH
    var query := PhysicsRayQueryParameters3D.create(from, to)
    query.collide_with_areas = false
    var hit := get_world_3d().direct_space_state.intersect_ray(query)
    if not hit.has("position"):
        return NO_TILE
    return world_to_tile(hit["position"])

# World point to city tile. The world sits under a Node3D that CameraAnchor3D
# rotates on a view rotate (rather than rotating the camera), so the hit has to
# be pulled back into that node's local space before it means anything.
func world_to_tile(world : Vector3) -> Vector2i:
    var host := get_parent().get_node_or_null("Node3D")
    var local : Vector3 = world if host == null else host.transform.affine_inverse() * world
    var tile := Vector2i(int(floor(local.x)), int(floor(local.z)))
    if tile.x < 0 or tile.y < 0 or tile.x >= _map_w or tile.y >= _map_h:
        return NO_TILE
    return tile

# --- drag --------------------------------------------------------------------

func _cancel_drag() -> void:
    drag_from = NO_TILE
    drag_to = NO_TILE
    if renderer != null:
        renderer.clear_preview()

func _preview() -> void:
    if renderer == null or drag_from == NO_TILE:
        return
    if mode == Mode.DRAW:
        renderer.preview_draw(drag_from, drag_to, network, drag_first)
    else:
        renderer.preview_bulldoze(bulldoze_preview_cells())

# What a bulldoze would actually take, for the highlight. A lot comes out whole
# even when the box only clips its corner, so the preview covers the whole lot
# -- highlighting just the part inside the box would understate the damage.
func bulldoze_preview_cells() -> Array:
    var box := bulldoze_box_cells()
    var seen := {}
    for cell in box:
        if model != null and model.has_tile(cell):
            seen[cell] = true
    if lots != null:
        for lot in lots.lots_over(box, true):
            for cell in LotModel.cells_of(lot):
                seen[cell] = true
    return seen.keys()

# Every cell inside the bulldoze box, whether or not anything stands there.
# Filtering to occupied cells is left to the two things that consume this,
# because they do not agree on what "occupied" means: the network cares about
# its tiles, the bulldozer also has to take a lot sitting on bare ground.
func bulldoze_box_cells() -> Array:
    if drag_from == NO_TILE or drag_to == NO_TILE:
        return []
    var cells : Array = []
    for x in range(mini(drag_from.x, drag_to.x), maxi(drag_from.x, drag_to.x) + 1):
        for z in range(mini(drag_from.y, drag_to.y), maxi(drag_from.y, drag_to.y) + 1):
            cells.append(Vector2i(x, z))
    return cells

# The subset of the box that holds a network tile.
func bulldoze_cells() -> Array:
    var cells : Array = []
    for cell in bulldoze_box_cells():
        if model != null and model.has_tile(cell):
            cells.append(cell)
    return cells

# Applies the pending drag. Everything reaches the models through here, so the
# graph cannot end up describing something other than what was drawn.
func commit() -> Array:
    var changed : Array = []
    if mode == Mode.DRAW and renderer != null:
        # Lots first. A road laid over a zoned building flattens it -- SC4 lets
        # a road eat a growable lot that is in the way, and only refuses over a
        # plopped one. Clearing before the tiles are placed keeps the order the
        # same as a bulldoze followed by a draw.
        _raze_lots(renderer.pending_cells())
        changed = renderer.commit_draw()
    elif mode == Mode.BULLDOZE:
        _raze_lots(bulldoze_box_cells())
        var cells := bulldoze_cells()
        if not cells.is_empty() and model != null:
            changed = model.remove(cells)
            renderer.forget_cells(cells)
    _cancel_drag()
    return changed

# Bulldozes the growable lots covering `cells`. Plopped lots are left alone:
# a stadium does not give way to a road.
func _raze_lots(cells : Array) -> Array:
    if lots == null or cells.is_empty():
        return []
    var doomed := lots.lots_over(cells, true)
    if doomed.is_empty():
        return []
    var freed := lots.remove(doomed)
    Log.info("Razed %d growable lot(s) over %d tiles" % [doomed.size(), freed.size()])
    return freed

# --- scripted entry points, for harnesses ------------------------------------
#
# These are the same operations the mouse drives, without the mouse, so the
# tool can be exercised headlessly.

func draw_line(from : Vector2i, to : Vector2i, network_name : String = "") -> Array:
    if not network_name.is_empty():
        network = network_name
    var previous := mode
    mode = Mode.DRAW
    drag_from = from
    drag_to = to
    _preview()
    var changed := commit()
    mode = previous
    return changed

# Bulldozes whatever stands on `cells`: network tiles and growable lots both.
func bulldoze(cells : Array) -> Array:
    if cells.is_empty():
        return []
    _raze_lots(cells)
    var present : Array = []
    for cell in cells:
        if model != null and model.has_tile(cell):
            present.append(cell)
    if present.is_empty():
        return []
    var changed := model.remove(present)
    if renderer != null:
        renderer.forget_cells(present)
    return changed

func bulldoze_box(from : Vector2i, to : Vector2i) -> Array:
    drag_from = from
    drag_to = to
    var cells := bulldoze_box_cells()
    _cancel_drag()
    return bulldoze(cells)
