extends Node

# Windowed variant of the HeadlessCity harness: loads the DATs and a city save
# exactly like tools/headless_city.gd, renders a few frames, and saves viewport
# screenshots for visual verification (building placement etc.), then quits.
#
# Run (needs a display; NOT --headless -- use xvfb-run for an unattended loop):
#   godot --path . --resolution 1600x900 res://tools/ScreenshotCity.tscn -- <out_dir> ["<region>" "<city name>"] [shot ...]
#
# With no shot specs it writes <out_dir>/city_zoom1.png (whole map) and
# <out_dir>/city_zoom4.png (closer view centred on the map).
#
# A shot spec aims the iso camera at one tile: "tx,tz,zoom[,rot][,name]" where
# tx/tz are city tile coordinates (0..127 on a 2x2 km map), zoom is 1..6 (1 =
# whole map, 6 = a handful of tiles) and rot is the quarter-turn 0..3. Each shot
# is written to <out_dir>/<name>.png, defaulting to shot_<tx>_<tz>_z<zoom>_r<rot>.
# The bare argument "pipes" reveals the (normally hidden) underground pipe layer.
#
# Under Xvfb the Vulkan renderer has no presentable device, so add
# --rendering-driver opengl3:
#   xvfb-run -a --server-args="-screen 0 1600x900x24" godot --path . \
#       --rendering-driver opengl3 --resolution 1600x900 res://tools/ScreenshotCity.tscn -- ...
# Example:
#   ... -- /tmp/shots "Timbuktu" "Big City Tutorial" 64,64,4 32,96,5 100,20,5,2,rail_xing

const DEFAULT_REGION = "Timbuktu"
const DEFAULT_CITY = "Big City Tutorial"

var dat_files = [
    "SimCity_1.dat",
    "SimCity_2.dat",
    "SimCity_3.dat",
    "SimCity_4.dat",
    "SimCity_5.dat",
    "EP1.dat",
]

func _ready():
    var user_args = OS.get_cmdline_user_args()
    if user_args.is_empty():
        push_error("Usage: ... res://tools/ScreenshotCity.tscn -- <out_dir> [<region> <city>]")
        get_tree().quit(1)
        return
    var out_dir = user_args[0]
    var region = DEFAULT_REGION
    var city_name = DEFAULT_CITY
    var shots : Array = []
    var show_pipes = false
    if user_args.size() >= 3:
        region = user_args[1]
        city_name = user_args[2]
        for i in range(3, user_args.size()):
            if user_args[i] == "pipes":
                show_pipes = true
                continue
            var shot = _parse_shot(user_args[i])
            if shot == null:
                push_error("Bad shot spec %s -- want tx,tz,zoom[,rot][,name]" % user_args[i])
                get_tree().quit(1)
                return
            shots.append(shot)

    if Core.game_dir == null:
        var config = INI.new("user://config.ini")
        if config.sections.has("paths"):
            Core.game_dir = config.sections["paths"]["sc4_files"]
        else:
            Core.game_dir = ProjectSettings.globalize_path("res://")

    for dat_file in dat_files:
        Core.add_dbpf(DBPF.new(Core.game_dir + "/" + dat_file))
    print("DATs loaded")

    var city_path = "%s/Regions/%s/City - %s.sc4" % [Core.game_dir, region, city_name]
    if not FileAccess.file_exists(city_path):
        push_error("No such city save: %s" % city_path)
        get_tree().quit(1)
        return
    Boot.current_city = DBPF.new(city_path)
    Boot.current_city_name = city_name
    Boot.current_city_path = city_path
    Boot.current_region_name = region

    var city = load("res://CityView/CityScene/City.tscn").instantiate()
    add_child(city)
    if not city.has_method("set_building_view"):
        push_error("City script not attached (compile error?) -- aborting")
        get_tree().quit(1)
        return
    print("City ready, capturing")
    if show_pipes:
        city.set_pipes_visible(true)

    var cam = city.get_node("CameraHandler")
    var half = city.size_w * 64 / 2.0    # world units are tiles

    if shots.is_empty():
        await _capture("%s/city_zoom1.png" % out_dir)
        # Closer pass: move the iso camera to the map centre at zoom 4 so
        # building clusters/alignment are inspectable.
        _aim(city, cam, half, half, 4, cam.rotated)
        await _capture("%s/city_zoom4.png" % out_dir)
    else:
        for shot in shots:
            _aim(city, cam, shot.tx, shot.tz, shot.zoom, shot.rot)
            await _capture("%s/%s.png" % [out_dir, shot.name])

    print("SCREENSHOTS DONE")
    get_tree().quit()

# "tx,tz,zoom[,rot][,name]" -> {tx, tz, zoom, rot, name}, or null if malformed.
func _parse_shot(spec : String):
    var parts = spec.split(",")
    if parts.size() < 3 or parts.size() > 5:
        return null
    for i in range(3):
        if not parts[i].is_valid_float():
            return null
    var shot = {
        "tx": float(parts[0]),
        "tz": float(parts[1]),
        "zoom": clampi(int(parts[2]), 1, 6),
        "rot": 0,
        "name": "",
    }
    if parts.size() >= 4 and parts[3].is_valid_int():
        shot.rot = posmod(int(parts[3]), 4)
    if parts.size() == 5:
        shot.name = parts[4]
    elif parts.size() == 4 and not parts[3].is_valid_int():
        shot.name = parts[3]
    if shot.name == "":
        shot.name = "shot_%d_%d_z%d_r%d" % [shot.tx, shot.tz, shot.zoom, shot.rot]
    return shot

# Points the isometric camera at city tile (tx, tz) at the given zoom/rotation.
# _rotate_step() permutes the rig origin, so rotate first and set the origin
# after; _zoom_step(0) re-applies the ortho size, view basis and the S3D
# zoom/rotation variants without changing the zoom level.
func _aim(city : Node, cam : Node, tx : float, tz : float, zoom : int, rot : int):
    while cam.rotated != posmod(rot, 4):
        cam._rotate_step(1)
    var target = city.get_node("Node3D").global_transform * Vector3(tx, 0.0, tz)
    cam.zoom = zoom
    cam.transform.origin = Vector3(target.x, cam.transform.origin.y, target.z)
    cam._zoom_step(0)

func _capture(path : String):
    # Let a few frames render so meshes/textures are on screen.
    for i in range(6):
        await get_tree().process_frame
    await RenderingServer.frame_post_draw
    var img = get_viewport().get_texture().get_image()
    img.save_png(path)
    print("saved %s" % path)
