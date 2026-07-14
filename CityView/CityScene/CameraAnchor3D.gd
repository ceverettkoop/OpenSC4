extends CharacterBody3D

var zoom = 1
var zoom_list = [292, 146, 73, 32, 16, 8]
var elevations = [60, 55, 50, 45, 45, 45]
var AZIMUTH = deg_to_rad(67.5)
var rotated = 2
var boot = true
var hold_r = []

# --- Free-orbit inspection camera (toggle with F) ---
# A full-3D perspective camera for diagnosing the scene from any angle, separate
# from the fixed SC4 isometric view. RMB drag orbits, MMB drag pans, wheel dollies.
var free_mode := false
var orbit_focus := Vector3.ZERO
var orbit_yaw := 0.0
var orbit_pitch := deg_to_rad(35.0)
var orbit_dist := 60.0

func _ready():
    velocity = Vector3(0, 0, 0)
    self.transform.origin = Vector3(self.transform.origin.x, get_parent().WATER_HEIGHT, self.transform.origin.z)
    _set_view()
    $Camera3D.set_near(-200.0)
    pass

func _input(event):
    # F toggles the free-orbit inspection camera.
    if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
        _toggle_free()
        return
    if free_mode:
        _free_input(event)
        return
    # Panning is handled by arrow keys in _physics_process (edge-scroll removed).
    if event is InputEventMouseButton:
        if event.is_pressed():
            if event.button_index == MOUSE_BUTTON_WHEEL_UP:
                self.zoom += 1
                if self.zoom > 6:
                    self.zoom = 6
                $Camera3D.size = zoom_list[self.zoom-1]
                _set_view()
            elif event.button_index == MOUSE_BUTTON_RIGHT:
                if len(hold_r) == 0:
                    hold_r = [event.position.x, event.position.y]
            elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
                self.zoom -= 1
                if self.zoom < 1:
                    self.zoom = 1
                $Camera3D.size = zoom_list[self.zoom-1]
                _set_view()
        if not event.is_pressed():
            if event.button_index == MOUSE_BUTTON_RIGHT:
                hold_r = []
    elif event is InputEventKey:
        if event.pressed and event.keycode == KEY_PAGEUP:
            rotated = (rotated + 1)%4
            var rot = round(((rotated*(PI/2)) + get_node("../Node3D").rotation.y) / (PI/2))*(PI/2)
            var rot_trans = get_node("../Node3D").transform.rotated(Vector3(0,1,0), rot)
            get_node("../Node3D").set_transform(rot_trans)
            var old = self.transform.origin
            self.transform.origin = Vector3(-old.z, old.y, old.x)
        elif event.pressed and event.keycode == KEY_PAGEDOWN:
            rotated = ((rotated-1)+4)%4
            var rot = round(((rotated*(PI/2)) + get_node("../Node3D").rotation.y) / (PI/2))*(PI/2)
            var rot_trans = get_node("../Node3D").transform.rotated(Vector3(0,1,0), rot)
            get_node("../Node3D").set_transform(rot_trans)
            var old = self.transform.origin
            self.transform.origin = Vector3(old.z, old.y, -old.x)
# Routes input while the free-orbit camera is active: RMB orbits, MMB pans,
# wheel dollies. Everything is relative-motion based so it needs no drag state.
func _free_input(event):
    if event is InputEventMouseMotion:
        if event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
            orbit_yaw -= event.relative.x * 0.008
            orbit_pitch = clamp(orbit_pitch + event.relative.y * 0.008, deg_to_rad(2.0), deg_to_rad(89.0))
            _apply_free()
        elif event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
            var b = $Camera3D.global_transform.basis
            orbit_focus += (-b.x * event.relative.x + b.y * event.relative.y) * orbit_dist * 0.0015
            _apply_free()
    elif event is InputEventMouseButton and event.is_pressed():
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            orbit_dist = max(orbit_dist * 0.9, 1.0)
            _apply_free()
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            orbit_dist = min(orbit_dist * 1.1, 3000.0)
            _apply_free()

# Places the perspective camera on a sphere around orbit_focus.
func _apply_free():
    var offset = Vector3(
        cos(orbit_pitch) * sin(orbit_yaw),
        sin(orbit_pitch),
        cos(orbit_pitch) * cos(orbit_yaw)) * orbit_dist
    var cam := $Camera3D
    cam.global_position = orbit_focus + offset
    cam.look_at(orbit_focus, Vector3.UP)

func _toggle_free():
    free_mode = not free_mode
    var cam := $Camera3D
    if free_mode:
        # Start focused roughly where the iso view was centred (rig origin sits on
        # the water plane under the screen centre).
        orbit_focus = Vector3(self.global_transform.origin.x, get_parent().WATER_HEIGHT, self.global_transform.origin.z)
        cam.projection = Camera3D.PROJECTION_PERSPECTIVE
        cam.fov = 55.0
        cam.near = 0.05
        cam.far = 4000.0
        _apply_free()
        Log.info("Free camera ON (RMB orbit, MMB pan, wheel zoom, arrows pan, F to exit)")
    else:
        cam.projection = Camera3D.PROJECTION_ORTHOGONAL
        cam.near = -200.0
        cam.size = zoom_list[zoom - 1]
        _set_view()
        Log.info("Free camera OFF")

func _physics_process(_delta):
    if free_mode:
        # Arrow keys pan the orbit focus across the ground plane.
        var cam := $Camera3D
        var fwd = Vector3(cam.global_transform.basis.z.x, 0, cam.global_transform.basis.z.z)
        var rgt = Vector3(cam.global_transform.basis.x.x, 0, cam.global_transform.basis.x.z)
        var mv = Vector3.ZERO
        if Input.is_key_pressed(KEY_UP):
            mv -= fwd
        if Input.is_key_pressed(KEY_DOWN):
            mv += fwd
        if Input.is_key_pressed(KEY_LEFT):
            mv -= rgt
        if Input.is_key_pressed(KEY_RIGHT):
            mv += rgt
        if mv != Vector3.ZERO:
            orbit_focus += mv.normalized() * orbit_dist * 0.02
            _apply_free()
        return
    # Arrow-key panning, in the camera's ground plane. Speed scales with zoom so
    # it covers roughly a constant fraction of the view per second.
    var move = Vector3(0, 0, 0)
    var camera_forward = Vector3(self.transform.basis.z.x, 0, self.transform.basis.z.z)
    var camera_left = Vector3(self.transform.basis.x.x, 0, self.transform.basis.x.z)
    if Input.is_key_pressed(KEY_LEFT):
        move -= camera_left
    if Input.is_key_pressed(KEY_RIGHT):
        move += camera_left
    if Input.is_key_pressed(KEY_UP):
        move -= camera_forward
    if Input.is_key_pressed(KEY_DOWN):
        move += camera_forward
    self.velocity = move.normalized() * $Camera3D.size
    self.set_velocity(self.velocity)
    self.move_and_slide()

func _set_view():
    # Elevation angle, Azimuth is a class var since it doesn't change
    var El = deg_to_rad(elevations[zoom-1])
    
    # exposure angles D and E
    var D = atan( (cos(El)) / (tan(AZIMUTH)) )
    var E = atan( (cos(El)) * (tan(AZIMUTH)) )
    # axis shrink factors 
    var Sx = sin(AZIMUTH) / cos(D)
    var Sz = cos(AZIMUTH) / cos(E)
    var Sy = sin(El)
    # range divisor, not sure why its needed
    var rng_d = 1
    # setting up the transform
    var v_trans = transform
    v_trans.basis.x = Vector3((Sx*cos(D))/rng_d, 	0.0, 		Sx*sin(D)/rng_d)
    v_trans.basis.y = Vector3(0.0, 					1.0, 		Sy/rng_d)
    v_trans.basis.z = Vector3(-(Sz*cos(E))/rng_d, 	-1.0, 		(Sz*sin(E))/rng_d)
    v_trans = v_trans.inverse()
    v_trans.origin = self.transform.origin
    self.transform = v_trans
    #print("in", v_trans, "\ncm", self.get_node("Camera3D").transform)
    
    # set sun location
    self.get_node("../Sun").transform.origin = Vector3(-50, 30, 20)
    self.get_node("../Sun").look_at(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0))
    
    # set zoom related uniforms for shaders
    var mat = self.get_parent().get_node("Node3D/Terrain").get_material_override()
    mat.set_shader_parameter("zoom", zoom)
    mat.set_shader_parameter("tiling_factor", zoom)
    self.get_parent().get_node("Node3D/Terrain").set_material_override(mat)
    var mat_e = self.get_parent().get_node("Node3D/Border").get_material_override()
    mat_e.set_shader_parameter("zoom", zoom)
    mat_e.set_shader_parameter("tiling_factor", zoom)
    self.get_parent().get_node("Node3D/Border").set_material_override(mat_e)
    var mat_w = self.get_parent().get_node("Node3D/WaterPlane").get_material_override()
    mat_w.set_shader_parameter("zoom", zoom)
    mat_w.set_shader_parameter("tiling_factor", zoom)
    self.get_parent().get_node("Node3D/WaterPlane").set_material_override(mat_w)
    
