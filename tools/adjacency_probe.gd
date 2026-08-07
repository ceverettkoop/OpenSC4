extends Node

# Prints a local map around each adjacent-but-unclaimed car-tile pair, so a
# screenshot can be lined up against it. Each cell shows its WNES codes.

var dat_files = ["SimCity_1.dat","SimCity_2.dat","SimCity_3.dat","SimCity_4.dat","SimCity_5.dat","EP1.dat"]

func _ready() -> void:
    if Core.game_dir == null:
        var config = INI.new("user://config.ini")
        Core.game_dir = config.sections["paths"]["sc4_files"] if config.sections.has("paths") \
            else ProjectSettings.globalize_path("res://")
    for f in dat_files:
        Core.add_dbpf(DBPF.new(Core.game_dir + "/" + f))
    var save = DBPF.new("%s/Regions/Timbuktu/City - Big City Tutorial.sc4" % Core.game_dir)
    var idx = save.indices_by_type.get(0xc9c05c6e, [])[0]
    var nsub = save.get_subfile(idx.type_id, idx.group_id, idx.instance_id, NetworkSubfile)
    var model = NetworkModel.new()
    model.seed_from_save(nsub.tiles)
    var graph = NetworkGraph.new(model)

    var car_cells := {}
    for arc in graph.arcs:
        if arc != null and arc.transport_class == SC4PathSubfile.CLASS_CAR:
            car_cells[arc.cell] = true

    # Collect the pairs, then group them so a run of them shows up as a run.
    var pairs : Array = []
    for cell in car_cells.keys():
        for side in [SC4PathSubfile.SIDE_EAST, SC4PathSubfile.SIDE_SOUTH]:
            var other : Vector2i = cell + NetworkModel.SIDE_DELTA[side]
            if not car_cells.has(other):
                continue
            var a = model.tiles[cell]
            var b = model.tiles[other]
            if a.wnes[side] != 0 and b.wnes[NetworkModel.opposite(side)] != 0:
                continue
            pairs.append([cell, other])
    pairs.sort_custom(func(p, q): return p[0].x < q[0].x or (p[0].x == q[0].x and p[0].y < q[0].y))
    print("%d unclaimed adjacent car pairs" % pairs.size())

    # Which pairs have the most company within 2 tiles? That is the clearest
    # one to photograph.
    var best = null
    var best_n := -1
    for p in pairs:
        var n := 0
        for q in pairs:
            if absi(q[0].x - p[0].x) <= 2 and absi(q[0].y - p[0].y) <= 2:
                n += 1
        if n > best_n:
            best_n = n
            best = p
    print("densest cluster around %s <-> %s (%d pairs within 2 tiles)" % [best[0], best[1], best_n])
    for p in pairs.slice(0, 12):
        print("   pair %s <-> %s" % [p[0], p[1]])
    _dump(model, car_cells, best[0], 4)

# A WNES grid around `centre`. "." = no tile, "x" = tile with no car arcs.
func _dump(model, car_cells : Dictionary, centre : Vector2i, radius : int) -> void:
    print("--- WNES codes around %s (columns = x, rows = z; north is -z)" % centre)
    var header := "      "
    for x in range(centre.x - radius, centre.x + radius + 1):
        header += "x=%-11d" % x
    print(header)
    for z in range(centre.y - radius, centre.y + radius + 1):
        var row := "z=%-4d" % z
        for x in range(centre.x - radius, centre.x + radius + 1):
            var c := Vector2i(x, z)
            var t = model.tiles.get(c)
            if t == null:
                row += "%-13s" % "."
            elif not car_cells.has(c):
                row += "%-13s" % ("x%s" % [t.wnes])
            else:
                row += "%-13s" % ("%s" % [t.wnes])
        print(row)
    print("--- pieces")
    for z in range(centre.y - radius, centre.y + radius + 1):
        var row := "z=%-4d" % z
        for x in range(centre.x - radius, centre.x + radius + 1):
            var t = model.tiles.get(Vector2i(x, z))
            row += "%-12s" % ("." if t == null else "%08x" % t.piece_id)
        print(row)
    print("ADJACENCY PROBE DONE")
    get_tree().quit()
