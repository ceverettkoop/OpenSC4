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
    # The share of the largest component is reported but not asserted on,
    # because a city can legitimately hold more than one road system: Rush Hour
    # Tutorial's three components sit in disjoint corners of the map with no
    # tile touching between them, so its largest covers only 63%. What IS
    # asserted is that no two NEIGHBOURING drivable tiles landed in different
    # components -- a boundary the graph failed to cross is always a defect,
    # whatever the city's layout.
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
        print("  info  largest car component covers %d of %d drivable tiles (%.1f%%), %d components, %d avenue tiles"
            % [sizes[0], car_cells, share * 100.0, sizes.size(), avenue_cells])
        var split = graph.disconnected_adjacencies(SC4PathSubfile.CLASS_CAR)
        if split.is_empty():
            print("  ok    every pair of neighbouring drivable tiles is mutually reachable")
        else:
            push_error("%d neighbouring tile pairs are in different car components, e.g. %s"
                % [split.size(), split.slice(0, 5)])
            ok = false
        if share < MIN_LARGEST_COMPONENT and sizes.size() > 1:
            print("  note  %d separate road systems -- check they are meant to be separate" % sizes.size())

    ok = _check_rail_purity(model, graph) and ok
    ok = _check_against_simulation(city, model, graph) and ok
    ok = _check_data_views(city) and ok
    ok = _check_incremental(city, model, graph) and ok
    ok = _check_tool(city, model, graph) and ok
    ok = _check_crossing(city, model, graph) and ok
    ok = _check_lot_bulldoze(city, model) and ok
    ok = _check_ground_layer(city, model) and ok
    ok = _check_data_view_live(city) and ok
    ok = _check_simulation(city) and ok
    return ok

# Drawing a road over a zoned building, and bulldozing lots directly.
#
# A lot's visuals are scattered over five subfiles with nothing linking them
# back to the lot, so "remove this lot" has to take all of them at once or the
# building stays standing on a road, or its lawn does, or its foundations do.
# These check each of those independently rather than trusting one of them to
# imply the rest.
func _check_lot_bulldoze(city, model) -> bool:
    var tool = city.network_tool
    var lots = city.lot_model
    if tool == null or lots == null:
        print("  note  no build tool or no lot subfile")
        return true

    print("\n--- lot bulldozing ---")
    var ok := true
    var site = _find_clear_lot(city, model, true)
    if site == null:
        print("  note  no growable lot on network-free ground to draw over")
    else:
        ok = _check_raze_by_road(city, lots, tool, site) and ok

    # A fresh lot each time -- _find_clear_lot skips the ones already gone,
    # because edits are permanent and nothing puts the last one back.
    var box_site = _find_clear_lot(city, model, true)
    if box_site == null:
        print("  note  no second growable lot to bulldoze directly")
    else:
        ok = _check_bulldoze_lot(city, lots, tool, box_site) and ok

    # A plopped lot is not growable and a road must not eat it.
    var plopped = _find_clear_lot(city, model, false)
    if plopped == null:
        print("  note  no plopped lot on network-free ground")
    else:
        var cell : Vector2i = plopped["cells"][0]
        tool.draw_line(Vector2i(plopped["min_x"], cell.y),
            Vector2i(plopped["max_x"], cell.y), "Road")
        # Only this lot's own survival is the claim. The road stays inside its
        # rect, but a plopped lot can still border growable ones, and those are
        # fair game.
        if lots.has_lot(cell):
            print("  ok    a road drawn over the plopped lot at %s left it standing (zone %d)"
                % [cell, plopped["lot"].zone_type])
        else:
            push_error("a road razed the PLOPPED lot at %s (zone %d)"
                % [cell, plopped["lot"].zone_type])
            ok = false
    return ok

func _check_raze_by_road(city, lots, tool, site) -> bool:
    var ok := true
    var lot = site["lot"]
    var cells : Array = site["cells"]
    # The cell carrying the most geometry, so the assertions have something to
    # measure rather than passing vacuously on an empty corner of the lot.
    var busiest : Vector2i = cells[0]
    for cell in cells:
        if city.occupant_nodes.get(cell, []).size() > city.occupant_nodes.get(busiest, []).size():
            busiest = cell
    var nodes_before : int = city.occupant_nodes.get(busiest, []).size()
    var lots_before : int = lots.size()
    var family : int = _lot_texture_family_at(city, busiest)
    var tex_before : int = _mesh_vertex_count(city.lot_texture_nodes.get(family))

    # Along one row of the lot and no further. Running a tile past either end
    # would clip whatever is next door, and then "how many lots went" stops
    # being a statement about this one.
    var row : int = cells[0].y
    var run : Array = []
    for x in range(site["min_x"], site["max_x"] + 1):
        run.append(Vector2i(x, row))
    var expected : int = lots.lots_over(run, true).size()
    tool.draw_line(run[0], run[run.size() - 1], "Road")

    if not lots.has_lot(busiest):
        print("  ok    a road drawn across the growable lot at %s razed it (zone %d, %d tiles)"
            % [busiest, lot.zone_type, cells.size()])
    else:
        push_error("a road drawn across the growable lot at %s left it in the model" % busiest)
        ok = false
    if lots.size() != lots_before - expected:
        push_error("razing %d lot(s) took the count from %d to %d"
            % [expected, lots_before, lots.size()])
        ok = false

    # The whole lot goes, not just the tiles the road actually crossed.
    var still_there : Array = []
    for cell in cells:
        if not city.lot_removed_cells.has(cell):
            still_there.append(cell)
    if still_there.is_empty():
        print("  ok    all %d of the lot's tiles were withdrawn, not just the crossed row"
            % cells.size())
    else:
        push_error("%d of the lot's tiles were left drawing: %s"
            % [still_there.size(), still_there.slice(0, 5)])
        ok = false

    if nodes_before > 0:
        var nodes_after : int = city.occupant_nodes.get(busiest, []).size()
        if nodes_after == 0:
            print("  ok    its %d occupant node(s) at %s were freed" % [nodes_before, busiest])
        else:
            push_error("%d occupant node(s) still standing at %s" % [nodes_after, busiest])
            ok = false
    else:
        print("  note  no occupant nodes on the razed lot to check")

    if family != 0 and tex_before > 0:
        var tex_after : int = _mesh_vertex_count(city.lot_texture_nodes.get(family))
        if tex_after < tex_before:
            print("  ok    its ground texture shrank (%d -> %d vertices)" % [tex_before, tex_after])
        else:
            push_error("the razed lot's ground texture is unchanged (%d vertices)" % tex_after)
            ok = false

    return ok

# The bulldozer takes a lot on its own, with no network tile in the box. Needs
# its own lot: the road check above razed its one for good.
func _check_bulldoze_lot(city, lots, tool, site) -> bool:
    var ok := true
    var cells : Array = site["cells"]
    var cell : Vector2i = cells[0]
    var razed = tool.bulldoze(cells)
    if lots.has_lot(cell):
        push_error("bulldozing %s left the lot in the model" % cells.slice(0, 3))
        ok = false
    elif not razed.is_empty():
        push_error("bulldozing a lot on bare ground reported %d network cells" % razed.size())
        ok = false
    else:
        print("  ok    the bulldozer removed the lot at %s with no network tile in the box" % cell)
    return ok

# The lot-texture family covering `cell`, or 0.
func _lot_texture_family_at(city, cell : Vector2i) -> int:
    for iid in city.lot_texture_tiles.keys():
        for t in city.lot_texture_tiles[iid]:
            if t.x == cell.x and t.z == cell.y:
                return iid
    return 0

# A lot whose whole rect is free of network tiles, so drawing across it is a
# clean test rather than a road merge. `growable` picks which kind.
func _find_clear_lot(city, model, growable : bool):
    for lot in city.lot_model.lots:
        if LotModel.is_growable(lot) != growable:
            continue
        if not city.lot_model.has_lot(Vector2i(lot.min_x, lot.min_z)):
            continue
        var cells := LotModel.cells_of(lot)
        var clear := true
        for cell in cells:
            # The lot must own every tile it claims -- overlapping rects would
            # make "the whole lot went" ambiguous.
            if model.has_tile(cell) or city.lot_model.lot_at(cell) != lot:
                clear = false
                break
        if not clear:
            continue
        # Room either side for the road to start and end on.
        if lot.min_x < 2 or lot.max_x > city.size_w * 64 - 3:
            continue
        return {"lot": lot, "cells": cells, "min_x": lot.min_x, "max_x": lot.max_x}
    return null

# Drives the build tool the way a user would, without a mouse, and checks the
# graph follows. This is the end-to-end assertion for the whole feature: a road
# drawn on empty ground has to become connected arcs, and bulldozing its middle
# has to split it.
#
# Every edit here is permanent, so the checks that follow this one capture their
# own before-state rather than assuming the city is as the save left it.
const DRAWN_RUN : int = 8

func _check_tool(city, model, graph) -> bool:
    var tool = city.network_tool
    if tool == null:
        print("  note  no build tool in this scene")
        return true

    print("\n--- build tool checks ---")
    var start = _find_clear_run(model, city.size_w * 64, city.size_h * 64)
    if start == null:
        print("  note  no clear ground to draw on")
        return true

    var before_tiles : int = model.size()
    var before_arcs : int = graph.arc_count()

    var finish := Vector2i(start.x + DRAWN_RUN - 1, start.y)
    tool.draw_line(start, finish, "Road")

    var drawn : Array = []
    for x in range(start.x, finish.x + 1):
        var cell := Vector2i(x, start.y)
        if model.has_tile(cell):
            drawn.append(cell)
    var ok := true
    if drawn.size() == DRAWN_RUN:
        print("  ok    drew %d road tiles from %s to %s" % [drawn.size(), start, finish])
    else:
        push_error("drew %d of %d tiles from %s" % [drawn.size(), DRAWN_RUN, start])
        ok = false
    if model.size() != before_tiles + drawn.size():
        push_error("model went from %d to %d tiles after drawing %d"
            % [before_tiles, model.size(), drawn.size()])
        ok = false

    # The drawn tiles must actually carry arcs, or the road exists visually and
    # not in the graph -- exactly the split this whole change removes.
    var arcs_on_drawn := 0
    for cell in drawn:
        if not graph.arcs_by_cell.get(cell, []).is_empty():
            arcs_on_drawn += 1
    if arcs_on_drawn == drawn.size():
        print("  ok    every drawn tile carries arcs (%d new arcs in total)"
            % [graph.arc_count() - before_arcs])
    else:
        push_error("only %d of %d drawn tiles carry arcs" % [arcs_on_drawn, drawn.size()])
        ok = false

    var problems = graph.validate()
    if not problems.is_empty():
        push_error("graph unsound after drawing: %s" % problems.slice(0, 3))
        ok = false

    # Bulldozing the middle of the run must break it in two.
    if drawn.size() >= 3:
        var middle : Vector2i = drawn[drawn.size() / 2]
        var before_components : int = _components_over(graph, drawn)
        tool.bulldoze([middle])
        var after_components : int = _components_over(graph, drawn)
        if model.has_tile(middle):
            push_error("bulldozing %s left the tile in the model" % middle)
            ok = false
        elif not graph.arcs_by_cell.get(middle, []).is_empty():
            push_error("bulldozing %s left its arcs in the graph" % middle)
            ok = false
        elif after_components > before_components:
            print("  ok    bulldozing %s split the run (%d -> %d components)"
                % [middle, before_components, after_components])
        else:
            push_error("bulldozing %s did not split the run (%d -> %d components)"
                % [middle, before_components, after_components])
            ok = false

    ok = _check_save_tile_bulldoze(city, model, tool) and ok

    # The drawn road stays. Edits are permanent, so every check after this one
    # captures its own before-state rather than assuming a pristine city.
    var problems_after = graph.validate()
    if problems_after.is_empty():
        print("  ok    graph still sound after the draw and bulldoze sequence")
    else:
        push_error("graph unsound after the tool sequence: %s" % problems_after.slice(0, 3))
        ok = false
    return ok

# Dragging a road ACROSS a road that came from the save.
#
# _check_tool deliberately draws on clear ground so the counts stay predictable,
# which left this case untested: the drag solver reconciled a drag only against
# tiles the renderer had drawn itself, so crossing one of the save's roads laid a
# straight piece over the top of it. The road still LOOKED continuous either
# side of the new one, because the save's own quad was still being drawn
# underneath, while the model record that replaced it claimed two edges instead
# of four -- so the crossed road's arcs stopped at the intersection and traffic
# could no longer get through it.
#
# The assertion is the one that would have caught that: after the drag the
# crossing tile claims all four sides, carries arcs, and the four tiles around
# it are mutually reachable through it.
const CROSS_ARM : int = 3

func _check_crossing(city, model, graph) -> bool:
    var tool = city.network_tool
    if tool == null:
        return true

    print("\n--- crossing an existing road ---")
    var site = _find_crossable_road(model, city.size_w * 64, city.size_h * 64)
    if site == null:
        print("  note  no straight save road with clear ground either side")
        return true
    var cell : Vector2i = site["cell"]
    var axis : Vector2i = site["axis"]          # the drag runs along this
    var before_source : int = model.get_tile(cell).source

    var from : Vector2i = cell - axis * CROSS_ARM
    var to : Vector2i = cell + axis * CROSS_ARM
    tool.draw_line(from, to, "Road")

    var ok := true
    var tile = model.get_tile(cell)
    if tile == null:
        push_error("drawing across %s left no tile there" % cell)
        return false

    var sides : Array = tile.connected_sides()
    if sides.size() == 4:
        print("  ok    %s became a 4-way intersection (wnes %s, piece 0x%08x)"
            % [cell, tile.wnes, tile.piece_id])
    else:
        push_error("%s connects %s after being crossed -- wanted all four sides (wnes %s)"
            % [cell, sides, tile.wnes])
        ok = false

    # Arcs have to exist on the crossing tile in BOTH axes. Counting arcs is not
    # enough: a straight piece laid over the junction still carries the drag's
    # own two.
    var axes := {}
    for idx in graph.arcs_by_cell.get(cell, []):
        var arc = graph.arcs[idx]
        if arc == null or arc.transport_class != SC4PathSubfile.CLASS_CAR:
            continue
        var span : Vector3 = arc.polyline[arc.polyline.size() - 1] - arc.polyline[0]
        axes[absf(span.x) > absf(span.z)] = true
    if axes.size() == 2:
        print("  ok    the intersection carries car lanes on both axes")
    else:
        push_error("%s carries car lanes on %d axis/axes, wanted 2" % [cell, axes.size()])
        ok = false

    # The real test: everything around the junction hangs together through it.
    var arms : Array = [cell]
    for step in [axis, -axis, Vector2i(axis.y, axis.x), Vector2i(-axis.y, -axis.x)]:
        var neighbour : Vector2i = cell + step
        if model.has_tile(neighbour):
            arms.append(neighbour)
    # Cars specifically. The pedestrian lanes around a junction sit in several
    # components before the drag as well as after -- sidewalks are not one
    # network -- so counting every class together measures something that was
    # never 1 and says nothing about whether traffic gets through.
    var components : int = _components_over(graph, arms, SC4PathSubfile.CLASS_CAR)
    if components == 1:
        print("  ok    all %d tiles around the junction are mutually reachable by car" % arms.size())
    else:
        push_error("the junction's %d surrounding tiles fall into %d car components"
            % [arms.size(), components])
        ok = false

    # The save's own quad for the cell must stop drawing, or the old straight
    # road shows through the new intersection.
    if before_source == NetworkModel.SOURCE_SAVE:
        if city.network_removed_cells.has(cell):
            print("  ok    the save's quad for %s was withdrawn" % cell)
        else:
            push_error("the save still draws its own quad under the new intersection at %s" % cell)
            ok = false

    # The incremental graph must agree with a rebuild after the crossing, which
    # is what a round trip used to prove indirectly.
    var incremental : int = graph.fingerprint()
    graph.rebuild()
    if graph.fingerprint() == incremental:
        print("  ok    the crossed junction matches a full graph rebuild")
    else:
        push_error("after crossing %s, the incremental graph disagrees with a full rebuild" % cell)
        ok = false
    return ok

# A straight two-edge road tile whose perpendicular neighbours are clear for
# CROSS_ARM tiles either side, so a drag across it meets that road and nothing
# else. Returns {cell, axis} where axis is the direction the drag should run.
func _find_crossable_road(model, map_w : int, map_h : int):
    var road_type : int = NetworkSubfile.NETWORK_TYPE_NAMES.find("Road")
    for cell in model.tiles.keys():
        var tile = model.tiles[cell]
        if tile.network_type() != road_type or tile.crossings.size() != 1:
            continue
        var sides : Array = tile.connected_sides()
        if sides.size() != 2:
            continue
        # Opposite edges only: a corner piece would put the drag alongside the
        # road rather than across it.
        if NetworkModel.opposite(sides[0]) != sides[1]:
            continue
        var axis := Vector2i(NetworkModel.SIDE_DELTA[sides[0]].y, NetworkModel.SIDE_DELTA[sides[0]].x)
        var clear := true
        for step in range(1, CROSS_ARM + 1):
            for dir in [axis, -axis]:
                var probe : Vector2i = cell + dir * step
                if probe.x < 1 or probe.y < 1 or probe.x >= map_w - 1 or probe.y >= map_h - 1:
                    clear = false
                elif model.has_tile(probe):
                    clear = false
            if not clear:
                break
        if clear:
            return {"cell": cell, "axis": axis}
    return null

# Bulldozing a tile that came from the save is the awkward case: its quad lives
# inside a mesh batched by texture family, with no per-tile addressing, so the
# family has to be rebuilt. Removing it from the model and the graph while
# leaving it on screen would look like nothing happened.
func _check_save_tile_bulldoze(city, model, tool) -> bool:
    var victim = null
    for cell in model.tiles.keys():
        var tile = model.tiles[cell]
        if tile.source == NetworkModel.SOURCE_SAVE and city.network_family_nodes.has(tile.piece_id):
            victim = cell
            break
    if victim == null:
        print("  note  no save tile with a batched mesh to bulldoze")
        return true

    var family : int = model.tiles[victim].piece_id
    var node = city.network_family_nodes[family]
    var before : int = _mesh_vertex_count(node)
    tool.bulldoze([victim])
    var after : int = _mesh_vertex_count(node)
    var ok := true
    if model.has_tile(victim):
        push_error("bulldozing save tile %s left it in the model" % victim)
        ok = false
    elif after < before:
        print("  ok    bulldozing save tile %s shrank its batch (%d -> %d vertices)"
            % [victim, before, after])
    else:
        push_error("bulldozing save tile %s left its quad in the mesh (%d vertices, unchanged)"
            % [victim, after])
        ok = false
    return ok

# The ground ("sidewalk") layer under drawn roads.
#
# A network tile draws two quads: the piece on top and an opaque ground family
# underneath, showing through the 24-31% of the piece texture that is cleared.
# The save records that family per tile; a drawn tile has to derive it from the
# lots beside it (NetworkBaseTexture). The first check below is the one that
# matters -- it scores the derived rule against the save's own answer, so a
# change to the rule, to LotModel or to the lot-cell index shows up as a number
# rather than as a road that quietly loses its kerb.
#
# The floor is well under the rule's real accuracy on purpose. Measured over all
# eight populated saves the rule lands at 93.0%, but per city it ranges from
# 72.9% (Konradshohe, dense $$$ and heavy industry, where SC4's own kerb follows
# land value rather than the zoning next door) to 98.0% (Fulham) -- and the
# ceiling is not 100% for any adjacency rule, see NetworkBaseTexture. So this
# gate is not tuned to catch a percent of drift; it catches the rule being
# broken outright, which scores in the twenties.
const MIN_BASE_TEXTURE_AGREEMENT : float = 0.70

func _check_ground_layer(city, model) -> bool:
    var tool = city.network_tool
    var lots = city.lot_model
    var renderer = city.get_node("Node3D").get_node_or_null("NetworkRenderer")
    if tool == null or lots == null or renderer == null:
        print("  note  no build tool, lot model or renderer in this scene")
        return true

    print("\n--- network ground layer ---")
    var ok := true

    # 1. The derived rule against the save's own base_texture, over every save
    #    tile that still carries one. Tiles the earlier checks bulldozed are
    #    gone from the model, which is fine -- this scores what is left.
    var scored := 0
    var agreed := 0
    for cell in model.tiles.keys():
        var tile = model.get_tile(cell)
        if tile == null or tile.source != NetworkModel.SOURCE_SAVE:
            continue
        scored += 1
        if NetworkBaseTexture.pick(cell, lots) == tile.base_texture:
            agreed += 1
    if scored == 0:
        print("  note  no save tiles left to score the ground rule against")
    else:
        var rate : float = float(agreed) / float(scored)
        if rate >= MIN_BASE_TEXTURE_AGREEMENT:
            print("  ok    ground rule matches the save on %d of %d tiles (%.1f%%)"
                % [agreed, scored, rate * 100.0])
        else:
            push_error("ground rule matches the save on only %d of %d tiles (%.1f%%, floor %.0f%%)"
                % [agreed, scored, rate * 100.0, MIN_BASE_TEXTURE_AGREEMENT * 100.0])
            ok = false

    # 2. Open country gets no ground quad at all, and no geometry for one.
    #    _find_clear_run is not enough here: it only avoids existing network
    #    tiles, so it happily returns a run through a zoned district, where the
    #    drag razes the lots under it and the lots still standing either side
    #    correctly give the new road a kerb.
    var clear = _find_rural_run(model, lots, city.size_w * 64, city.size_h * 64)
    if clear == null:
        print("  note  no run of open country left to draw on")
    else:
        var before_verts : int = _mesh_vertex_count(renderer.base_meshinst)
        var clear_end := Vector2i(clear.x + DRAWN_RUN - 1, clear.y)
        tool.draw_line(clear, clear_end, "Road")
        var rural_bare := true
        for x in range(clear.x, clear_end.x + 1):
            var tile = model.get_tile(Vector2i(x, clear.y))
            if tile != null and tile.base_texture != NetworkBaseTexture.NONE:
                rural_bare = false
        if rural_bare and _mesh_vertex_count(renderer.base_meshinst) == before_verts:
            print("  ok    a road drawn in open country carries no ground quad")
        else:
            push_error("a road drawn away from every lot picked up a ground texture")
            ok = false

    # 3. A road drawn alongside a lot gets that lot's ground family, and the
    #    geometry to draw it. This is the visible half of "complete".
    var site = _find_cell_beside_lot(model, lots, city.size_w * 64, city.size_h * 64)
    if site == null:
        print("  note  no clear cell beside a lot to draw on")
        return ok
    var expected : int = NetworkBaseTexture.pick(site, lots)
    var verts_before : int = _mesh_vertex_count(renderer.base_meshinst)
    tool.draw_line(site, site, "Road")
    var placed = model.get_tile(site)
    if placed == null:
        push_error("drawing beside a lot at %s placed no tile" % site)
        return false
    if placed.base_texture != expected:
        push_error("tile beside a lot at %s got ground 0x%08X, expected 0x%08X"
            % [site, placed.base_texture, expected])
        ok = false
    elif expected == NetworkBaseTexture.NONE:
        push_error("cell %s was chosen as being beside a lot but derives no ground family" % site)
        ok = false
    else:
        var verts_after : int = _mesh_vertex_count(renderer.base_meshinst)
        if verts_after > verts_before:
            print("  ok    a road drawn beside a lot took ground 0x%08X and %d vertices of geometry"
                % [expected, verts_after - verts_before])
        else:
            push_error("tile at %s claims ground 0x%08X but the layer gained no geometry"
                % [site, expected])
            ok = false

    # 4. Bulldozing takes the ground quad with it. A ground quad left behind is
    #    a sidewalk floating on bare terrain -- and it is a separate mesh from
    #    the piece, so nothing else in the harness would notice.
    var verts_placed : int = _mesh_vertex_count(renderer.base_meshinst)
    tool.bulldoze([site])
    var verts_gone : int = _mesh_vertex_count(renderer.base_meshinst)
    if verts_gone < verts_placed:
        print("  ok    bulldozing took the ground quad with it (%d -> %d vertices)"
            % [verts_placed, verts_gone])
    else:
        push_error("bulldozing %s left its ground quad behind (%d -> %d vertices)"
            % [site, verts_placed, verts_gone])
        ok = false
    return ok

# A horizontal run of empty cells with no network tile AND no lot anywhere in
# the band the ground rule looks at, so a road drawn along it is genuinely in
# open country rather than in a district whose lots the drag just razed.
func _find_rural_run(model, lots, map_w : int, map_h : int):
    for z in range(4, map_h - 4):
        for x in range(4, map_w - DRAWN_RUN - 4):
            var clear := true
            for dx in range(-2, DRAWN_RUN + 2):
                for dz in range(-2, 3):
                    var cell := Vector2i(x + dx, z + dz)
                    if model.has_tile(cell) or lots.has_lot(cell):
                        clear = false
                        break
                if not clear:
                    break
            if clear:
                return Vector2i(x, z)
    return null

# A clear cell, with clear orthogonal neighbours, that has at least one lot in
# its 3x3 neighbourhood -- so a road drawn on it derives a ground family without
# the drag flattening the lot that gave it one.
func _find_cell_beside_lot(model, lots, map_w : int, map_h : int):
    for z in range(4, map_h - 4):
        for x in range(4, map_w - 4):
            var cell := Vector2i(x, z)
            if model.has_tile(cell) or lots.has_lot(cell):
                continue
            var clear := true
            for d in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
                if model.has_tile(cell + d):
                    clear = false
                    break
            if not clear:
                continue
            if NetworkBaseTexture.pick(cell, lots) != NetworkBaseTexture.NONE:
                return cell
    return null

func _mesh_vertex_count(node) -> int:
    if node == null or node.mesh == null or node.mesh.get_surface_count() == 0:
        return 0
    return node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()

# Connected components counted over just these cells, so a local split shows up
# without being drowned out by the rest of the city.
func _components_over(graph, cells : Array, transport_class : int = -1) -> int:
    var wanted := {}
    for cell in cells:
        wanted[cell] = true
    var adjacent := {}
    for arc in graph.arcs:
        if arc == null or not wanted.has(arc.cell):
            continue
        if transport_class >= 0 and arc.transport_class != transport_class:
            continue
        for pair in [[arc.from_node, arc.to_node], [arc.to_node, arc.from_node]]:
            if not adjacent.has(pair[0]):
                adjacent[pair[0]] = []
            adjacent[pair[0]].append(pair[1])
    var seen := {}
    var count := 0
    for start in adjacent.keys():
        if seen.has(start):
            continue
        count += 1
        var stack : Array = [start]
        seen[start] = true
        while not stack.is_empty():
            var current = stack.pop_back()
            for next in adjacent.get(current, []):
                if not seen.has(next):
                    seen[next] = true
                    stack.append(next)
    return count

# A horizontal run of empty cells with empty ground either side, so the drawn
# road cannot merge into an existing one and confuse the counts.
func _find_clear_run(model, map_w : int, map_h : int):
    for z in range(4, map_h - 4):
        for x in range(4, map_w - DRAWN_RUN - 4):
            var clear := true
            for dx in range(-1, DRAWN_RUN + 1):
                for dz in range(-1, 2):
                    if model.has_tile(Vector2i(x + dx, z + dz)):
                        clear = false
                        break
                if not clear:
                    break
            if clear:
                return Vector2i(x, z)
    return null

# Checks the model against SC4's own traffic simulation output, which the game
# saved per tile. This is the strongest check available: it compares our
# network against the shipped game's answer rather than against our own
# expectations, and it is sensitive to exactly the mistakes -- a transposed
# axis, a dropped tile -- that leave the city rendering perfectly.
const MIN_TRAFFIC_JACCARD : float = 0.95

func _check_against_simulation(city, model, graph) -> bool:
    var grids = city.load_sim_grids()
    var total = grids.get(SimGridSubfile.TRAFFIC_TOTAL)
    if total == null:
        print("  note  no traffic SimGrid in this save, skipping the ground-truth check")
        return true

    var map_tiles : int = city.size_w * 64
    var traffic_cells := {}
    for cell in total.nonzero_cells():
        traffic_cells[cell] = true
    var ours := {}
    for cell in model.tiles.keys():
        ours[cell] = true

    var intersection := 0
    for cell in traffic_cells.keys():
        if ours.has(cell):
            intersection += 1
    var union : int = traffic_cells.size() + ours.size() - intersection
    var jaccard : float = float(intersection) / float(max(1, union))

    var ok := true
    if jaccard >= MIN_TRAFFIC_JACCARD:
        print("  ok    traffic grid agrees with the model: %d of %d tiles, Jaccard %.3f"
            % [intersection, union, jaccard])
    else:
        push_error("traffic grid only overlaps the model at Jaccard %.3f (%d shared, %d union)"
            % [jaccard, intersection, union])
        ok = false

    # The car-traffic layer is near-zero on rail, so every tile it marks should
    # be somewhere a car can actually get to.
    var car = grids.get(SimGridSubfile.TRAFFIC_CAR)
    if car == null:
        return ok
    var drivable := {}
    for arc in graph.arcs:
        if arc != null and arc.transport_class == SC4PathSubfile.CLASS_CAR:
            drivable[arc.cell] = true
    var had_traffic := 0
    var missing : Array = []
    for cell in car.nonzero_cells():
        if not ours.has(cell):
            continue
        had_traffic += 1
        if not drivable.has(cell):
            missing.append(cell)
    if had_traffic == 0:
        return ok
    var covered : float = 1.0 - float(missing.size()) / float(had_traffic)
    if covered >= MIN_TRAFFIC_JACCARD:
        print("  ok    %.1f%% of tiles SC4 gave car traffic carry car arcs (%d of %d)"
            % [covered * 100.0, had_traffic - missing.size(), had_traffic])
    else:
        push_error("only %.1f%% of tiles SC4 gave car traffic carry car arcs; e.g. %s"
            % [covered * 100.0, missing.slice(0, 5)])
        ok = false
    return ok

# SimGrids and the data views built on them. Three layers of checks: every
# grid record of the save parses cleanly, the DataView catalogue reads SC4's
# own view exemplars out of the DATs, and decoding the occupant-code grid
# still reproduces each lot's wealth class -- which is how that grid was
# identified in the first place (single-valued crosstab over all 12 populated
# saves). If a refactor transposes an axis or misreads a header offset, the
# agreement collapses long before anything looks wrong on screen. Vacant
# cells (code 0 under a lot: abandonment) are excluded -- they carry no
# wealth to agree with.
const MIN_WEALTH_AGREEMENT : float = 0.95
const MIN_WEALTH_SAMPLES : int = 200

func _check_data_views(city) -> bool:
    print("\n--- sim grids and data views ---")
    var ok := true

    # 1. Parse health: every record accounted for, every grid well-formed.
    var model = city.sim_grids_model()
    if model.layout_failures > 0:
        push_error("%d SimGrid records failed header validation" % model.layout_failures)
        ok = false
    if model.size() == 0:
        print("  note  no SimGrid layers in this save, skipping")
        return ok
    var malformed := 0
    for data_id in model.grids.keys():
        var grid = model.grids[data_id]
        if grid.width != grid.height or grid.width <= 0 \
                or model.map_tiles % grid.width != 0 \
                or grid.values.size() != grid.width * grid.height:
            push_error("grid %08X is malformed: %dx%d, %d cells, map %d tiles"
                % [data_id, grid.width, grid.height, grid.values.size(), model.map_tiles])
            malformed += 1
    if malformed == 0:
        print("  ok    %d SimGrid layers parse cleanly" % model.size())
    else:
        ok = false

    # 2. The DataView catalogue reads SC4's own view definitions from the DATs.
    var catalogue = DataViewCatalogue.new()
    var n_views : int = catalogue.load_from_core()
    var land_view = catalogue.view_named("Land value")
    if land_view == null:
        push_error("catalogue has no 'Land value' view (%d views loaded)" % n_views)
        return false
    var opaque_stops := 0
    for stop in land_view.ramp:
        if stop["color"].a > 0.0:
            opaque_stops += 1
    if land_view.ramp.size() >= 2 and opaque_stops > 0 \
            and land_view.data_id == SimGridSubfile.OCCUPANT_CODE:
        print("  ok    catalogue: %d views, Land value ramp has %d stops"
            % [n_views, land_view.ramp.size()])
    else:
        push_error("Land value view is malformed: %d ramp stops, %d visible, dataId %08X"
            % [land_view.ramp.size(), opaque_stops, land_view.data_id])
        ok = false

    # 3. The identification gate: decoding the occupant-code grid must
    # reproduce each lot's wealth class.
    if not model.has(SimGridSubfile.OCCUPANT_CODE):
        print("  note  no occupant-code grid in this save, skipping the wealth check")
        return ok
    if city.lot_model == null:
        print("  note  no lots in this save, skipping the wealth check")
        return ok
    var sampled := 0
    var agreed := 0
    var mismatches : Array = []
    for cell in city.lot_model.by_cell.keys():
        var lot = city.lot_model.lot_at(cell)
        if lot == null:
            continue
        var code : int = int(model.value_at_tile(SimGridSubfile.OCCUPANT_CODE, cell.x, cell.y))
        if code == 0:
            continue    # vacant/abandoned under a zoned lot
        sampled += 1
        if SimGridSubfile.OCCUPANT_CODE_WEALTH.get(code, 0) == lot.zone_wealth:
            agreed += 1
        elif mismatches.size() < 5:
            mismatches.append("%s code %d wealth %d" % [cell, code, lot.zone_wealth])
    if sampled < MIN_WEALTH_SAMPLES:
        print("  note  only %d occupied lot tiles -- wealth check not meaningful, skipping" % sampled)
        return ok
    var agreement : float = float(agreed) / float(sampled)
    if agreement >= MIN_WEALTH_AGREEMENT:
        print("  ok    occupant-code grid reproduces lot wealth on %.1f%% of %d tiles"
            % [agreement * 100.0, sampled])
    else:
        push_error("occupant-code grid only reproduces lot wealth on %.1f%% of %d tiles (want >= %.0f%%); e.g. %s"
            % [agreement * 100.0, sampled, MIN_WEALTH_AGREEMENT * 100.0, mismatches])
        ok = false

    ok = _check_zone_grid(city, model) and ok
    ok = _check_flammability_grids(city, model) and ok
    return ok

# The zone-type grid (0x41800000) stores each tile's lot zone_type verbatim
# -- the crosstab is single-valued on every populated save, >= 99.6% of lot
# tiles agreeing (the stragglers are tiles two overlapping lot rects claim).
const MIN_ZONE_AGREEMENT : float = 0.99

func _check_zone_grid(city, model) -> bool:
    if not model.has(SimGridSubfile.ZONE_TYPE) or city.lot_model == null:
        print("  note  no zone-type grid or no lots, skipping the zone check")
        return true
    var agreed := 0
    var checked := 0
    for cell in city.lot_model.by_cell.keys():
        var lot = city.lot_model.lot_at(cell)
        if lot == null:
            continue
        checked += 1
        if int(model.value_at_tile(SimGridSubfile.ZONE_TYPE, cell.x, cell.y)) == lot.zone_type:
            agreed += 1
    if checked < MIN_WEALTH_SAMPLES:
        print("  note  only %d lot tiles -- zone-grid check not meaningful, skipping" % checked)
        return true
    var rate : float = float(agreed) / float(checked)
    if rate >= MIN_ZONE_AGREEMENT:
        print("  ok    zone-type grid matches lot zoning on %.1f%% of %d tiles" % [rate * 100.0, checked])
        return true
    push_error("zone-type grid matches lot zoning on only %.1f%% of %d tiles (floor %.0f%%)"
        % [rate * 100.0, checked, MIN_ZONE_AGREEMENT * 100.0])
    return false

# The flammability pair: FLAMMABILITY_BASE holds each building exemplar's
# "Flammability" property (0x29244DB5, inherited from the family cohort)
# stamped over its lot; exact per-tile agreement runs 0.66 (Tegel) to 0.95
# (Rush Hour) across the saves -- the gap is small decays and garden tiles
# carrying their trees' value -- so the floor sits at 0.60. The EFFECTIVE
# twin is BASE * 1.25 (the summer multiplier) on >= 99% of nonzero cells.
const MIN_FLAMMABILITY_AGREEMENT : float = 0.60
const MIN_FLAMMABILITY_PAIR : float = 0.98
const PROP_FLAMMABILITY : int = 0x29244db5

func _check_flammability_grids(city, model) -> bool:
    var base = model.grid(SimGridSubfile.FLAMMABILITY_BASE)
    var eff = model.grid(SimGridSubfile.FLAMMABILITY_EFFECTIVE)
    if base == null or eff == null or city.lot_model == null or city.building_records.is_empty():
        print("  note  no flammability grids, lots or buildings, skipping")
        return true
    var ok := true

    # Building flammability stamped over its lot rect vs the base grid.
    var flam_by_cell := {}
    for rec in city.building_records:
        var f = Core.exemplar_prop(rec.exemplar_tgi[1], rec.exemplar_tgi[2], PROP_FLAMMABILITY)
        if f != null:
            flam_by_cell[PollutionSim.occupant_cell(rec)] = f
    var agreed := 0
    var checked := 0
    for lot in city.lot_model.lots:
        var expected = null
        for cell in LotModel.cells_of(lot):
            if flam_by_cell.has(cell):
                expected = flam_by_cell[cell]
                break
        if expected == null:
            continue
        for cell in LotModel.cells_of(lot):
            var v : int = int(base.at_tile(cell.x, cell.y, model.map_tiles))
            if v == 0:
                continue
            checked += 1
            if v == int(expected):
                agreed += 1
    if checked < MIN_WEALTH_SAMPLES:
        print("  note  only %d flammable lot tiles -- flammability check not meaningful" % checked)
    else:
        var rate : float = float(agreed) / float(checked)
        if rate >= MIN_FLAMMABILITY_AGREEMENT:
            print("  ok    flammability grid matches building exemplars on %.1f%% of %d tiles"
                % [rate * 100.0, checked])
        else:
            push_error("flammability grid matches building exemplars on only %.1f%% of %d tiles (floor %.0f%%)"
                % [rate * 100.0, checked, MIN_FLAMMABILITY_AGREEMENT * 100.0])
            ok = false

    # The pair relation: base = 0.8 * effective (within u8 rounding), or the
    # two equal where the seasonal factor is not applied.
    var pair_ok := 0
    var pair_n := 0
    for i in range(eff.values.size()):
        var e : float = eff.values[i]
        if e == 0:
            continue
        pair_n += 1
        var b : float = base.values[i]
        if absf(b - 0.8 * e) <= 1.0 or b == e:
            pair_ok += 1
    if pair_n > 0:
        var pair_rate : float = float(pair_ok) / float(pair_n)
        if pair_rate >= MIN_FLAMMABILITY_PAIR:
            print("  ok    flammability pair holds base = 0.8 x effective on %.1f%% of %d cells"
                % [pair_rate * 100.0, pair_n])
        else:
            push_error("flammability pair relation holds on only %.1f%% of %d cells (floor %.0f%%)"
                % [pair_rate * 100.0, pair_n, MIN_FLAMMABILITY_PAIR * 100.0])
            ok = false
    return ok

# The wealth data view renders from the LIVE lot model, not the saved grid:
# razing a lot must recolour its tiles to vacant. Guard that wiring end to
# end -- activate the view, raze a wealthy growable lot through the model
# choke point, and require the repainted image to change to the vacant
# colour on the lot's cell. Runs last in the chain because the raze is
# permanent, like every other edit here. The repaint is normally deferred
# and coalesced; the harness pumps it directly since _ready never yields.
func _check_data_view_live(city) -> bool:
    print("\n--- data view live update ---")
    if city.lot_model == null:
        print("  note  no lots in this save, skipping")
        return true
    # This check is about the WEALTH-CLASS rendering following lot edits; the
    # simulated-gradient rendering (the default) is _check_simulation's
    # business, so pin the source for the duration.
    city.set_land_value_simulated(false)
    if not city.set_data_view_named("Land value"):
        push_error("could not activate the Land value data view")
        city.set_land_value_simulated(true)
        return false

    # A growable lot with nonzero wealth, still standing at this point.
    var target = null
    for cell in city.lot_model.by_cell.keys():
        var lot = city.lot_model.lot_at(cell)
        if lot != null and LotModel.is_growable(lot) and lot.zone_wealth > 0:
            target = lot
            break
    if target == null:
        print("  note  no wealthy growable lot left to raze, skipping")
        city.set_data_view(null)
        return true

    var view = city.data_view_active
    var cell : Vector2i = LotModel.cells_of(target)[0]
    var before : Color = city.data_view_image.get_pixel(cell.x, cell.y)
    var expected_before : Color = view.color_for(
        DataViewCatalogue.WEALTH_TO_LAND_VALUE[target.zone_wealth])
    var expected_after : Color = view.color_for(DataViewCatalogue.WEALTH_TO_LAND_VALUE[0])

    city.lot_model.remove([target])
    city._repaint_data_view()
    var after : Color = city.data_view_image.get_pixel(cell.x, cell.y)
    city.set_data_view(null)

    var ok := true
    if not _colors_close(before, expected_before):
        push_error("tile %s painted %s before the raze, expected wealth-%d colour %s"
            % [cell, before, target.zone_wealth, expected_before])
        ok = false
    if not _colors_close(after, expected_after):
        push_error("tile %s painted %s after the raze, expected vacant colour %s"
            % [cell, after, expected_after])
        ok = false
    if ok:
        print("  ok    razing the lot at %s recoloured it %s -> %s" % [cell, before, after])
    city.set_land_value_simulated(true)
    return ok

# get_pixel round-trips through RGBA8, so compare with an 8-bit tolerance.
func _colors_close(a : Color, b : Color) -> bool:
    return abs(a.r - b.r) < 0.01 and abs(a.g - b.g) < 0.01 \
        and abs(a.b - b.b) < 0.01 and abs(a.a - b.a) < 0.01

# The simulation: clock, systems, derived fields and their gates. Runs LAST --
# it steps months and razes a lot of its own, and like every other edit in
# this harness those are permanent.
#
# What is gated and why:
#   - fixed point: stepping with no edits must leave every derived field
#     byte-identical. The simulators are stateless recomputes, so any drift
#     is nondeterminism -- the bug class the plan's step 2 check exists for.
#   - land value vs wealth: no save stores land value, so the calibration IS
#     thresholding ours at the Land Value Sim wealth boundaries [70, 120] and
#     comparing to each lot's zone_wealth. Fitted across all populated saves
#     this scores mean 0.82, worst 0.57 (Rush Hour Tutorial), so the floor is
#     0.50 (margin for the lots the earlier checks raze) -- the same
#     "identify by agreement, then gate on it" move as the occupant-code
#     grid, just against a simulated field instead of a decode table.
#   - pollution structure: no saved target exists either (the plan's twin
#     candidates decode as flammability), so the gate is the property that
#     made SC4's field recognisable: industry outpollutes residential.
#   - crime structure: same shape -- poor tiles outscore wealthy ones.
#   - edit response: razing a polluting lot must lower total pollution and
#     move land value on the next tick, which is the whole point of
#     simulating rather than snapshotting.
const MIN_LAND_VALUE_AGREEMENT : float = 0.50
const SIM_FIXED_POINT_MONTHS : int = 3

func _check_simulation(city) -> bool:
    print("\n--- simulation ---")
    var sim = city.simulation
    if sim == null:
        push_error("no simulation was set up for a loaded save")
        return false
    var ok := true

    if sim.system_names() == ["traffic", "pollution", "land value", "crime"]:
        print("  ok    systems registered in dependency order, month %d" % sim.month)
    else:
        push_error("systems out of order: %s" % [sim.system_names()])
        ok = false

    var grids = city.sim_grids_model()
    for entry in [["traffic", SimGrids.DERIVED_TRAFFIC],
            ["air pollution", SimGrids.DERIVED_AIR_POLLUTION],
            ["land value", SimGrids.DERIVED_LAND_VALUE],
            ["crime", SimGrids.DERIVED_CRIME],
            ["police coverage", SimGrids.DERIVED_POLICE_COVERAGE]]:
        if grids.grid(entry[1]) == null:
            push_error("derived %s layer missing after the load tick" % entry[0])
            ok = false
    if not ok:
        return false

    # Fixed point under no edits. The load tick ran before this harness's
    # tool checks razed lots and drew roads, so one settling step first --
    # otherwise the first comparison step legitimately folds those edits in
    # and reads as drift.
    sim.step()
    var before := {}
    for id in grids.derived.keys():
        before[id] = grids.derived[id].values.duplicate()
    sim.step(SIM_FIXED_POINT_MONTHS)
    var drifted : Array = []
    for id in before.keys():
        if grids.derived[id].values != before[id]:
            drifted.append("%08X" % id)
    if drifted.is_empty():
        print("  ok    %d months with no edits left every derived field identical"
            % SIM_FIXED_POINT_MONTHS)
    else:
        push_error("derived fields drifted with no edits: %s" % [drifted])
        ok = false

    ok = _check_land_value_agreement(city, grids) and ok
    ok = _check_pollution_structure(city, grids) and ok
    ok = _check_crime_structure(city, grids) and ok
    ok = _check_traffic_assignment(city, grids) and ok
    ok = _check_simulation_edit_response(city, grids, sim) and ok
    return ok

# The commute assignment against SC4's own saved car volumes. Shape, not
# magnitude: everywhere WE route traffic must be somewhere SC4 recorded car
# traffic (precision -- routing down a railway or through a field would
# break this), and busier-vs-quieter must broadly agree (rank correlation
# over the shared footprint). Recall is deliberately NOT gated: one
# shortest path per lot concentrates flow on trunk routes and leaves side
# streets empty, which SC4's capacity-aware multi-path assignment does not.
# Save tiles only -- roads the harness itself drew have no saved volume.
const MIN_TRAFFIC_PRECISION : float = 0.85
const MIN_TRAFFIC_RANK_CORRELATION : float = 0.10

func _check_traffic_assignment(city, grids) -> bool:
    var ours = grids.grid(SimGrids.DERIVED_TRAFFIC)
    var theirs = grids.grid(SimGridSubfile.TRAFFIC_CAR)
    var model = city.network_model
    if ours == null or theirs == null or model == null:
        print("  note  no assignment or no saved car-traffic grid to compare")
        return true
    var side : int = grids.map_tiles
    var our_vals : Array = []
    var their_vals : Array = []
    var on_traffic := 0
    var routed := 0
    for cell in model.tiles.keys():
        if model.get_tile(cell).source != NetworkModel.SOURCE_SAVE:
            continue
        var o : float = ours.at_tile(cell.x, cell.y, side)
        var t : float = theirs.at_tile(cell.x, cell.y, side)
        if o > 0.0:
            routed += 1
            if t > 0.0:
                on_traffic += 1
                our_vals.append(o)
                their_vals.append(t)
    if routed == 0:
        # Legitimate on job-less or road-less saves; everywhere else it means
        # the demand model found nothing, which the structure checks would
        # already have flagged as all-zero pollution from traffic.
        print("  note  the assignment routed no traffic (no residential-to-job path?)")
        return true
    var ok := true
    var precision : float = float(on_traffic) / float(routed)
    if precision >= MIN_TRAFFIC_PRECISION:
        print("  ok    %.1f%% of our %d trafficked save tiles carry SC4 car traffic too"
            % [precision * 100.0, routed])
    else:
        push_error("only %.1f%% of our %d trafficked tiles carry SC4 car traffic (floor %.0f%%)"
            % [precision * 100.0, routed, MIN_TRAFFIC_PRECISION * 100.0])
        ok = false
    if our_vals.size() >= 100:
        var rho : float = _spearman(our_vals, their_vals)
        if rho >= MIN_TRAFFIC_RANK_CORRELATION:
            print("  ok    volume rank correlation with SC4 is %.3f over %d shared tiles"
                % [rho, our_vals.size()])
        else:
            push_error("volume rank correlation %.3f below the %.2f floor (%d shared tiles)"
                % [rho, MIN_TRAFFIC_RANK_CORRELATION, our_vals.size()])
            ok = false
    else:
        print("  note  only %d shared trafficked tiles -- rank correlation skipped" % our_vals.size())
    return ok

static func _spearman(a : Array, b : Array) -> float:
    var ra := _ranks(a)
    var rb := _ranks(b)
    var n : int = ra.size()
    var ma : float = 0.0
    var mb : float = 0.0
    for i in range(n):
        ma += ra[i]
        mb += rb[i]
    ma /= n
    mb /= n
    var cov : float = 0.0
    var va : float = 0.0
    var vb : float = 0.0
    for i in range(n):
        cov += (ra[i] - ma) * (rb[i] - mb)
        va += (ra[i] - ma) * (ra[i] - ma)
        vb += (rb[i] - mb) * (rb[i] - mb)
    if va == 0.0 or vb == 0.0:
        return 0.0
    return cov / sqrt(va * vb)

# Average ranks with ties shared, matching the offline calibration scripts.
static func _ranks(v : Array) -> Array:
    var order : Array = range(v.size())
    order.sort_custom(func(x, y): return v[x] < v[y])
    var ranks : Array = []
    ranks.resize(v.size())
    var i : int = 0
    while i < order.size():
        var j : int = i
        while j + 1 < order.size() and v[order[j + 1]] == v[order[i]]:
            j += 1
        var avg : float = (i + j) / 2.0
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks

func _check_land_value_agreement(city, grids) -> bool:
    if city.lot_model == null:
        print("  note  no lots to score land value against")
        return true
    var agreed := 0
    var checked := 0
    for cell in city.lot_model.by_cell.keys():
        var lot = city.lot_model.lot_at(cell)
        if lot == null or lot.zone_wealth == 0:
            continue
        checked += 1
        var value : float = grids.value_at_tile(SimGrids.DERIVED_LAND_VALUE, cell.x, cell.y)
        if LandValueSim.wealth_class(value) == lot.zone_wealth:
            agreed += 1
    if checked < MIN_WEALTH_SAMPLES:
        print("  note  only %d wealthy lot tiles -- land-value agreement not meaningful" % checked)
        return true
    var rate : float = float(agreed) / float(checked)
    if rate >= MIN_LAND_VALUE_AGREEMENT:
        print("  ok    simulated land value reproduces lot wealth on %.1f%% of %d tiles"
            % [rate * 100.0, checked])
        return true
    push_error("simulated land value reproduces lot wealth on only %.1f%% of %d tiles (floor %.0f%%)"
        % [rate * 100.0, checked, MIN_LAND_VALUE_AGREEMENT * 100.0])
    return false

# DIRTY industrial tiles (zones 8-9) must, on average, sit in a dirtier
# field than residential ones. Zone 7 is agriculture and does not count --
# farms barely pollute, and on farming saves (Tegel, Kensington) lumping
# them in drags the "industry" mean below residential-street traffic.
# Both cohorts need enough tiles for a mean to mean anything.
func _check_pollution_structure(city, grids) -> bool:
    if city.lot_model == null:
        print("  note  no lots to check pollution structure against")
        return true
    var sums := {"industry": 0.0, "residential": 0.0}
    var counts := {"industry": 0, "residential": 0}
    for cell in city.lot_model.by_cell.keys():
        var lot = city.lot_model.lot_at(cell)
        if lot == null:
            continue
        var kind : String
        if lot.zone_type >= 8 and lot.zone_type <= 9:
            kind = "industry"
        elif lot.zone_type >= 1 and lot.zone_type <= 3:
            kind = "residential"
        else:
            continue
        sums[kind] += grids.value_at_tile(SimGrids.DERIVED_AIR_POLLUTION, cell.x, cell.y)
        counts[kind] += 1
    if counts["industry"] < 50 or counts["residential"] < 50:
        print("  note  too few dirty-industry/residential tiles (%d/%d) for the pollution check"
            % [counts["industry"], counts["residential"]])
        return true
    var ind_mean : float = sums["industry"] / counts["industry"]
    var res_mean : float = sums["residential"] / counts["residential"]
    if ind_mean > res_mean:
        print("  ok    industry sits in a dirtier air field than residential (%.0f vs %.0f over %d/%d tiles)"
            % [ind_mean, res_mean, counts["industry"], counts["residential"]])
        return true
    push_error("air pollution means: industry %.1f <= residential %.1f" % [ind_mean, res_mean])
    return false

func _check_crime_structure(city, grids) -> bool:
    if city.lot_model == null:
        print("  note  no lots to check crime structure against")
        return true
    var sums := {1: 0.0, 3: 0.0}
    var counts := {1: 0, 3: 0}
    for cell in city.lot_model.by_cell.keys():
        var lot = city.lot_model.lot_at(cell)
        if lot == null or not counts.has(lot.zone_wealth):
            continue
        sums[lot.zone_wealth] += grids.value_at_tile(SimGrids.DERIVED_CRIME, cell.x, cell.y)
        counts[lot.zone_wealth] += 1
    if counts[1] < 50 or counts[3] < 50:
        print("  note  too few $/$$$ tiles (%d/%d) for the crime check" % [counts[1], counts[3]])
        return true
    var poor : float = sums[1] / counts[1]
    var rich : float = sums[3] / counts[3]
    if poor > rich:
        print("  ok    crime is higher on $ tiles than $$$ tiles (%.0f vs %.0f over %d/%d)"
            % [poor, rich, counts[1], counts[3]])
        return true
    push_error("crime means: $ %.1f <= $$$ %.1f" % [poor, rich])
    return false

# Razing a polluting lot and stepping must lower total air pollution and
# change the land-value field. Needs a growable lot whose building actually
# pollutes; without one the response cannot be asserted.
func _check_simulation_edit_response(city, grids, sim) -> bool:
    if city.lot_model == null:
        print("  note  no lots to raze for the edit-response check")
        return true
    var victim = null
    var victim_cell := Vector2i.ZERO
    for rec in city.building_records:
        var centre = Core.exemplar_prop(rec.exemplar_tgi[1], rec.exemplar_tgi[2], 0x27812851)
        var radius = Core.exemplar_prop(rec.exemplar_tgi[1], rec.exemplar_tgi[2], 0x68EE9764)
        if typeof(centre) != TYPE_ARRAY or centre.is_empty() \
                or typeof(radius) != TYPE_ARRAY or radius.is_empty():
            continue
        var mag : int = centre[0]
        # The building must actually stamp: positive magnitude (not zero, not
        # a negative absorber) AND a nonzero radius -- farm sheds carry air 1
        # radius 0, which contributes nothing and cannot respond to a raze.
        if mag == 0 or mag >= 0x80000000 or radius[0] <= 0.0:
            continue
        var cell : Vector2i = PollutionSim.occupant_cell(rec)
        # And its tile must sit INSIDE the clamp range: on a farm belt the
        # crop fields absorb more than the shed emits, the whole area floors
        # at 0, and razing one emitter moves nothing; a cell pinned at the
        # 1024 ceiling by neighbouring industry likewise cannot fall.
        var value : float = grids.value_at_tile(SimGrids.DERIVED_AIR_POLLUTION, cell.x, cell.y)
        if value <= 0.5 or value >= 1000.0:
            continue
        var lot = city.lot_model.lot_at(cell)
        if lot != null and LotModel.is_growable(lot):
            victim = lot
            victim_cell = cell
            break
    if victim == null:
        print("  note  no growable lot with a visibly polluting building left to raze")
        return true

    var air_before : float = grids.value_at_tile(SimGrids.DERIVED_AIR_POLLUTION,
        victim_cell.x, victim_cell.y)
    var land_before : Array = grids.grid(SimGrids.DERIVED_LAND_VALUE).values.duplicate()
    city.lot_model.remove([victim])
    sim.step()
    var air_after : float = grids.value_at_tile(SimGrids.DERIVED_AIR_POLLUTION,
        victim_cell.x, victim_cell.y)
    var land_after : Array = grids.grid(SimGrids.DERIVED_LAND_VALUE).values
    var ok := true
    if air_after < air_before:
        print("  ok    razing the polluting lot at %s lowered air there (%.1f -> %.1f)"
            % [victim_cell, air_before, air_after])
    else:
        push_error("air pollution at %s did not fall after razing its polluting lot (%.1f -> %.1f)"
            % [victim_cell, air_before, air_after])
        ok = false
    # Land value CAN legitimately hold still: the neighbourhood-wealth term
    # is a mean over developed cells, so razing a wealth-1 lot inside a
    # uniformly wealth-1 district removes cells without moving any window's
    # mean (Tegel's farm belt does exactly this). Moved = good signal;
    # unmoved = only a note.
    if land_after != land_before:
        print("  ok    the land-value field moved in response")
    else:
        print("  note  land value unchanged -- razed lot's neighbourhood is uniform wealth")
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

    # Pick a real road tile with neighbours, so removing it actually disturbs
    # something, and prefer one in the middle of a run.
    var victim = _pick_victim(model)
    if victim == null:
        print("  note  no suitable tile to test removal against")
        return true
    # Held across the removal so it can be put back. remove() erases the model's
    # reference, not the Tile itself.
    var victim_tile = model.get_tile(victim)

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
        return false
    print("  ok    incremental removal matches a full rebuild")

    # And the same in the ADDING direction, which is the harder one: an
    # incremental update tears down the boundaries around the dirty cells and
    # re-derives them, and a portal still carrying an untouched neighbour's arcs
    # has to survive that and still be visible to the stitch. When it was not,
    # the re-emitted tile found nothing to pair with and the boundary quietly
    # came apart -- with the arc count unchanged, so only comparing against a
    # full rebuild catches it.
    var ok := true
    model.place([victim_tile])
    var incremental_after_place : int = graph.fingerprint()
    graph.rebuild()
    if graph.fingerprint() == incremental_after_place:
        print("  ok    incremental placement matches a full rebuild")
    else:
        push_error("after placement, incremental graph disagrees with a full rebuild")
        ok = false
    # The city keeps the edit: remove() relaxed the victim's neighbours' edge
    # codes in place and nothing restores those, so this is not a round trip.
    # Later checks capture their own before-state, so that is theirs to handle.
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
