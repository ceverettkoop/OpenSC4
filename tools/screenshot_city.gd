extends Node

# Windowed variant of the HeadlessCity harness: loads the DATs and a city save
# exactly like tools/headless_city.gd, renders a few frames, and saves viewport
# screenshots for visual verification (building placement etc.), then quits.
#
# Run (needs a display; NOT --headless):
#   godot --path . --resolution 1600x900 res://tools/ScreenshotCity.tscn -- <out_dir> ["<region>" "<city name>"]
#
# Writes <out_dir>/city_zoom1.png (whole map) and <out_dir>/city_zoom4.png
# (closer view centred on the map).

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
    if user_args.size() >= 3:
        region = user_args[1]
        city_name = user_args[2]

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

    await _capture("%s/city_zoom1.png" % out_dir)

    # Closer pass: move the iso camera to the map centre at zoom 4 so building
    # clusters/alignment are inspectable.
    var cam = city.get_node("CameraHandler")
    var half = city.size_w * 64 / 2.0    # world units are tiles
    # Map centre in world space (Node3D carries the view rotation).
    var center = city.get_node("Node3D").global_transform * Vector3(half, 0, half)
    cam.zoom = 4
    cam.transform.origin = Vector3(center.x, cam.transform.origin.y, center.z)
    cam._zoom_step(0)    # re-applies ortho size + view + building variants
    await _capture("%s/city_zoom4.png" % out_dir)

    print("SCREENSHOTS DONE")
    get_tree().quit()

func _capture(path : String):
    # Let a few frames render so meshes/textures are on screen.
    for i in range(6):
        await get_tree().process_frame
    await RenderingServer.frame_post_draw
    var img = get_viewport().get_texture().get_image()
    img.save_png(path)
    print("saved %s" % path)
