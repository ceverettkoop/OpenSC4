extends Node

# Headless city-load harness for development / CI-style checks.
#
# Boots the asset pipeline without any UI: loads the game DATs the way
# BootScreen does, opens a city save the way RegionCityView does, instantiates
# City.tscn (terrain + building build runs in _ready), then sweeps
# set_building_view through every iso zoom/rotation and the free-orbit
# rotations so every model-variant code path executes. Any SCRIPT ERROR in the
# output is a real bug; a clean run ends with "SWEEP COMPLETE".
#
# Run as a scene (NOT with -s: --script main loops can't compile scripts that
# reference autoload singletons like Core/Log):
#   godot --headless --path . res://tools/HeadlessCity.tscn
#   godot --headless --path . res://tools/HeadlessCity.tscn -- "<region>" "<city name>"
# e.g.
#   godot --headless --path . res://tools/HeadlessCity.tscn -- Berlin Konradshohe

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
    var region = DEFAULT_REGION
    var city_name = DEFAULT_CITY
    var user_args = OS.get_cmdline_user_args()
    if user_args.size() >= 2:
        region = user_args[0]
        city_name = user_args[1]

    if Core.game_dir == null:
        var config = INI.new("user://config.ini")
        if config.sections.has("paths"):
            Core.game_dir = config.sections["paths"]["sc4_files"]
        else:
            Core.game_dir = ProjectSettings.globalize_path("res://")
    print("game_dir: %s" % Core.game_dir)

    for dat_file in dat_files:
        var dbpf = DBPF.new(Core.game_dir + "/" + dat_file)
        Core.add_dbpf(dbpf)
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
    print("Loading city: %s" % city_path)

    var city = load("res://CityView/CityScene/City.tscn").instantiate()
    add_child(city)
    if not city.has_method("set_building_view"):
        # City.gd failed to compile/attach; a runtime error mid-sweep would
        # abort _ready before quit() and leave the process hanging.
        push_error("City script not attached (compile error?) -- aborting")
        get_tree().quit(1)
        return
    print("City ready, sweeping building views")
    for zoom in range(1, 7):
        for rot in range(4):
            print("iso zoom=%d rotated=%d" % [zoom, rot])
            city.set_building_view(zoom, rot)
    for r in range(4):
        print("free rot=%d" % r)
        city.set_building_view(3, 2, r)
    print("SWEEP COMPLETE")
    get_tree().quit()
