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

# A city's drivable tiles should nearly all hang together. Fragmentation is the
# first visible symptom of boundaries failing to merge, and it shows up here
# long before anything looks wrong on screen.
const MIN_LARGEST_COMPONENT : float = 0.90

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

    return _check_graph(city, model) and ok

# Checks the graph derived from the model. The structural assertions are cheap
# and catch the bookkeeping mistakes that are otherwise invisible: an arc
# pointing at a node that no longer exists still renders fine.
func _check_graph(city, model) -> bool:
    var graph = city.network_graph
    if graph == null:
        if model.size() == 0:
            return true
        push_error("model has tiles but no graph was built")
        return false

    print("\n--- network graph checks ---")
    var ok := true
    print("  info  %d arcs over %d nodes, classes %s"
        % [graph.arc_count(), graph.node_count(), graph.class_histogram()])

    if model.size() == 0:
        print("  note  empty network, nothing to check")
        return true

    var problems = graph.validate()
    if problems.is_empty():
        print("  ok    graph structurally sound")
    else:
        for problem in problems.slice(0, 8):
            push_error("graph: %s" % problem)
        if problems.size() > 8:
            push_error("graph: ... and %d more" % (problems.size() - 8))
        ok = false

    # Roads and streets carry cars; rail does not. If the class tagging were
    # lost, every network would look alike and routing would send cars down
    # railway lines.
    var hist = graph.class_histogram()
    if hist.get("Car", 0) > 0 and hist.get("Sim", 0) > 0:
        print("  ok    car and pedestrian arcs both present")
    else:
        push_error("expected both Car and Sim arcs, got %s" % hist)
        ok = false

    # One-sided portals are normal and numerous: dead ends, the map border, and
    # lanes whose neighbouring piece simply has no matching lane -- a sidewalk
    # running down one side of a street, a turn pocket that stops. What is NOT
    # normal is the stitch leaving a pairing on the table, so assert on that
    # rather than on a raw count. `missed_pairable` is how many one-sided
    # portals had a still-one-sided complement within tolerance that the stitch
    # failed to take.
    var dangle = graph.dangling_report()
    var diag = graph.stranded_diagnosis()
    print("  info  %d one-sided portals: %d at dead ends, %d facing an occupied neighbour %s"
        % [dangle["total"], dangle["dead_end"], dangle["stranded"], diag["by_class"]])
    if diag["missed_pairable"] == 0:
        print("  ok    stitch took every available pairing (median gap to the nearest already-claimed lane %.2f m)"
            % diag["gap_median"])
    else:
        push_error("stitch left %d pairable portals unmatched -- %s"
            % [diag["missed_pairable"], diag])
        ok = false

    # A city's road network should be essentially one connected thing. If
    # boundaries stopped merging this fragments long before anything else
    # visibly breaks.
    #
    # Avenues are the known exception and are not yet counted against us. An
    # avenue is one network two tiles wide, and its two carriageways exchange
    # traffic across the shared median (RUL edge code 4) rather than through
    # per-tile paths -- SC4's avenue/road intersection piece 0x04005500 emits
    # only the lanes ARRIVING at the junction, with nothing departing into the
    # avenue. Until median pairing is modelled, a city with avenues genuinely
    # does fragment here. Rush Hour Tutorial (43 avenue tiles) drops to ~59%,
    # while avenue-free cities sit at 96-99%.
    var sizes = graph.component_cell_sizes(SC4PathSubfile.CLASS_CAR)
    var avenue_cells := 0
    for cell in model.tiles.keys():
        if model.is_multi_tile_network(model.tiles[cell]):
            avenue_cells += 1
    if sizes.is_empty():
        push_error("no car-class components at all")
        ok = false
    else:
        var car_cells := 0
        for size in sizes:
            car_cells += size
        var share : float = float(sizes[0]) / float(max(1, car_cells))
        var summary := "largest car component covers %d of %d drivable tiles (%.1f%%), %d components" \
            % [sizes[0], car_cells, share * 100.0, sizes.size()]
        if avenue_cells > 0:
            print("  note  %s -- %d two-tile (avenue) tiles present, median pairing not modelled yet"
                % [summary, avenue_cells])
        elif share >= MIN_LARGEST_COMPONENT:
            print("  ok    %s" % summary)
        else:
            push_error("%s -- the network is fragmenting" % summary)
            ok = false

    ok = _check_rail_purity(model, graph) and ok
    ok = _check_incremental(city, model, graph) and ok
    return ok

# Rail-only tiles must carry Train arcs and no Car arcs. If the class tag were
# dropped somewhere every network would look alike, and routing would happily
# send commuters down a railway line -- a failure that renders perfectly.
const NETWORK_RAIL : int = 1

func _check_rail_purity(model, graph) -> bool:
    var rail_cells := 0
    var with_train := 0
    var with_cars : Array = []
    for cell in model.tiles.keys():
        var tile = model.tiles[cell]
        # Skip level crossings: those tiles legitimately carry both.
        if tile.network_types != [NETWORK_RAIL]:
            continue
        rail_cells += 1
        var saw_train := false
        for idx in graph.arcs_by_cell.get(cell, []):
            var arc = graph.arcs[idx]
            if arc == null:
                continue
            if arc.transport_class == SC4PathSubfile.CLASS_TRAIN:
                saw_train = true
            elif arc.transport_class == SC4PathSubfile.CLASS_CAR:
                with_cars.append(cell)
        if saw_train:
            with_train += 1
    if rail_cells == 0:
        print("  note  no rail-only tiles in this city")
        return true
    if not with_cars.is_empty():
        push_error("%d rail-only tiles carry Car arcs, e.g. %s"
            % [with_cars.size(), with_cars.slice(0, 3)])
        return false
    print("  ok    %d of %d rail-only tiles carry Train arcs, none carry Car"
        % [with_train, rail_cells])
    return true

# The single most valuable check here: an incremental update after an edit must
# land on exactly the state a full rebuild would produce. Node and arc counts
# alone pass while one side of a boundary is stale, so compare the fingerprint,
# which folds in every arc's endpoints.
func _check_incremental(city, model, graph) -> bool:
    var before : int = graph.fingerprint()
    var before_arcs : int = graph.arc_count()
    var before_nodes : int = graph.node_count()

    # Pick a real road tile with neighbours, so removing it actually disturbs
    # something, and prefer one in the middle of a run.
    var victim = _pick_victim(model)
    if victim == null:
        print("  note  no suitable tile to test removal against")
        return true

    var removed = model.remove([victim])
    var after_remove : int = graph.fingerprint()
    if after_remove == before:
        push_error("removing tile %s left the graph fingerprint unchanged" % victim)
        return false
    print("  ok    removing %s changed the graph (%d cells dirtied)" % [victim, removed.size()])

    # Removal must be reflected in a full rebuild the same way.
    var incremental_after_remove : int = graph.fingerprint()
    graph.rebuild()
    if graph.fingerprint() != incremental_after_remove:
        push_error("after removal, incremental graph disagrees with a full rebuild")
        model.undo()
        return false
    print("  ok    incremental removal matches a full rebuild")

    # Put it back and confirm we land exactly where we started.
    model.undo()
    var restored : int = graph.fingerprint()
    var ok := true
    if restored != before:
        push_error("undo did not restore the graph: fingerprint %d vs %d" % [restored, before])
        ok = false
    elif graph.arc_count() != before_arcs or graph.node_count() != before_nodes:
        push_error("undo restored the fingerprint but not the counts: %d/%d vs %d/%d"
            % [graph.arc_count(), graph.node_count(), before_arcs, before_nodes])
        ok = false
    else:
        print("  ok    undo restored the graph exactly (%d arcs, %d nodes)"
            % [before_arcs, before_nodes])
    return ok

# A tile with two opposite neighbours, i.e. one in the middle of a run, so
# removing it is a real topology change rather than trimming a dead end.
func _pick_victim(model):
    var best = null
    for cell in model.tiles.keys():
        var tile = model.tiles[cell]
        if tile.connected_sides().size() != 2:
            continue
        var neighbours = model.occupied_neighbours(cell)
        if neighbours.size() < 2:
            continue
        if best == null or (cell.x + cell.y) < (best.x + best.y):
            best = cell
    return best
