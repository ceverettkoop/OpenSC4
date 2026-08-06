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
    if not _check_network(city):
        push_error("NETWORK CHECKS FAILED")
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

# Checks the tile model against the save it was built from. These are the
# invariants the whole network graph rests on, so they are assertions rather
# than log lines: if the rotation convention or the piece linkage ever breaks,
# the city still renders and only these numbers move.
#
# Both shipped saves score 100% piece coverage and 100% edge agreement once
# avenues are set aside -- they are one network two tiles wide, so a single
# tile's paths and its own edge codes describe different things. The floor sits
# just under 100% rather than at it so a single odd tile in some other city
# reports rather than fails the run.
const MIN_EDGE_AGREEMENT : float = 0.99

func _check_network(city) -> bool:
    print("\n--- network model checks ---")
    var model = city.network_model
    if model == null:
        # A city with no roads at all is legitimate; nothing to check.
        if city.save_network_tiles.is_empty():
            print("  city has no network subfile, skipping")
            return true
        push_error("network subfile present but no model was built")
        return false

    var ok := true
    var present := 0
    for tile in city.save_network_tiles:
        if tile.is_present():
            present += 1
    if model.size() == present:
        print("  ok    model holds every present save tile: %d" % present)
    else:
        push_error("model has %d tiles, save has %d present" % [model.size(), present])
        ok = false

    # Only tiles that connect to something can contribute an arc, so only those
    # need a path. Getting Started Tutorial's entire network is a single orphan
    # street tile with no connections at all.
    var unresolved = model.unresolved_pieces()
    if unresolved["connected"].is_empty():
        print("  ok    every connected piece resolved to an SC4Path")
    else:
        push_error("connected pieces with no SC4Path: %s" % unresolved["connected"])
        ok = false
    if not unresolved["inert"].is_empty():
        print("  note  %d unconnected piece(s) with no path: %s"
            % [unresolved["inert"].size(), unresolved["inert"]])

    var orient = model.orientation_report()
    if orient["checked"] == 0:
        # Nothing comparable: every tile was an avenue, or had no path at all.
        print("  note  no tiles to check edge agreement against")
    else:
        var rate : float = float(orient["agreed"]) / float(orient["checked"])
        if rate >= MIN_EDGE_AGREEMENT:
            print("  ok    path/save edge agreement: %.1f%% of %d tiles (%d avenues deferred)"
                % [rate * 100.0, orient["checked"], orient["deferred"]])
        else:
            push_error("path/save edge agreement %.1f%% is below the %.0f%% floor"
                % [rate * 100.0, MIN_EDGE_AGREEMENT * 100.0])
            ok = false

    # Every tile the model holds must sit inside the map, or a coordinate
    # convention is inverted somewhere.
    var tiles_w = city.size_w * 64
    var tiles_h = city.size_h * 64
    var out_of_bounds := 0
    for cell in model.tiles.keys():
        if cell.x < 0 or cell.y < 0 or cell.x >= tiles_w or cell.y >= tiles_h:
            out_of_bounds += 1
    if out_of_bounds == 0:
        print("  ok    all cells within the %dx%d map" % [tiles_w, tiles_h])
    else:
        push_error("%d cells fall outside the map" % out_of_bounds)
        ok = false

    return ok
