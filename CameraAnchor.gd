extends CharacterBody2D

var viewport = 0
var margin_w = 0
var margin_h = 0
var move = Vector2(0, 0)
var mouse_right_click_origin = Vector2(0, 0)
var mouse_position = Vector2(0, 0)

#Should move one screen width every 4 seconds
#var move_speed = viewport.size.x / 4
var move_speed = 16834 # just manually setting it idk

# Zoom limits/step for the region Camera2D. In Godot 4, Camera2D.zoom is a
# magnification factor: >1 zooms in, <1 zooms out.
var zoom_min = 0.1
var zoom_max = 3.0
var zoom_step = 1.15

@onready var camera: Camera2D = $MainCamera

func _ready():
    velocity = Vector2(0, 0)
    pass

func _apply_zoom(factor):
    var z = clamp(camera.zoom.x * factor, zoom_min, zoom_max)
    camera.zoom = Vector2(z, z)

# Center the camera on world_rect and pick a zoom that fits it in the viewport
# (with a little margin). Called once after the region's cities are placed.
func focus_on(world_rect: Rect2):
    var vp = get_viewport().get_visible_rect().size
    var fit = min(vp.x / max(world_rect.size.x, 1.0), vp.y / max(world_rect.size.y, 1.0)) * 0.85
    camera.zoom = Vector2(clamp(fit, zoom_min, zoom_max), clamp(fit, zoom_min, zoom_max))
    self.global_position = world_rect.position + world_rect.size * 0.5

func _input(event):
    viewport = self.get_viewport()
    margin_w = viewport.size.x / 15
    margin_h = viewport.size.y / 15

    if event is InputEventMouseButton and event.pressed:
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            _apply_zoom(zoom_step)
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            _apply_zoom(1.0 / zoom_step)

    if event is InputEventMouseMotion:
        if event.position.x < margin_w:
            move.x = -1
        elif event.position.x > viewport.size.x - margin_w:
            move.x = 1
        
        if event.position.y < margin_h:
            move.y = -1
        elif event.position.y > viewport.size.y - margin_h:
            move.y = 1		
    
    if Input.is_action_pressed("camera_up"):
        move.y = -1
    elif Input.is_action_pressed("camera_down"):
        move.y = 1
    
    if Input.is_action_pressed("camera_left"):
        move.x = -1
    elif Input.is_action_pressed("camera_right"):
        move.x = 1
    
    # `normalized() * move_speed` so no fast diagonal movement.
    # Divide by zoom so panning covers the same on-screen distance at any zoom.
    self.velocity = move.normalized() * move_speed / camera.zoom.x
    
    # reset variables
    move.x = 0
    move.y = 0

func right_click_movement():
    if Input.is_action_just_pressed("camera_right_click"):
        mouse_right_click_origin = get_local_mouse_position()
    
    if Input.is_action_pressed("camera_right_click"):
        mouse_position = get_local_mouse_position()
        move = mouse_position - mouse_right_click_origin
        
        self.velocity = move.normalized() * move_speed * move.length()/256 / camera.zoom.x
        
        move.x = 0
        move.y = 0

func _process(delta):
    right_click_movement()
    self.set_velocity(self.velocity * delta)
    self.move_and_slide()
    self.velocity
