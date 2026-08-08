extends MeshInstance3D

# Draws the roads the build tool lays down, and solves their shape.
#
# Was TransitTiles.gd, which also loaded the RUL files and handled mouse input.
# Those are now NetworkPieceDB and NetworkTool; what stays here is everything
# that turns a drag into geometry: snapping it to one of 24 directions, working
# out each tile's edge codes, reconciling them with the tiles already there,
# picking the piece that best fits its neighbours, and emitting the vertices.
#
# Coordinates. The solver below works in float Vector2 throughout, because it
# does arithmetic against corner offsets and direction vectors that are
# genuinely fractional. NetworkModel keys on Vector2i, where Vector2(1,2) and
# Vector2i(1,2) are different dictionary keys entirely. The conversion happens
# at this class's public methods and nowhere else -- inside, everything is
# Vector2; outside, everything is Vector2i.
#
# Texturing. The transit shader (City.tscn SubResource 18) reads the
# texture-array layer out of UV2, packed as (layer & 255, layer >> 8) with 128
# added to the green channel once a tile is committed. That path works: a probe
# quad carrying UV2 (13, 128) through an ArrayMesh comes out of the fragment
# stage as layer 13, and the 285-layer array packs every RUL texture id without
# dropping one.
#
# Drawn roads used to render solid black anyway, and the cause was the face
# NORMALS below, not UV2. Both triangle windings here are counter-clockwise
# seen from above, so the old v.cross(u) produced (0, -1, 0) -- a road lit by a
# sun overhead through a normal aimed at the ground gets no diffuse term, and
# City.tscn's environment draws its ambient from a background whose energy
# multiplier is 0, leaving nothing. The shader is also `unshaded` now, matching
# the material City.gd gives the save's own network quads, because SC4's road
# textures already have their lighting baked in.
class_name NetworkRenderer

var mat = self.get_material_override()
var textarr = false
var layer_arr : Array
var transit_tiles : Dictionary = {}
# The tiles this renderer has drawn, keyed by float Vector2 -- see the note on
# coordinates above. The authoritative record is NetworkModel; this is the
# solver's own working set, which also holds the RUL edge codes it needs and
# the model does not keep in the same form.
var network_tiles : Dictionary = {}
var model : NetworkModel = null
var piece_db : NetworkPieceDB = null
var drag_tiles : Dictionary = {}
var drag_arrays : Array = []
var built_arrays : Array = []
var drag_tracker : Array = []
var built_tracker : Array = []
var drag_meshinst = MeshInstance3D.new()
# The ground ("sidewalk") layer under the tiles this renderer drew, and its own
# mesh instance. It is kept apart from `built_arrays` on purpose: that array
# pairs one 6-vertex block with one `built_tracker` entry and de-duplicates by
# the FIRST entry matching a location, so a second quad per cell would collide
# with the first on every redraw. Rebuilt wholesale instead -- only user-drawn
# tiles are in here (the save's own ground quads are City.gd's), so it is small.
var base_meshinst = MeshInstance3D.new()
# location -> {"verts": Array[Vector3], "uvs": Array[Vector2]}, the surface quad
# as it was emitted. The ground quad is that same quad dropped to BASE_LIFT, so
# it stays parallel to the piece over sloped ground for free.
var drag_quads : Dictionary = {}
var built_quads : Dictionary = {}
# The lots beside a tile decide its ground family. Set by City.gd via setup().
var lots = null
var layer_map = []
var map_width : int
var map_height : int
var drag_first = true
#input
var start_l = false
var hold_l = false
var drag_modes = {
    "Elevated Highway": 0x0011, "WaterPipe": 0x0011,"Rail":0x1111, 		"Road": 0x1111, 
    "Street":0x0001, 			"Subway":0x0011, 	"Avenue": 0x0011,	"Elevated Rail": 0x0011, 
    "One-Way Road": 0x1111, 	"Dirt Road":0x1111, "Monorail": 0x0011, "Ground Highway":0x0011
}
"""
11	12	13	14	15
10	2	3	4	16
9	1	0	5	17
24	8	7	6	18
23	22	21	20	19
"""
var neigh_num_to_vec = [
    # middle
    Vector2(0, 0),
    # inner ring
    Vector2(-1, 0),Vector2(-1, -1),Vector2(0, -1),Vector2(1, -1),
    Vector2(1, 0),Vector2(1, 1),Vector2(0, 1),Vector2(-1, 1),
    # outer ring
    Vector2(-2, 0),Vector2(-2, -1),Vector2(-2, -2),Vector2(-1, -2),
    Vector2(0, -2),Vector2(1, -2),Vector2(2, -2),Vector2(2, -1),
    Vector2(2, 0),Vector2(2, 1),Vector2(2, 2),Vector2(1, 2),
    Vector2(0, 2),Vector2(-1, 2),Vector2(-2, 2),Vector2(-2, 1)
]

# Set up by City.gd once the piece database and the model exist. Nothing here
# loads game data any more -- NetworkPieceDB does that once and is shared.
func setup(db : NetworkPieceDB, network_model : NetworkModel, lot_model = null) -> void:
    piece_db = db
    model = network_model
    lots = lot_model
    transit_tiles = db.pieces
    layer_arr = db.layer_ids
    textarr = db.texture_array
    mat = get_material_override()
    if textarr and mat != null:
        mat.set_shader_parameter("textarr", textarr)
    if mat == null or not textarr:
        Log.warn("NetworkRenderer: material %s, texture array %s -- drawn roads will not texture"
            % ["ok" if mat != null else "MISSING", "ok" if textarr else "MISSING"])
    if drag_meshinst.get_parent() == null:
        add_child(drag_meshinst)
    if base_meshinst.get_parent() == null:
        base_meshinst.name = "GroundLayer"
        add_child(base_meshinst)
    drag_meshinst.set_material_override(mat)
    base_meshinst.set_material_override(mat)
    set_material_override(mat)

# --- the tool's interface ----------------------------------------------------
#
# Vector2i in, Vector2i out. The solver below is all float Vector2; this is the
# only place the two meet.

func clear_preview() -> void:
    drag_arrays = []
    drag_tiles = {}
    drag_tracker = []
    drag_quads = {}
    if drag_meshinst.mesh != null and drag_meshinst.mesh.get_surface_count() > 0:
        drag_meshinst.mesh = null

# Shows what a drag from `from` to `to` would build, without building it.
func preview_draw(from : Vector2i, to : Vector2i, network : String, first : bool) -> void:
    if piece_db == null or not piece_db.has_network(network):
        return
    drag_first = first
    drag_network = network
    drag_meshinst.set_material_override(mat)
    _drag_network(Vector2(from.x, from.y), Vector2(to.x, to.y), network)

# Highlights the tiles a bulldoze would remove. Flat quads rather than the
# drag solver's machinery, so bulldoze does not depend on any of it.
func preview_bulldoze(cells : Array) -> void:
    clear_preview()
    if cells.is_empty():
        return
    var verts := PackedVector3Array()
    var colours := PackedColorArray()
    var red := Color(1.0, 0.2, 0.2, 0.5)
    for cell in cells:
        var h : float = _tile_height(cell) + BULLDOZE_LIFT
        var corners = [Vector3(cell.x, h, cell.y), Vector3(cell.x, h, cell.y + 1),
            Vector3(cell.x + 1, h, cell.y + 1), Vector3(cell.x + 1, h, cell.y)]
        for i in [0, 1, 2, 0, 2, 3]:
            verts.append(corners[i])
            colours.append(red)
    var arrays := []
    arrays.resize(ArrayMesh.ARRAY_MAX)
    arrays[ArrayMesh.ARRAY_VERTEX] = verts
    arrays[ArrayMesh.ARRAY_COLOR] = colours
    var mesh_out := ArrayMesh.new()
    mesh_out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    var flat := StandardMaterial3D.new()
    flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    flat.vertex_color_use_as_albedo = true
    flat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    flat.cull_mode = BaseMaterial3D.CULL_DISABLED
    mesh_out.surface_set_material(0, flat)
    drag_meshinst.set_material_override(null)
    drag_meshinst.mesh = mesh_out

# The cells the pending drag would occupy, before it is committed. The tool
# uses it to clear the lots in the way first; the solver's own working keys are
# float Vector2, so this is the conversion point like everything else here.
func pending_cells() -> Array:
    var out : Array = []
    for loc in drag_tiles.keys():
        out.append(Vector2i(int(loc.x), int(loc.y)))
    return out

# Commits the pending drag: bakes the geometry and registers the tiles with the
# model, which is what makes the graph follow. Returns the dirty cells.
func commit_draw() -> Array:
    if drag_tiles.is_empty():
        return []
    var records : Array = []
    for loc in drag_tiles.keys():
        var record = _to_model_tile(loc, drag_tiles[loc])
        if record != null:
            records.append(record)
    _build_network()
    drag_meshinst.set_material_override(mat)
    if model == null or records.is_empty():
        return []
    var dirty = model.place(records)
    # After place(), so the ground family is picked from tiles that are already
    # in the model -- _rebuild_base_mesh reads base_texture back off it.
    _rebuild_base_mesh()
    return dirty

# Turns one solved tile into the record NetworkModel keeps. The RUL 3-line
# gives the texture and a rotation/flip pair, which is exactly the piece id and
# orientation byte the model and SC4Path want -- the flip goes in bit 7, the
# same place NetworkTile.orientation carries it.
func _to_model_tile(loc : Vector2, tile) -> Variant:
    if not tile.tile.ids.has(0):
        return null
    var spec = tile.tile.ids[0]        # [texture iid, rotation, flip]
    var record = NetworkModel.Tile.new()
    record.cell = Vector2i(int(loc.x), int(loc.y))
    record.piece_id = spec[0]
    record.orientation = (int(spec[1]) & 3) | (0x80 if int(spec[2]) == 1 else 0)
    record.wnes = PackedInt32Array(tile.edges)
    var drag_type := _network_type_index(drag_network)
    record.network_types = [drag_type]
    record.crossings = [{
        "type": drag_type,
        "west": tile.edges[0], "north": tile.edges[1],
        "east": tile.edges[2], "south": tile.edges[3],
    }]
    # Dragging across a DIFFERENT network is a level crossing, and the tile this
    # record replaces is the only surviving record of the other network being
    # here -- so carry its crossings over rather than erasing them. The piece
    # drawn is still the drag network's: SC4 has dedicated crossing pieces and
    # choosing one needs the crossed network's RUL table, so for now the graph
    # gets the drag's lanes and not the crossed network's. Crossing the SAME
    # network needs no second entry; the merged edges above already describe the
    # whole intersection, and duplicating it would double-count in the model's
    # type histogram.
    var existing = model.get_tile(record.cell) if model != null else null
    if existing != null:
        for crossing in existing.crossings:
            if crossing["type"] == drag_type:
                continue
            record.crossings.append(crossing)
            record.network_types.append(crossing["type"])
    record.base_height = _tile_height(record.cell)
    record.source = NetworkModel.SOURCE_USER
    # The sidewalk/verge under the piece. The save stores this per tile; a drawn
    # tile has to derive it from the lots beside it. Keeping it on the model
    # record rather than only in the mesh means a tile that came from a drag and
    # one that came from the save answer the same question the same way.
    record.base_texture = NetworkBaseTexture.pick(record.cell, lots)
    return record

static func _network_type_index(network : String) -> int:
    var idx = NetworkSubfile.NETWORK_TYPE_NAMES.find(network)
    return idx if idx >= 0 else 0

# Drops tiles this renderer drew. Save tiles are not ours to erase -- City.gd
# rebuilds their batched mesh instead.
func forget_cells(cells : Array) -> void:
    var touched := false
    for cell in cells:
        var loc := Vector2(cell.x, cell.y)
        if network_tiles.erase(loc):
            touched = true
    if touched:
        _rebuild_built_mesh(cells)
    # Unconditional: a multi-tile piece keeps ground quads at sub-tile locations
    # that were never keys in network_tiles, so `touched` does not cover them.
    _prune_base_quads()
    _rebuild_base_mesh()

# Rebuilds the committed mesh, dropping any quad whose cell no longer holds a
# tile. built_tracker records the cell each vertex belongs to, so this is a
# filter rather than a re-solve.
func _rebuild_built_mesh(_cells : Array) -> void:
    if built_arrays.is_empty() or built_tracker.is_empty():
        return
    var keep : Array = []
    for i in range(0, built_tracker.size(), 6):
        var loc = built_tracker[i]
        # Keep the quad while this renderer still owns the cell. The model check
        # is the second half of that, not a fallback to the model's authority:
        # a multi-tile piece tracks quads at sub-tile locations that are not
        # keys in network_tiles, and only the model knows those are still live.
        # A cell holding a SAVE tile is explicitly not ours -- City.gd draws
        # that one from its own batched mesh.
        var tile = model.get_tile(Vector2i(int(loc.x), int(loc.y))) if model != null else null
        if network_tiles.has(loc) or (tile != null and tile.source != NetworkModel.SOURCE_SAVE):
            keep.append(i)
    var filtered : Array = []
    filtered.resize(ArrayMesh.ARRAY_MAX)
    var tracker : Array = []
    for channel in range(built_arrays.size()):
        if built_arrays[channel] == null:
            continue
        filtered[channel] = []
        for start in keep:
            for k in range(6):
                filtered[channel].append(built_arrays[channel][start + k])
    for start in keep:
        for k in range(6):
            tracker.append(built_tracker[start + k])
    built_arrays = filtered
    built_tracker = tracker
    if mesh != null and mesh.get_surface_count() > 0:
        mesh.surface_remove(0)
    if not built_tracker.is_empty():
        if mesh == null:
            mesh = ArrayMesh.new()
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, get_mesh_arrays(built_arrays))

# --- the ground layer --------------------------------------------------------
#
# One quad per drawn tile, textured with the family NetworkBaseTexture picks and
# sitting BASE_LIFT under the piece. Rebuilt whole rather than patched: the set
# is only the tiles this renderer drew, and a partial update would have to track
# quads by cell inside a flat array, which is exactly the de-duplication trap
# `built_arrays` already sets (see the note on base_meshinst).

# Drops ground quads whose cell is no longer ours -- same ownership test as
# _rebuild_built_mesh, so the two layers cannot disagree about what is placed.
func _prune_base_quads() -> void:
    for loc in built_quads.keys():
        var tile = model.get_tile(Vector2i(int(loc.x), int(loc.y))) if model != null else null
        if network_tiles.has(loc) or (tile != null and tile.source != NetworkModel.SOURCE_SAVE):
            continue
        built_quads.erase(loc)

func _rebuild_base_mesh() -> void:
    for loc in drag_quads.keys():
        built_quads[loc] = drag_quads[loc]
    drag_quads = {}
    if piece_db == null:
        return
    var verts := PackedVector3Array()
    var uvs := PackedVector2Array()
    var uv2 := PackedVector2Array()
    var normals := PackedVector3Array()
    var colours := PackedColorArray()
    var up := Vector3(0, 1, 0)
    var white := Color(1, 1, 1, 1)
    for loc in built_quads.keys():
        var tile = model.get_tile(Vector2i(int(loc.x), int(loc.y))) if model != null else null
        if tile == null or tile.base_texture == NetworkBaseTexture.NONE:
            continue
        var layer := piece_db.layer_for_texture(tile.base_texture)
        if layer < 0:
            continue
        # Same split the piece quads use: low byte in UV2.r, high byte in UV2.g,
        # and 128 added to UV2.g to mark the quad as built rather than previewed.
        var layer_vec := Vector2(layer & 0xFF, ((layer & 0xFF00) >> 8) + 128)
        var quad = built_quads[loc]
        for i in range(6):
            verts.append(quad["verts"][i])
            uvs.append(quad["uvs"][i])
            uv2.append(layer_vec)
            normals.append(up)
            colours.append(white)
    if verts.is_empty():
        base_meshinst.mesh = null
        return
    var arrays := []
    arrays.resize(ArrayMesh.ARRAY_MAX)
    arrays[ArrayMesh.ARRAY_VERTEX] = verts
    arrays[ArrayMesh.ARRAY_NORMAL] = normals
    arrays[ArrayMesh.ARRAY_COLOR] = colours
    arrays[ArrayMesh.ARRAY_TEX_UV] = uvs
    arrays[ArrayMesh.ARRAY_TEX_UV2] = uv2
    var out := ArrayMesh.new()
    out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    base_meshinst.mesh = out

# Terrain height at a tile centre, in world units.
func _tile_height(cell : Vector2i) -> float:
    var terrain = get_parent().get_node_or_null("Terrain")
    if terrain == null or terrain.heightmap == null:
        return 0.0
    var hm = terrain.heightmap
    var z : int = clampi(cell.y, 0, hm.size() - 1)
    var x : int = clampi(cell.x, 0, hm[z].size() - 1)
    return hm[z][x] / 16.0

# Drawn roads sit at the terrain height the solver computed, which is exactly
# coplanar with the ground and z-fights with it. Lift them the same way City.gd
# lifts the save's network quads (NETWORK_SURFACE_LIFT), which also keeps them
# above the lot base textures at 0.015 + 0.004 * 7 = 0.043.
const SURFACE_LIFT : float = 0.075
# The ground/sidewalk quad sits just under the piece, the same 0.02 apart as
# City.gd holds the save's own pair (NETWORK_BASE_LIFT 0.055 under
# NETWORK_SURFACE_LIFT 0.075), so a drawn road and a shipped one that meet at a
# tile boundary line up instead of stepping.
const BASE_LIFT : float = 0.055
# Height a bulldoze highlight sits above the terrain, clear of the road quads.
const BULLDOZE_LIFT : float = 0.09

# The network the current drag is laying, for _to_model_tile.
var drag_network : String = "Road"

# --- what is already on the ground -------------------------------------------
#
# The drag solver has to reconcile a drag with two different sources of existing
# tiles: the ones this renderer drew, in `network_tiles`, which carries the RUL
# edge codes the solver works in; and the ones that came from the city save,
# which only NetworkModel knows about. `network_tiles` alone is not the ground
# truth and never was -- it is this class's working set.
#
# Consulting only `network_tiles` is why dragging a road across one of the
# SAVE's roads built a straight piece on top of it instead of an intersection.
# The merge below never saw the road being crossed, so the RUL table was asked
# for a two-edge shape; and the record that then replaced the save tile in the
# model carried only the drag's own edges, which took the crossed road's arcs
# out of the graph with them. Roads this renderer had drawn itself already
# worked, which is what hid it.
#
# Returns the four RUL edge codes at `loc`, or null if nothing is there.
func _existing_edges(loc : Vector2) -> Variant:
    if network_tiles.has(loc):
        return network_tiles[loc].edges
    if model == null:
        return null
    var tile = model.get_tile(Vector2i(int(loc.x), int(loc.y)))
    # NetworkModel keeps the unioned WNES as a PackedInt32Array; the RUL tables
    # are keyed by plain Array, and the two do not compare equal as dictionary
    # keys, so this has to convert rather than pass the packed array through.
    return Array(tile.wnes) if tile != null else null

func _has_existing(loc : Vector2) -> bool:
    if network_tiles.has(loc):
        return true
    return model != null and model.has_tile(Vector2i(int(loc.x), int(loc.y)))

func _drag_network(start, end, type):
    self.drag_arrays.resize(ArrayMesh.ARRAY_MAX)
    self.drag_arrays[ArrayMesh.ARRAY_VERTEX] = []
    self.drag_arrays[ArrayMesh.ARRAY_NORMAL] = [] 
    self.drag_arrays[ArrayMesh.ARRAY_COLOR] = [] 
    self.drag_arrays[ArrayMesh.ARRAY_TEX_UV] = [] 
    self.drag_arrays[ArrayMesh.ARRAY_TEX_UV2] = [] 
    self.drag_tiles = {}
    drag_tracker = []
    drag_quads = {}
    var heightmap = self.get_parent().get_node("Terrain").heightmap
    if len(layer_map) == 0:
        self.map_width = len(heightmap[0])
        self.map_height = len(heightmap)
        for _y in range(map_height):
            for _x in range(map_width):
                layer_map.append(0)
                layer_map.append(0)
    var directions = [
        # ortho
        Vector2(1, 0), 
        Vector2(-1, 0), 
        Vector2(0, 1), 
        Vector2(0, -1),
        # diag
        Vector2(1, 1).normalized(), 
        Vector2(-1, 1).normalized(), 
        Vector2(-1, -1).normalized(), 
        Vector2(1, -1).normalized(),
        # FAR-2
        Vector2(1, 2).normalized(),
        Vector2(1, -2).normalized(),
        Vector2(-1, 2).normalized(),
        Vector2(-1, -2).normalized(),
        Vector2(2, 1).normalized(),
        Vector2(2, -1).normalized(),
        Vector2(-2, 1).normalized(),
        Vector2(-2, -1).normalized(),
        # FAR-3
        Vector2(1, 3).normalized(),
        Vector2(1, -3).normalized(),
        Vector2(-1, 3).normalized(),
        Vector2(-1, -3).normalized(),
        Vector2(3, 1).normalized(),
        Vector2(3, -1).normalized(),
        Vector2(-3, 1).normalized(),
        Vector2(-3, -1).normalized()
    ]
    var drag_dir = (end - start).normalized()
    var best_ind = 0
    var best_dot = 0
    var best_orth_ind = 0
    for ind in range(len(directions)):
        var curr_dot = drag_dir.dot(directions[ind])
        if curr_dot > best_dot and ind < 4:
            best_orth_ind = ind
        if curr_dot > best_dot:
            best_dot = curr_dot
            best_ind = ind
    var draw_dir = directions[best_ind]
    var edges : Array
    if start == end:
        edges = [[[0,0,0,0]],[start]]
    elif best_ind < 4:
        edges = edges_ortho(start, end, draw_dir)
    elif best_ind < 8:
        edges = edges_diag(start, end, draw_dir)
    elif best_ind < 16:
        edges = edges_far2(start, end, draw_dir)
    elif abs(start.x-end.x) * abs(start.y-end.y) > 15:
        edges = edges_far3(start, end, draw_dir)
    else:
        draw_dir = directions[best_orth_ind]
        edges = edges_ortho(start, end, draw_dir)
    """
    Allright, here I have the basic edges per location with edges[0] containing edges and edges[1] containing locations
    Now I need to interact this with existing tiles, for this I want two options, one with existing-first one with drag-first
    This would allow for a key-hold, for instance CRTL to set the mode to which edge is considered more important
    """
    # combine edges with existing
    var intersect_ind = []
    for loc_i in range(len(edges[1])):
        var loc = edges[1][loc_i]
        var edge_e = _existing_edges(loc)
        if edge_e != null:
            var edge_d = edges[0][loc_i]
            var edge_res = []
            if self.drag_first:
                for i in range(len(edge_d)):
                    if edge_d[i] == 0:
                        edge_res.append(edge_e[i])
                    else:
                        edge_res.append(edge_d[i])
            else:
                for i in range(len(edge_d)):
                    if edge_e[i] == 0:
                        edge_res.append(edge_d[i])
                    else:
                        edge_res.append(edge_e[i])
            var buff = edges[0].duplicate()
            buff[loc_i] = edge_res.duplicate()
            edges[0] = buff.duplicate()
            intersect_ind.append(loc_i)
            
    var neighbors = [Vector2(-1, 0), Vector2(0, -1), Vector2(1, 0), Vector2(0, 1)]
    # iter over the intersection points
    for int_i in intersect_ind:
        var edge_base = edges[0][int_i].duplicate()
        # if intersection needs diagonals to be adjusted
        if not self.transit_tiles[type].has(edge_base):
            var loc_to_fix = [edges[1][int_i]]
            var edge_ind_affected = []
            # while there is locations to fix, fix them
            while len(loc_to_fix) > 0:
                # get first in list and remove it from list
                var loc_fix = loc_to_fix[0]
                loc_to_fix.erase(loc_fix)
                # get the edge numbers
                var edge_fix
                if loc_fix in edges[1]:
                    var ind = edges[1].find(loc_fix)
                    edge_fix = edges[0][ind].duplicate()
                else:
                    var existing = _existing_edges(loc_fix)
                    # The recursion reached a cell with nothing on it. That was
                    # impossible while the tile set only ever grew, but a
                    # bulldoze can now take a tile out from under it.
                    if existing == null:
                        continue
                    edge_fix = existing.duplicate()
                # edge_ind_affected starts with length 0
                if not len(edge_ind_affected) == 0:
                    # get the first in list and remove it from list
                    var edge_aff = edge_ind_affected[0]
                    edge_ind_affected.erase(edge_aff)
                    # update the affected edge
                    if edge_fix[edge_aff] == 1 or edge_fix[edge_aff] == 3:
                        edge_fix[edge_aff] += 10
                        var affected_loc = neighbors[edge_aff] + loc_fix
                        # calculate and add new affected edge values to the lists
                        var n_i = (edge_aff+2)%4
                        var n_edge 
                        if edges[1].has(affected_loc):
                            var n_ind = edges[1].find(affected_loc)
                            n_edge = edges[0][n_ind]
                        else:
                            n_edge = _existing_edges(affected_loc)
                        # only add the neighbor if the affected edge wasn't fixed yet
                        if n_edge != null and (n_edge[n_i] == 1 or n_edge[n_i] == 3):
                            loc_to_fix.append(affected_loc)
                            edge_ind_affected.append(n_i)
                # only do the below if the above did not produce a valid edge-set
                if not self.transit_tiles[type].has(edge_fix):
                    var diag_inds = []
                    # get the diagonals not yet changed, might need to change for rails as they have more edges
                    for e in range(len(edge_fix)):
                        if edge_fix[e] == 1 or edge_fix[e] == 3:
                            diag_inds.append(e)
                    # generate every combination of diagonal-edge-updates
                    var options = []
                    for i in range(len(diag_inds)):
                        options.append([diag_inds[i]])
                    for i in range(len(diag_inds)):
                        for j in range(len(options)):
                            if diag_inds[i] > options[j][0]:
                                var option = options[j].duplicate()
                                option.append(diag_inds[i])
                                options.append(option.duplicate())
                    # the above might not work, and was adding null values instead of edge combinations
                    # go over the options
                    for option in options:
                        var edge_option = edge_fix.duplicate()
                        # generate the change the option is set to make
                        for i in range(len(option)):
                            if edge_option[option[i]] == 1 or edge_option[option[i]] == 3:
                                edge_option[option[i]] +=10
                        # if option is valid
                        if self.transit_tiles[type].has(edge_option):
                            # go over the options changes and add affected neighbors
                            for i in range(len(option)):
                                var opt_i = option[i]
                                var affected_loc = neighbors[opt_i] + loc_fix
                                var n_i = (opt_i+2)%4
                                var n_edge 
                                if edges[1].has(affected_loc):
                                    var n_ind = edges[1].find(affected_loc)
                                    n_edge = edges[0][n_ind]
                                else:
                                    n_edge = _existing_edges(affected_loc)
                                # only add the neighbor if the affected edge wasn't fixed yet
                                if n_edge != null and (n_edge[n_i] == 1 or n_edge[n_i] == 3):
                                    loc_to_fix.append(affected_loc)
                                    edge_ind_affected.append(n_i)
                            # check if the fixed tile is in edges(could be a built tile)
                            if edges[1].has(loc_fix):
                                var ind = edges[1].find(loc_fix)
                                var edge_buff = edges[0].duplicate()
                                edge_buff[ind] = edge_option.duplicate()
                                edges[0] = edge_buff.duplicate()
                            # if not yet in edges just add it as the build_network then overrides the existing tiles
                            else:
                                var edge_buff = edges[0].duplicate()
                                edge_buff.append(edge_option.duplicate())
                                edges[0] = edge_buff.duplicate()
                                var loc_buff = edges[1].duplicate()
                                loc_buff.append(loc_fix)
                                edges[1] = loc_buff.duplicate()
                            break
                else:
                    if edges[1].has(loc_fix):
                        var ind = edges[1].find(loc_fix)
                        var edge_buff = edges[0].duplicate()
                        edge_buff[ind] = edge_fix.duplicate()
                        edges[0] = edge_buff.duplicate()
                    # if not yet in edges just add it as the build_network then overrides the existing tiles
                    else:
                        var edge_buff = edges[0].duplicate()
                        edge_buff.append(edge_fix.duplicate())
                        edges[0] = edge_buff.duplicate()
                        var loc_buff = edges[1].duplicate()
                        loc_buff.append(loc_fix)
                        edges[1] = loc_buff.duplicate()
                    break
    """
    Now that all edges are valid 
    I should go over the various options per location and find the tile that best fits the surroundings
    To do this I need a structure that translates the neighbour indicator in 2 and 3-lines into vectors
        neigh_num_to_vec does this ^^
    """
    # check
    var tile_arr = []
    var overridden = []
    var overrider = []
    for i in range(len(edges[0])):
        var best_score = 0
        var best_points = 0
        var best_t_i = 0
        var b_loc = edges[1][i]
        var override = false
        for t_i in range(len(transit_tiles[type][edges[0][i]])):
            var points = 0
            var div = 0
            for line in transit_tiles[type][edges[0][i]][t_i].edges.keys():
                div += 1
                var vec = neigh_num_to_vec[line]
                var loc = b_loc + vec
                # The save's tiles count as neighbours here too, or a variant
                # that wants a road to its east scores no better next to one of
                # the save's roads than next to bare ground.
                if edges[1].has(loc) or _has_existing(loc):
                    points += 1
            var score : float = float(points)/float(div)
            if (score > best_score) or (score == best_score and points > best_points):
                best_score = score
                best_points = points
                best_t_i = t_i
                if len(transit_tiles[type][edges[0][i]][t_i].ids) > 1:
                    override = true
                else:
                    override = false
        tile_arr.append(transit_tiles[type][edges[0][i]][best_t_i])
        if override and not b_loc in overridden:
            overrider.append(b_loc)
            for sub in transit_tiles[type][edges[0][i]][best_t_i].ids.keys():
                if sub != 0:
                    var loc = b_loc + neigh_num_to_vec[sub]
                    overridden.append(loc)
    """
    now I need to generate normals, uvs, vertices, uv2-layer_indices and colors and add them to the arrays
    and generate and register the network tiles to drag_tiles
    
    first step is generate vertices and smoothen them
    """
    # determine the edges that best match the perpendicular to the draw direction
    var best_perp
    var best_score_perp = 1
    for x in range(-1, 2):
        for y in range(-1, 2):
            var curr_vec = Vector2(x, y).normalized()
            if x != 0 or y != 0:
                var curr_score = abs(draw_dir.dot(curr_vec))
                if curr_score < best_score_perp:
                    best_score_perp = curr_score
                    best_perp = curr_vec
    var matches = []
    var first_step = null
    var last_step = null
    var step_length = 1
    # sqrt(2.0)/2.0 reasoning:
    #	x--x
    #	|\ |\
    #	| \| \
    #	x--x--x
    # sides are length 1, diagonal is sqrt(1^2 + 1^2) = sqrt(2)
    # distance between diagonals is half of that so sqrt(2.0)/2.0
    if best_perp.x == best_perp.y:
        step_length = sqrt(2.0)/2.0
        matches = [2,0]
        first_step = [3]
        last_step = [1]
        if draw_dir.x > 0:
            matches = [0,2]
            first_step = [1]
            last_step = [3]
    elif best_perp.x == -best_perp.y:
        step_length = sqrt(2.0)/2.0
        matches = [3,1]
        first_step = [0]
        last_step = [2]
        if draw_dir.x < 0:
            matches = [1,3] # to ensure counter-clockwise order
            first_step = [2]
            last_step = [0]
    elif best_perp.x != 0:
        first_step = [0,3]
        matches = [1,2]
        if draw_dir.y < 0:
            first_step = [2,1]
            matches = [3,0]
            
    else:
        first_step = [0,1]
        matches = [3,2]
        if draw_dir.x < 0:
            first_step = [2,3]
            matches = [1,0]
    # use the match
    var corners = [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]
    var strip_heights = []
    if first_step != null:
        var height = 0
        for c_i in range(len(first_step)):
            var vec = edges[1][0] + corners[first_step[c_i]]
            height += heightmap[vec.y][vec.x]
        strip_heights.append(height/len(first_step))
    for loc_i in range(len(edges[1])):
        var height = 0
        for c_i in matches:
            var vec = edges[1][loc_i] + corners[c_i]
            height += heightmap[vec.y][vec.x]
        strip_heights.append(height/2.0)
    var height = 0
    if last_step != null:
        for c_i in range(len(last_step)): # need to use range(len()) because the array can be length 1 which godot derps on
            var vec = edges[1][-1] + corners[last_step[c_i]]
            height += heightmap[vec.y][vec.x]
        strip_heights.append(height/len(last_step))
    var MaxNetworkSlopeChange = 35.0 #degrees
    var MaxSlopeAlongNetwork = 35.0 #degrees
    var MaxNetworkHtAdjustment = 10.0/16.0
    var numSmoothingProgressionSteps = 2
    #var distAddedPerSmoothingProgressionStep = 4 # idk, i guess its supposed to take the average of more tiles?
    """
    var max_height_change = tan(deg_to_rad(MaxSlopeAlongNetwork))*step_length
    var max_slope_change = tan(deg_to_rad(MaxNetworkSlopeChange))*step_length
    for _step in range(numSmoothingProgressionSteps):
        for h_i in range(len(strip_heights)):
            var from = strip_heights[max(h_i-1, 0)]
            var curr = strip_heights[h_i]
            var to = strip_heights[min(h_i+1, len(strip_heights)-1)]
            var slope = curr-to
            var change = abs((from-curr) - (curr-to))
            if abs(slope) > max_height_change or change > max_slope_change:
                var average = (from+curr+to)/3.0
                var step_height = 0.5 * (average-curr)
                curr += min(step_height, MaxNetworkHtAdjustment)
                strip_heights[h_i] = curr
    """
    """
    I should have smooth heights now, next is to turn them into vertices
    corner heights would be i, i+1, i+1, i+2 for diagonals
    """
    # step_seq stores the index offset per corner-index
    var step_seq = {}
    var counter = 0
    if first_step != null:
        for step in range(len(first_step)):
            step_seq[first_step[step]] = counter
        counter += 1
    for step in matches:
        step_seq[step] = counter
    counter += 1
    if last_step != null:
        for step in range(len(last_step)):
            step_seq[last_step[step]] = counter
    var vecadd = [0,3,1,1,3,2]
    if(best_perp.x == -best_perp.y):
            vecadd = [1,0,2,2,0,3]
    #print(step_seq, draw_dir, best_perp)
    #print(strip_heights)
    var corner_uvs = [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]
    # yellow transparent color for dragged network
    var col = Color(1.0, 1.0, 0.1, 0.7)
    for h_i in range(len(edges[1])):
        var tile = tile_arr[h_i]
        if not edges[1][h_i] in overridden:
            for sub_tile in tile.ids.keys():
                if tile.text_arr_layers.keys().has(sub_tile):
                    var rot = tile.ids[sub_tile][1] # for multi-tile dragging there needs to be additional rot and flip added
                    var flip = tile.ids[sub_tile][2] # since multi tile base-pieces presume we generate additional rot and flip
                    var layer = tile.text_arr_layers[sub_tile] # TODO^^
                    var layr_l = 0xFF & layer
                    var layr_a = (0xFF00 & layer)>>8
                    var layer_vec = Vector2(layr_l, layr_a)
                    var rot_uvs = []
                    for i in range(rot, 4+rot, 1):
                        rot_uvs.append(corner_uvs[i%4])
                    var flip_uvs = []
                    if flip == 1:
                        flip_uvs.append(rot_uvs[3])
                        flip_uvs.append(rot_uvs[2])
                        flip_uvs.append(rot_uvs[1])
                        flip_uvs.append(rot_uvs[0])
                    else:
                        flip_uvs = rot_uvs
                    var normal_verts = []
                    var sub_vec = edges[1][h_i] + neigh_num_to_vec[sub_tile]
                    # Kept so the ground quad under this tile can be the same
                    # six vertices dropped to BASE_LIFT -- reconstructing them
                    # from the cell would lose the solver's per-corner heights
                    # and float off a sloped road. See _rebuild_base_mesh.
                    var quad_verts : Array = []
                    var quad_uvs : Array = []
                    for vec_i in range(6):
                        var vec = sub_vec + corners[vecadd[vec_i]]
                        var vec_ht = strip_heights[h_i + step_seq[vecadd[vec_i]]]
                        self.drag_arrays[ArrayMesh.ARRAY_VERTEX].append(Vector3(vec.x, vec_ht/16.0 + SURFACE_LIFT, vec.y))
                        self.drag_arrays[ArrayMesh.ARRAY_TEX_UV].append(flip_uvs[vecadd[vec_i]])
                        self.drag_arrays[ArrayMesh.ARRAY_COLOR].append(col)
                        self.drag_arrays[ArrayMesh.ARRAY_TEX_UV2].append(layer_vec)
                        self.drag_tracker.append(sub_vec)
                        normal_verts.append(Vector3(vec.x, vec_ht/16.0 + SURFACE_LIFT, vec.y))
                        quad_verts.append(Vector3(vec.x, vec_ht/16.0 + BASE_LIFT, vec.y))
                        quad_uvs.append(corner_uvs[vecadd[vec_i]])
                    drag_quads[sub_vec] = {"verts": quad_verts, "uvs": quad_uvs}
                    # vecadd = [0,3,1,1,3,2] or [1,0,2,2,0,3]
                    # indices   0 1 2 3 4 5		 0 1 2 3 4 5
                    # ind 1 == 4 is used as the anchors
                    # 2 to 0 and 5 to 3 results in counter-clockwise order for both
                    # u.cross(v), not v.cross(u). Both triangle windings here
                    # are counter-clockwise seen from above, so v.cross(u) is
                    # the DOWNWARD face normal: for the flat case it works out
                    # to (0, -1, 0) for every triangle of both vecadd
                    # orderings. A road lit from a sun overhead by a normal
                    # pointing at the ground gets no diffuse term at all, and
                    # City.tscn's environment takes its ambient from a
                    # background whose energy multiplier is 0 -- which is why
                    # drawn roads rendered solid black while their geometry,
                    # UVs and texture layer were all correct.
                    var v = normal_verts[2] - normal_verts[1]
                    var u = normal_verts[0] - normal_verts[1]
                    var normal1 : Vector3 = u.cross(v).normalized()
                    v  = normal_verts[5] - normal_verts[4]
                    u  = normal_verts[3] - normal_verts[4]
                    var normal2 : Vector3 = u.cross(v).normalized()
                    for norm in [normal1, normal2]:
                        for _face_vert in range(3):
                            self.drag_arrays[ArrayMesh.ARRAY_NORMAL].append(norm)
        self.drag_tiles[edges[1][h_i]] = NetTile.new(edges[1][h_i], edges[0][h_i], tile, draw_dir)
    if len(self.drag_arrays[ArrayMesh.ARRAY_VERTEX]) > 0:
        var drag_array_mesh = ArrayMesh.new()
        drag_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, get_mesh_arrays(self.drag_arrays))
        drag_meshinst.mesh = drag_array_mesh
    """
    TODO 
    x diagonal intersections are bugged - done
    x situations where a neighbor is attempted to update into an imcompatible shape, should check the neighbors other diagonals before discaring
        and if another diagonal needs changing, it should do a recursion, so I should make a function that calls itself. - fixed
    - multi-tile networking
    - smoothening for built tiles - means smoothening should be 2-d
      - need to lock the heights of intersections and direction changes? maybe the 2d height update is enough
      - for tiles with locked perpendicularness I either need to add foundation or make the built one set the height for the drag
      - the perpendicular flatness could be optional
      - snapping to heights of parallel tiles could be optional
      - could do three modes: BuiltFirst, DragFirst, Foundations where foundations makes it pick its own heights
    - transform terrain
      - have the permanence of terrain transformation be optional
      - add foundation logic: if delta_height > someval: do foundations
    x implement drag vs built prio toggle - done
    - Verticality and viaducts
    """
    
func _build_network():#start, end, type):
    "TODO Register tiles to network_tiles and figure out how to copy PackedVector3Array"
    if len(self.drag_arrays[ArrayMesh.ARRAY_VERTEX]) > 0:
        var debug = false
        if self.mesh == null:
            self.mesh = ArrayMesh.new()
        if len(self.built_arrays) == 0:
            self.built_arrays = []
            self.built_arrays.resize(ArrayMesh.ARRAY_MAX)
        var built = Vector2(0, 128) # used to swap from yellow color to basic with tile colors
        var verts_to_terrain = PackedVector3Array(self.drag_arrays[ArrayMesh.ARRAY_VERTEX])
        var UVs_to_terrain = PackedVector2Array(self.drag_arrays[ArrayMesh.ARRAY_TEX_UV])
        # Terrain deformation is off. Terrain.update_terrain() pulls the ground
        # up to the road and, in doing so, hands the terrain shader the ROAD's
        # UV2 layer indices -- which are indices into the transit texture array,
        # not the terrain one -- so the strip under every drawn road rendered
        # solid black. Roads are lifted clear of the ground instead (see
        # SURFACE_LIFT), which is what City.gd already does for the save's own
        # network quads. Re-enabling this needs update_terrain to keep the
        # terrain's own UVs; the vertices are still computed above so the call
        # can come back unchanged.
        #self.get_parent().get_node("Terrain").update_terrain(verts_to_terrain, UVs_to_terrain)
        for i in len(self.drag_arrays):
            if self.built_arrays[i] == null and not self.drag_arrays[i] == null:
                self.built_arrays[i] = []
            if not self.drag_arrays[i] == null:
                for j in range(0, len(self.drag_arrays[i]), 6):
                    var found = self.built_tracker.find(self.drag_tracker[j])
                    if found == -1:
                        for k in range(6):
                            if i == ArrayMesh.ARRAY_TEX_UV2:
                                self.built_arrays[i].append(self.drag_arrays[i][j+k]+built)
                            else:
                                self.built_arrays[i].append(self.drag_arrays[i][j+k])
                    else:
                        for k in range(6):
                            if i == ArrayMesh.ARRAY_TEX_UV2:
                                self.built_arrays[i][found+k] = self.drag_arrays[i][j+k]+built
                            else:
                                self.built_arrays[i][found+k] = self.drag_arrays[i][j+k]
        
        if self.mesh.get_surface_count() > 0:
            self.mesh.surface_remove(0)
        self.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, get_mesh_arrays(self.built_arrays))
    self.drag_arrays = []
    if drag_meshinst.mesh != null and drag_meshinst.mesh.get_surface_count() > 0:
        drag_meshinst.mesh.surface_remove(0)
    for key in self.drag_tiles.keys():
        self.network_tiles[key] = self.drag_tiles[key]
    self.drag_tiles = {}
    for j in range(0, len(self.drag_tracker), 6):
        var found = self.built_tracker.find(self.drag_tracker[j])
        if found == -1:
            for k in range(6):
                self.built_tracker.append(self.drag_tracker[j+k])
        else:
            for k in range(6):
                self.built_tracker[found+k] = self.drag_tracker[j+k]

func get_mesh_arrays(arrays):
    var ret_array = []
    ret_array.resize(ArrayMesh.ARRAY_MAX)
    ret_array[ArrayMesh.ARRAY_VERTEX] = PackedVector3Array(arrays[ArrayMesh.ARRAY_VERTEX])
    ret_array[ArrayMesh.ARRAY_NORMAL] = PackedVector3Array(arrays[ArrayMesh.ARRAY_NORMAL])
    ret_array[ArrayMesh.ARRAY_COLOR] = PackedColorArray(arrays[ArrayMesh.ARRAY_COLOR])
    ret_array[ArrayMesh.ARRAY_TEX_UV] = PackedVector2Array(arrays[ArrayMesh.ARRAY_TEX_UV])
    ret_array[ArrayMesh.ARRAY_TEX_UV2] = PackedVector2Array(arrays[ArrayMesh.ARRAY_TEX_UV2])
    return ret_array

func get_uvs(rot : int, flip : int):
    """
    rotations are declared as clockwise, godot requires counter-clockwise vertex declaration
    since flip->rotate =/= rotate->flip and rotations come first in the 3-line declaration
      I will assume rotation is applied before flipping
    as flip is a bool that doesn't specify the axis to flip along I will assume it flips "horizontally" 
                                                along the v axis flipping the u coordinates ^^
    
    so a rotate=3, flip=1 would perform:
            rot		flip
        1-4		4-3		3-4
        | |  ->	| |  ->	| |
        2-3		1-2		2-1
    """
    var corner_uvs = [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]
    var rot_uvs = []
    for i in range(rot, 4+rot, 1):
        rot_uvs.append(corner_uvs[i%4])
    var flip_uvs = []
    if flip == 1:
        flip_uvs.append(rot_uvs[3])
        flip_uvs.append(rot_uvs[2])
        flip_uvs.append(rot_uvs[1])
        flip_uvs.append(rot_uvs[0])
    else:
        flip_uvs = rot_uvs
    # will need to use the same order when assigning vectors
    var ret_uvs = PackedVector2Array([
        flip_uvs[0],
        flip_uvs[2],
        flip_uvs[1],
        flip_uvs[0],
        flip_uvs[3],
        flip_uvs[2]
    ])
    return ret_uvs
    
func edges_ortho(start: Vector2, end: Vector2, draw_dir: Vector2) -> Array:
    #print("ortho")
    var curr_tile = start
    var ret_edges = []
    var ret_locations = []
    var half_d = draw_dir/2
    var e_key = [int(2 * abs(floor(half_d.x))), int(2 * abs(floor(half_d.y))), int(2 * ceil(half_d.x)), int(2 * ceil(half_d.y))]
    ret_edges.append(e_key.duplicate())
    ret_locations.append(curr_tile)
    curr_tile += draw_dir
    while (curr_tile.x * abs(draw_dir.x)) != end.x and (curr_tile.y * abs(draw_dir.y)) != end.y:
        # use edge values as keys, 2 means orthogonal edge
        e_key = [int(2*abs(draw_dir.x)), int(2*abs(draw_dir.y)), int(2*abs(draw_dir.x)), int(2*abs(draw_dir.y))]
        # add edge to dict if its not in there
        ret_edges.append(e_key.duplicate())
        ret_locations.append(curr_tile)
        # find best next tile
        curr_tile += draw_dir
    e_key = [int(2 * ceil(half_d.x)), int(2 * ceil(half_d.y)), int(2 * abs(floor(half_d.x))), int(2 * abs(floor(half_d.y)))]
    ret_edges.append(e_key.duplicate())
    ret_locations.append(curr_tile)
    return [ret_edges, ret_locations]
    
func edges_diag(start: Vector2, end: Vector2, draw_dir: Vector2) -> Array:
    #print("diag")
    # two ways to start:
    #	| /|	|  |
    #	|/ |	| /|
    #	|__|	|/_|

    # Vector2(.7, .7), 	->	[3, 0, 0, 1]	alt	[0, 1, 3, 0]	start[0, 0, 0, 1]	alt[0, 0, 3, 0]
    # Vector2(-.7, .7),	->	[0, 0, 1, 3]	alt	[1, 3, 0, 0]	start[0, 0, 0, 3]	alt[1, 0, 0, 0]
    # Vector2(-.7, -.7),->	[0, 1, 3, 0]	alt	[3, 0, 0, 1]	start[0, 1, 0, 0]	alt[3, 0, 0, 0]
    # Vector2(.7, -.7),	->	[1, 3, 0, 0]	alt	[0, 0, 1, 3]	start[0, 3, 0, 0]	alt[0, 0, 1, 0]
    # 1 = \ , 3 = /
    var curr_tile = start
    var ret_edges = []
    var ret_locations = []
    var edges_sets = [[
        int(abs(ceil(draw_dir.x) * 			(1+2*ceil(draw_dir.y)))), 
        int(abs(abs(floor(draw_dir.y)) * 	(1+2*ceil(draw_dir.x)))), 
        int(abs(abs(floor(draw_dir.x)) * 	(1+2*abs(floor(draw_dir.y))))), 
        int(abs(ceil(draw_dir.y) * 			(1+2*abs(floor(draw_dir.x)))))
    ],[
        int(abs(abs(floor(draw_dir.x)) * 	(1+2*abs(floor(draw_dir.y))))), 
        int(abs(ceil(draw_dir.y) * 			(1+2*abs(floor(draw_dir.x))))), 
        int(abs(ceil(draw_dir.x) * 			(1+2*ceil(draw_dir.y)))), 
        int(abs(abs(floor(draw_dir.y)) * 	(1+2*ceil(draw_dir.x))))
    ]]
    var curr_edges_i = 0
    if abs((end - start).x) > abs((end - start).y):
        curr_edges_i = 1
        
    # handle start, it uses s_key because setting values to e_key were overriding things
    var s_key = [0,0,0,0]
    if curr_edges_i == 0:
        s_key[0] = 0
        s_key[1] = edges_sets[curr_edges_i][1]
        s_key[2] = 0
        s_key[3] = edges_sets[curr_edges_i][3]
    else:
        s_key[0] = edges_sets[curr_edges_i][0]
        s_key[1] = 0
        s_key[2] = edges_sets[curr_edges_i][2]
        s_key[3] = 0
    ret_edges.append(s_key.duplicate())
    ret_locations.append(curr_tile)
    curr_tile += Vector2(round(draw_dir.x)*curr_edges_i, round(draw_dir.y)*(1-curr_edges_i))
    curr_edges_i = (curr_edges_i+1)%2
    
    # this iters the range, since for diagonals abs(x) == abs(y) these simple != checks work
    while curr_tile.x != end.x and curr_tile.y != end.y:
        var e_key = edges_sets[curr_edges_i]
        # add edge to dict if its not in there
        ret_edges.append(e_key.duplicate())
        ret_locations.append(curr_tile)
        curr_tile += Vector2(round(draw_dir.x)*curr_edges_i, round(draw_dir.y)*(1-curr_edges_i))
        # 2%2=0, 1%2=1 so this toggles between 0 and 0
        curr_edges_i = (curr_edges_i+1)%2
    
    # handle end, it uses s_key because setting values to e_key were overriding things
    var f_key = [0,0,0,0]
    if curr_edges_i == 1:
        f_key[0] = 0
        f_key[1] = edges_sets[curr_edges_i][1]
        f_key[2] = 0
        f_key[3] = edges_sets[curr_edges_i][3]
    else:
        f_key[0] = edges_sets[curr_edges_i][0]
        f_key[1] = 0
        f_key[2] = edges_sets[curr_edges_i][2]
        f_key[3] = 0
    ret_edges.append(f_key.duplicate())
    ret_locations.append(curr_tile)
    return [ret_edges, ret_locations]
    
func edges_far2(start : Vector2, end : Vector2, draw_dir : Vector2) -> Array:
    #print("far2")
    var curr_tile = start
    var ret_edges = []
    var ret_locations = []
    var main_vec : Vector2
    var sec_vec : Vector2
    if abs(draw_dir.x) > abs(draw_dir.y):
        if draw_dir.x > 0:
            main_vec = Vector2(1, 0)
        else:
            main_vec = Vector2(-1, 0)
        if draw_dir.y > 0:
            sec_vec = Vector2(0, 1)
        else:
            sec_vec = Vector2(0, -1)
    else:
        if draw_dir.y > 0:
            main_vec = Vector2(0, 1)
        else:
            main_vec = Vector2(0, -1)
        if draw_dir.x > 0:
            sec_vec = Vector2(1, 0)
        else:
            sec_vec = Vector2(-1, 0)
    # starts with double straight step to assist the transition
    #          3->4
    #	        \\
    #    3->4->1->2
    #     \\
    # 0->1->2
    var tile_steps = [
        main_vec,
        main_vec,
        sec_vec-main_vec,
        main_vec,
    ]
    var edge_steps = [
        [int(2*abs(main_vec.x)), 	    int(2*abs(main_vec.y)), 			int(2*abs(main_vec.x)), 			int(2*abs(main_vec.y))],
        [int(2*abs(main_vec.x)), 	    int(2*abs(main_vec.y)), 			int(2*abs(main_vec.x)), 			int(2*abs(main_vec.y))],
        # bottom two lines use min and max to convert pos/neg dir into 0 edges where needed
        [int(2*max(main_vec.x, 0)), 	int(2*max(main_vec.y,0)), 			int(2*abs(min(main_vec.x, 0))), 	int(2*abs(min(main_vec.y, 0)))],
        [int(2*abs(min(main_vec.x, 0))),int(2*abs(min(main_vec.y, 0))), 	int(2*max(main_vec.x, 0)), 			int(2*max(main_vec.y, 0))],
    ]
    var step = 0
    var goal = end.x
    var curr = curr_tile.x
    var x_first = true
    if round(abs(draw_dir.x)) == 0:
        goal = end.y
        curr = curr_tile.y
        x_first = false
    var e_key = edge_steps[3]
    ret_edges.append(e_key.duplicate())
    ret_locations.append(curr_tile)
    curr_tile += tile_steps[step]
    while curr != goal:
        e_key = edge_steps[step]
        if abs(curr - goal) == 1:
            e_key = edge_steps[0]
            step = (step + (len(tile_steps)-1))%len(tile_steps)
        # add edge to dict if its not in there
        ret_edges.append(e_key.duplicate())
        ret_locations.append(curr_tile)
        curr_tile += tile_steps[step]
        step = (step + 1)%len(tile_steps)
        if x_first:
            curr = curr_tile.x
        else:
            curr = curr_tile.y
    e_key = edge_steps[2]
    ret_edges.append(e_key.duplicate())
    ret_locations.append(curr_tile)
    curr_tile += tile_steps[step]
    return [ret_edges, ret_locations]
    
func edges_far3(start: Vector2, end: Vector2, draw_dir: Vector2) -> Array:
    #print("far3")
    var curr_tile = start
    var ret_edges = []
    var ret_locations = []
    var main_vec : Vector2
    var sec_vec : Vector2
    var starting = true
    if abs(draw_dir.x) > abs(draw_dir.y):
        if draw_dir.x > 0:
            main_vec = Vector2(1, 0)
        else:
            main_vec = Vector2(-1, 0)
        if draw_dir.y > 0:
            sec_vec = Vector2(0, 1)
        else:
            sec_vec = Vector2(0, -1)
    else:
        if draw_dir.y > 0:
            main_vec = Vector2(0, 1)
        else:
            main_vec = Vector2(0, -1)
        if draw_dir.x > 0:
            sec_vec = Vector2(1, 0)
        else:
            sec_vec = Vector2(-1, 0)
    # starts with double straight step to assist the transition
    #             4->5->6->7
    #	           \---\
    #    4->5->6->1->2->3
    #     \---\
    # 0->1->2->3
    var tile_steps = [
        main_vec,
        main_vec,
        main_vec,
        sec_vec-(main_vec*2),
        main_vec,
        main_vec,
    ]
    
    #  = = = >
    #    < =
    var edge_steps = [
        [int(2*abs(main_vec.x)), 		int(2*abs(main_vec.y)), 		int(2*abs(main_vec.x)), 		int(2*abs(main_vec.y))],
        [int(2*abs(main_vec.x)), 		int(2*abs(main_vec.y)), 		int(2*abs(main_vec.x)), 		int(2*abs(main_vec.y))],
        [int(2*abs(main_vec.x)), 		int(2*abs(main_vec.y)), 		int(2*abs(main_vec.x)), 		int(2*abs(main_vec.y))],
        # bottom two lines use min and max to convert pos/neg dir into 0 edges where needed
        [int(2*max(main_vec.x, 0)), 	int(2*max(main_vec.y,0)), 		int(2*abs(min(main_vec.x, 0))), int(2*abs(min(main_vec.y, 0)))],
        [int(2*abs(min(main_vec.x, 0))),int(2*abs(min(main_vec.y, 0))), int(2*max(main_vec.x, 0)), 		int(2*max(main_vec.y, 0))],
        [int(2*abs(main_vec.x)), 		int(2*abs(main_vec.y)), 		int(2*abs(main_vec.x)), 		int(2*abs(main_vec.y))],
    ]
    var step = 0
    var goal = end.x
    var curr = curr_tile.x
    var x_first = true
    if round(abs(draw_dir.x)) == 0:
        goal = end.y
        curr = curr_tile.y
        x_first = false
    var e_key = edge_steps[4]
    ret_edges.append(e_key.duplicate())
    ret_locations.append(curr_tile)
    curr_tile += tile_steps[step]
    while curr != goal:
        e_key = edge_steps[step]
        # this if-elif chain makes the first and last segment have far-to-ortho transitions
        # might want to make this more flexible to incorporate more/all transitions
        if step == 1 and starting:
            e_key = edge_steps[3]
        elif step == 2 and starting:
            e_key = edge_steps[4]
            starting = false
        elif abs(curr - goal) < 7 and step == 5:
            e_key = edge_steps[3]
        elif abs(curr - goal) < 6 and step == 0:
            e_key = edge_steps[4]
        elif abs(curr - goal) < 3:
            e_key = edge_steps[0]
            step-=1
        # add edge to dict if its not in there
        ret_edges.append(e_key.duplicate())
        ret_locations.append(curr_tile)
        curr_tile += tile_steps[step]
        step = (step + 1)%len(tile_steps)
        if x_first:
            curr = curr_tile.x
        else:
            curr = curr_tile.y
    e_key = edge_steps[3]
    ret_edges.append(e_key.duplicate())
    ret_locations.append(curr_tile)
    return [ret_edges, ret_locations]
