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
#
# Bare keywords, in any position after the city name:
#   pipes     reveal the underground water pipes
#   graph     draw the transport graph over the city (vehicle lanes)
#   walking   as graph, plus the pedestrian lanes
#   hold      aim at the first shot and STAY OPEN instead of capturing/quitting
#   draw:x1,z1,x2,z2   lay a road through the build tool before shooting
#   del:x1,z1,x2,z2    bulldoze that box before shooting
#
# "hold" turns the harness into a viewer: it does the same load, parks the iso
# camera on the first shot spec and then hands the window to whoever is sitting
# in front of it -- normal camera keys, the build tool, G/H/F all work. Nothing
# is written and the scene never calls quit(), so <out_dir> is meaningless and
# "hold" may simply take its place as the first argument:
#   godot --path . --windowed --resolution 1600x900 res://tools/ScreenshotCity.tscn \
#       -- hold "Timbuktu" "Big City Tutorial" graph 49,67,6

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
    var user_args : Array = Array(OS.get_cmdline_user_args())
    if user_args.is_empty():
        push_error("Usage: ... res://tools/ScreenshotCity.tscn -- <out_dir>|hold [<region> <city>]")
        get_tree().quit(1)
        return
    # In hold mode nothing is written, so the leading <out_dir> is redundant and
    # "hold" is allowed to stand in for it. Blanking it here rather than
    # shifting the array keeps region/city at the fixed indices 1 and 2.
    var hold : bool = user_args.has("hold")
    if hold and user_args[0] == "hold":
        user_args[0] = ""
    var out_dir = user_args[0]
    var region = DEFAULT_REGION
    var city_name = DEFAULT_CITY
    var shots : Array = []
    var show_pipes = false
    var show_graph = false
    var show_walking = false
    var edits : Array = []
    if user_args.size() >= 3:
        region = user_args[1]
        city_name = user_args[2]
        for i in range(3, user_args.size()):
            if user_args[i] == "pipes":
                show_pipes = true
                continue
            # "graph" draws the transport graph over the city; "walking" adds
            # the pedestrian lanes, which are off by default.
            if user_args[i] == "graph":
                show_graph = true
                continue
            if user_args[i] == "walking":
                show_graph = true
                show_walking = true
                continue
            # Already picked up before the city name was parsed; swallow it here
            # so it is not mistaken for a shot spec.
            if user_args[i] == "hold":
                continue
            # "draw:x1,z1,x2,z2" lays a road before the shot; "del:x1,z1,x2,z2"
            # bulldozes a box. Lets the visual harness exercise the build tool,
            # which otherwise needs a mouse.
            if user_args[i].begins_with("draw:") or user_args[i].begins_with("del:"):
                edits.append(user_args[i])
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
    for edit in edits:
        _apply_edit(city, edit)
    if show_graph:
        if show_walking:
            city.toggle_graph_debug_pedestrians()
        city.set_graph_debug_visible(true)
        print("Graph overlay: %s" % city.network_debug.stats())

    var cam = city.get_node("CameraHandler")
    var half = city.size_w * 64 / 2.0    # world units are tiles

    # Viewer mode: park the camera and return without quitting, leaving the
    # scene tree running so the window stays live and takes input as usual.
    if hold:
        # No shot spec means the same default framing as a no-shot capture run:
        # the middle of the map, close enough to make out individual lots.
        var view = shots[0] if not shots.is_empty() else \
            {"tx": half, "tz": half, "zoom": 4, "rot": cam.rotated}
        if shots.size() > 1:
            print("hold: showing the first of %d shots, ignoring the rest" % shots.size())
        _aim(city, cam, view.tx, view.tz, view.zoom, view.rot)
        print("HOLDING at tile (%d, %d) zoom %d -- close the window to quit"
            % [view.tx, view.tz, view.zoom])
        return

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

# Applies one "draw:x1,z1,x2,z2" or "del:x1,z1,x2,z2" through the build tool.
func _apply_edit(city, spec : String) -> void:
    var tool = city.network_tool
    if tool == null:
        push_error("no build tool to apply %s" % spec)
        return
    var parts = spec.split(":")
    var nums = parts[1].split(",")
    if nums.size() != 4:
        push_error("Bad edit %s -- want draw:x1,z1,x2,z2" % spec)
        return
    var from := Vector2i(int(nums[0]), int(nums[1]))
    var to := Vector2i(int(nums[2]), int(nums[3]))
    var changed : Array
    if parts[0] == "draw":
        changed = tool.draw_line(from, to, "Road")
    else:
        changed = tool.bulldoze_box(from, to)
    print("%s -> %d cells changed" % [spec, changed.size()])

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
