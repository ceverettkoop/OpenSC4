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
    ok = _check_incremental(city, model, graph) and ok
    ok = _check_tool(city, model, graph) and ok
    ok = _check_crossing(city, model, graph) and ok
    ok = _check_lot_bulldoze(city, model) and ok
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
