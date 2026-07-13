extends Node
# TEMPORARY: loads the full City scene headlessly to catch runtime crashes. Deleted after use.

var dat_files = ["SimCity_1.dat", "SimCity_2.dat", "SimCity_3.dat",
                 "SimCity_4.dat", "SimCity_5.dat", "EP1.dat"]

func _ready():
    var config = INI.new("user://config.ini")
    Core.game_dir = config.sections["paths"]["sc4_files"]
    for f in dat_files:
        Core.add_dbpf(DBPF.new(Core.game_dir + "/" + f))
    var save_path = Core.game_dir + "/Regions/Timbuktu/City - Big City Tutorial.sc4"
    Boot.current_city = DBPF.new(save_path)
    Boot.current_city_name = "Big City Tutorial"
    Boot.current_city_path = save_path
    Boot.current_region_name = "Timbuktu"
    Log.info("CITYTEST instantiating City scene...")
    var city = load("res://CityView/CityScene/City.tscn").instantiate()
    add_child(city)
    await get_tree().process_frame
    await get_tree().process_frame
    var b = city.get_node_or_null("Node3D/Buildings")
    if b:
        Log.info("CITYTEST Buildings node children=%d" % b.get_child_count())
    else:
        Log.info("CITYTEST no Buildings node found")
    Log.info("CITYTEST DONE")
    get_tree().quit()
