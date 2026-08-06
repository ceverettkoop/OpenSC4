extends Node3D

var size_w : int = 4
var size_h : int = 4
var rng : RandomNumberGenerator = RandomNumberGenerator.new()
var savefile
var width
var height
var city_name : String
var city_path : String
var region_name : String
const TILE_SIZE : int = 16
const WATER_HEIGHT : float = 250.0 / TILE_SIZE
# stores where tiles are in the vertex, uv and normal arrays
var terr_tile_ind = {}
# heightmap (metres) kept for building placement; indexed [z][x] like the terrain build
var height_map : Array = []
# translator from fsh-iid to texturearray layer
var ind_layer
# for cursor
var cur_img
var vec_hot

func _ready():
    rng.randomize()
    savefile = Boot.current_city
    city_name = Boot.current_city_name
    city_path = Boot.current_city_path
    region_name = Boot.current_region_name
    create_terrain()
    set_cursor()
    pass

func gen_random_terrain(width : int, height : int) -> Array:
    var heightmap : Array = []
    var noise = FastNoiseLite.new()
    noise.seed = randi()
    noise.octaves = 1
    noise.period = 20
    noise.persistence = 0.8
    for i in range(width):
        heightmap.append([])
        for j in range(height):
            var h = WATER_HEIGHT * TILE_SIZE + (noise.get_noise_2d(i, j) * 200 )
            heightmap[i].append(h)
    return heightmap

func load_city_terrain(svfile : DBPF):
    var heightmap : Array = []
    var city_info = svfile.get_subfile(0xca027edb, 0xca027ee1, 0, SC4ReadRegionalCity)
    var terrain_info = svfile.get_subfile(0xa9dd6ff4, 0xe98f9525, 00000001, cSTETerrain__SaveAltitudes)
    size_w = city_info.size[0]
    size_h = city_info.size[1]
    self.width = size_w * 64 + 1
    self.height = size_h * 64 + 1
        
    terrain_info.set_dimensions(self.width, self.height)
    for i in range(width):
        heightmap.append([])
        for j in range(self.height):
            heightmap[i].append(terrain_info.get_altitude(i, j))
    self.get_node("Node3D/Terrain").heightmap = heightmap
    return heightmap

#(0, 0)       (1, 0)
#	    0 - 3
#	    | \ |
#       1 - 2
#(0, 1)       (1, 1)
func create_face(v0 : Vector3, v1 : Vector3, v2 : Vector3, v3 : Vector3, heightmap):
    """
    TODO:
        swap from surface normals to verex normals to make godot smoothen out edges
        
    """
    var v : Vector3 = v1 - v0
    var u1 : Vector3 = v2 - v0
    var u2 : Vector3 = v3 - v1
    var w1 : Vector3 = v3 - v0
    var w2 : Vector3 = v3 - v2
    var normal1 : Vector3 = v.cross(u1).normalized()
    var normal2 : Vector3 = u1.cross(w1).normalized()
    var normal3 : Vector3 = v.cross(u2).normalized()
    var normal4 : Vector3 = u2.cross(w2).normalized()
    var uvs = []
    var normalz = []
    var layer_ind = []
    var layer_weights = []
    var vertex_layers = []
    var vertex_weights = []
    for i in range(4):
        var vert = [v0, v1, v2, v3][i]
        var res = coord_to_uv(vert.x, vert.y, vert.z)
        uvs.append(res[0])
        if heightmap:
            var weight = [0.0, 0.0, 0.0, 0.0]
            weight[i] = 1.0
            vertex_layers.append(res[1])
            vertex_weights.append([weight[0], weight[1], weight[2], weight[3]])
            normalz.append(get_normal(vert, heightmap))
        else:
            normalz.append(Vector3(0.0, 1.0, 0.0))
    
    var vertices = PackedVector3Array()
    var normals = PackedVector3Array()
    var UVs = PackedVector2Array()
    
    # this if-else is my attempt to make the terrain diagonals smart, sometimes they still don't cooperate
    if min(normal1.y, normal2.y) >= min(normal3.y, normal4.y):
        var uv2
        var cols = [null, null, null]
        if heightmap:
            uv2 = Vector2(vertex_layers[2]/255.0, vertex_layers[1]/255.0)
            cols = [
                Color(vertex_weights[0][0], vertex_weights[0][2], vertex_weights[0][1], vertex_layers[0]/255.0),
                Color(vertex_weights[2][0], vertex_weights[2][2], vertex_weights[2][1], vertex_layers[0]/255.0),
                Color(vertex_weights[1][0], vertex_weights[1][2], vertex_weights[1][1], vertex_layers[0]/255.0),
                    ]
        vertices.append(v0)
        UVs.append(uvs[0])
        normals.append(normalz[0])
        layer_ind.append(uv2)
        layer_weights.append(cols[0])
        vertices.append(v2)
        UVs.append(uvs[2])
        normals.append(normalz[2])
        layer_ind.append(uv2)
        layer_weights.append(cols[2])
        vertices.append(v1)
        UVs.append(uvs[1])
        normals.append(normalz[1])
        layer_ind.append(uv2)
        layer_weights.append(cols[1])
        
        if heightmap:
            uv2 = Vector2(vertex_layers[3]/255.0, vertex_layers[2]/255.0)
            cols = [
                Color(vertex_weights[0][0], vertex_weights[0][3], vertex_weights[0][2], vertex_layers[0]/255.0),
                Color(vertex_weights[3][0], vertex_weights[3][3], vertex_weights[3][2], vertex_layers[0]/255.0),
                Color(vertex_weights[2][0], vertex_weights[2][3], vertex_weights[2][2], vertex_layers[0]/255.0),
                    ]
        vertices.append(v0)
        UVs.append(uvs[0])
        normals.append(normalz[0])
        layer_ind.append(uv2)
        layer_weights.append(cols[0])
        vertices.append(v3)
        UVs.append(uvs[3])
        normals.append(normalz[3])
        layer_ind.append(uv2)
        layer_weights.append(cols[1])
        vertices.append(v2)
        UVs.append(uvs[2])
        normals.append(normalz[2])
        layer_ind.append(uv2)
        layer_weights.append(cols[2])
        
    else:
        var uv2
        var cols = [null, null, null]
        if heightmap:
            uv2 = Vector2(vertex_layers[3]/255.0, vertex_layers[1]/255.0)
            cols = [
                Color(vertex_weights[0][0], vertex_weights[0][3], vertex_weights[0][1], vertex_layers[0]/255.0),
                Color(vertex_weights[3][0], vertex_weights[3][3], vertex_weights[3][1], vertex_layers[0]/255.0),
                Color(vertex_weights[1][0], vertex_weights[1][3], vertex_weights[1][1], vertex_layers[0]/255.0),
                    ]
        vertices.append(v0)
        UVs.append(uvs[0])
        normals.append(normalz[0])
        layer_ind.append(uv2)
        layer_weights.append(cols[0])
        vertices.append(v3)
        UVs.append(uvs[3])
        normals.append(normalz[3])
        layer_ind.append(uv2)
        layer_weights.append(cols[1])
        vertices.append(v1)
        UVs.append(uvs[1])
        normals.append(normalz[1])
        layer_ind.append(uv2)
        layer_weights.append(cols[2])
        
        if heightmap:
            uv2 = Vector2(vertex_layers[2]/255.0, vertex_layers[1]/255.0)
            cols = [
                Color(vertex_weights[3][3], vertex_weights[3][2], vertex_weights[3][1], vertex_layers[3]/255.0),
                Color(vertex_weights[2][3], vertex_weights[2][2], vertex_weights[2][1], vertex_layers[3]/255.0),
                Color(vertex_weights[1][3], vertex_weights[1][2], vertex_weights[1][1], vertex_layers[3]/255.0),
                    ]
        vertices.append(v3)
        UVs.append(uvs[3])
        normals.append(normalz[3])
        layer_ind.append(uv2)
        layer_weights.append(cols[0])
        vertices.append(v2)
        UVs.append(uvs[2])
        normals.append(normalz[2])
        layer_ind.append(uv2)
        layer_weights.append(cols[1])
        vertices.append(v1)
        UVs.append(uvs[1])
        normals.append(normalz[1])
        layer_ind.append(uv2)
        layer_weights.append(cols[2])

    return [vertices, normals, UVs, layer_ind, layer_weights]

func create_edge(vert, n1, n2, normal):
    """
    in: 4 vertices in array and two normals
    out: appropriate triangle vertices for 3 levels of edge depth 
        normals influence the thickness of the top two layers
        
    could i just do long quads and handle the rest in the fragment shader?
    how would the deterministic randomness be achieved? adding different phase and altitude sines?
    how would a fragment know its distance from the surface?
    can pass a Varying smooth y and a Varying static y from vertex to fragment,
    the difference will then indicate when to switch texture
    uv's will then just be in direct coordination to the height
    
    Static Noise texture (can also be used to spice up terrain randomness only needs to be set once)
    Long Quads -> Varying smooth and static -> uv.y's represent height, 
    should jiggle bottom uv.y's based on normal.y's
    """
    var TerrainTexTilingFactor = 0.2
    var factor = (16.0/100.0) * TerrainTexTilingFactor
    var coords = [vert[0].x, vert[1].x, vert[2].x, vert[3].x]
    if abs(normal.x) < abs(normal.z):
        coords = [vert[0].z, vert[1].z, vert[2].z, vert[3].z]
    var uv0 = Vector2(float(coords[0]) * factor, 0.0)
    var uv1 = Vector2(float(coords[1]) * factor, 0.0)
    var uv2 = Vector2(float(coords[2]) * factor, vert[1].y * factor)
    var uv3 = Vector2(float(coords[3]) * factor, vert[0].y * factor)
    var vertices = []
    var normals = []
    var UVs = []
    vertices.append(vert[2])
    UVs.append(uv2)
    normals.append(normal)
    vertices.append(vert[1])
    UVs.append(uv1)
    normals.append(normal)
    vertices.append(vert[0])
    UVs.append(uv0)
    normals.append(normal)
    vertices.append(vert[3])
    UVs.append(uv3)
    normals.append(normal)
    vertices.append(vert[2])
    UVs.append(uv2)
    normals.append(normal)
    vertices.append(vert[0])
    UVs.append(uv0)
    normals.append(normal)
    return [vertices, normals, UVs]

func create_terrain():
    self.ind_layer = $Node3D/Terrain.load_textures_to_uv_dict()
    var vertices : PackedVector3Array = PackedVector3Array()
    var normals : PackedVector3Array = PackedVector3Array()
    var UVs : PackedVector2Array = PackedVector2Array()
    var col_layer_weights : PackedColorArray = PackedColorArray()
    var uv2_layer_ind : PackedVector2Array = PackedVector2Array()
    var e_vertices : PackedVector3Array = PackedVector3Array()
    var e_normals : PackedVector3Array = PackedVector3Array()
    var e_UVs : PackedVector2Array = PackedVector2Array()
    var w_vertices : PackedVector3Array = PackedVector3Array()
    var w_normals : PackedVector3Array = PackedVector3Array()
    var w_UVs : PackedVector2Array = PackedVector2Array()
    # Random heightmap (for now)
    var heightmap : Array
    if savefile != null:
        heightmap = load_city_terrain(savefile)
    else:
        heightmap = gen_random_terrain(size_w * 64 + 1, size_h * 64 + 1)
    self.height_map = heightmap
    $Node3D/WaterPlane.generate_wateredges(heightmap)
    var tiles_w = size_w * 64
    var tiles_h = size_h * 64
    
    var v1
    var v2
    var v3
    var v4
    var ve1
    var ve2
    var ve3
    var ve4
    var vw1
    var vw2
    var vw3
    var vw4
    var n_in1
    var n_in2
    # Top surface 
    for i in range(tiles_w):
        for j in range(tiles_h):
            v1 = Vector3(i,   heightmap[j  ][i  ] / TILE_SIZE, j  )
            v2 = Vector3(i,   heightmap[j+1][i  ] / TILE_SIZE, (j+1))
            v3 = Vector3((i+1), heightmap[j+1][i+1] / TILE_SIZE, (j+1))
            v4 = Vector3((i+1), heightmap[j  ][i+1] / TILE_SIZE, j  )
            var r = create_face(v1, v2, v3, v4, heightmap)
            terr_tile_ind[Vector2(v1.x, v1.z)] = len(vertices)
            vertices.append_array(r[0])
            normals.append_array(r[1])
            UVs.append_array(r[2])
            uv2_layer_ind.append_array(r[3])
            col_layer_weights.append_array(r[4])
            if i == 0:
                ve1 = v2
                ve2 = v1
                ve3 = Vector3(ve1.x, 0.0, ve2.z)
                ve4 = Vector3(ve2.x, 0.0, ve1.z)
                n_in1 = r[1][0]
                n_in2 = r[1][1]
                var e = create_edge([ve1, ve2, ve3, ve4], n_in1, n_in2, Vector3(0.0, 0.0, -1.0))
                e_vertices.append_array(e[0])
                e_normals.append_array(e[1])
                e_UVs.append_array(e[2])
            if i == tiles_w - 1:
                ve1 = v4
                ve2 = v3
                ve3 = Vector3(ve2.x, 0.0, ve2.z)
                ve4 = Vector3(ve1.x, 0.0, ve1.z)
                n_in1 = r[1][3]
                n_in2 = r[1][2]
                var e = create_edge([ve1, ve2, ve3, ve4], n_in1, n_in2, Vector3(0.0, 0.0, 1.0))
                e_vertices.append_array(e[0])
                e_normals.append_array(e[1])
                e_UVs.append_array(e[2])
            if j == 0:
                ve1 = v1
                ve2 = v4
                ve3 = Vector3(ve2.x, 0.0, ve2.z)
                ve4 = Vector3(ve1.x, 0.0, ve1.z)
                n_in1 = r[1][0]
                n_in2 = r[1][3]
                var e = create_edge([ve1, ve2, ve3, ve4], n_in1, n_in2, Vector3(1.0, 0.0, 0.0))
                e_vertices.append_array(e[0])
                e_normals.append_array(e[1])
                e_UVs.append_array(e[2])
            if j == tiles_h - 1:
                ve1 = v3
                ve2 = v2
                ve3 = Vector3(ve2.x, 0.0, ve2.z)
                ve4 = Vector3(ve1.x, 0.0, ve1.z)
                n_in1 = r[1][2]
                n_in2 = r[1][1]
                var e = create_edge([ve1, ve2, ve3, ve4], n_in1, n_in2, Vector3(-1.0, 0.0, 0.0))
                e_vertices.append_array(e[0])
                e_normals.append_array(e[1])
                e_UVs.append_array(e[2])
                
            vw1 = Vector3(i, WATER_HEIGHT, j)
            vw2 = Vector3(i, WATER_HEIGHT, j+1)
            vw3 = Vector3(i+1, WATER_HEIGHT, j+1)
            vw4 = Vector3(i+1, WATER_HEIGHT, j)
            var wa = create_face(vw1, vw2, vw3, vw4, null)
            w_vertices.append_array(wa[0])
            w_normals.append_array(wa[1])
            w_UVs.append_array(wa[2])

    var array_mesh : ArrayMesh = ArrayMesh.new()
    var arrays : Array = []
    arrays.resize(ArrayMesh.ARRAY_MAX)
    arrays[ArrayMesh.ARRAY_VERTEX] = vertices
    arrays[ArrayMesh.ARRAY_NORMAL] = normals 
    arrays[ArrayMesh.ARRAY_TEX_UV] = UVs 
    arrays[ArrayMesh.ARRAY_TEX_UV2] = uv2_layer_ind
    arrays[ArrayMesh.ARRAY_COLOR] = col_layer_weights
    array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    $Node3D/Terrain.mesh = array_mesh
    $Node3D/Terrain.create_trimesh_collision()
    
    #var layer_img = Image.new()
    #var layer_flat = PackedByteArray([])
    #for row in self.layer_arr:
    #	layer_flat.append_array(row)
    #layer_img.create_from_data(self.width, self.height, false, Image.FORMAT_R8, layer_flat)
    #var layer_tex = ImageTexture.new()
    #layer_tex.create_from_image(layer_img) #,2
    #var mat = $Node3D/Terrain.get_material_override()
    #mat.set_shader_parameter("layer", layer_tex)
    #$Node3D/Terrain.set_material_override(mat)
    
    var e_rray_mesh : ArrayMesh = ArrayMesh.new()
    var e_rrays : Array = []
    e_rrays.resize(ArrayMesh.ARRAY_MAX)
    e_rrays[ArrayMesh.ARRAY_VERTEX] = e_vertices
    e_rrays[ArrayMesh.ARRAY_NORMAL] = e_normals 
    e_rrays[ArrayMesh.ARRAY_TEX_UV] = e_UVs 
    e_rray_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, e_rrays)
    $Node3D/Border.mesh = e_rray_mesh
    
    var warray_mesh : ArrayMesh = ArrayMesh.new()
    var warrays : Array = []
    warrays.resize(ArrayMesh.ARRAY_MAX)
    warrays[ArrayMesh.ARRAY_VERTEX] = w_vertices
    warrays[ArrayMesh.ARRAY_NORMAL] = w_normals 
    warrays[ArrayMesh.ARRAY_TEX_UV] = w_UVs 
    warray_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, warrays)
    $Node3D/WaterPlane.mesh = warray_mesh
    
    if savefile != null:
        load_lots()
        load_lot_textures()
        load_networks()
        load_pipes()
        load_network_index()
        load_buildings()

# Parsed LotSubfile records (tile rects, zoning, wealth, orientation). No direct
# rendering: SC4 denormalizes a lot's visuals into the building/prop/flora/
# base-texture subfiles. Kept as the authority for zone overlays, foundations
# and simulation work.
var lots : Array = []

func load_lots():
    var lindex = savefile.indices_by_type.get(0xc9bd5d4a, [])
    if lindex.is_empty():
        Log.info("City has no lot subfile")
        return
    var idx = lindex[0]
    var lsub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, LotSubfile)
    lots = lsub.records
    var zones = {}
    for rec in lots:
        zones[rec.zone_type] = zones.get(rec.zone_type, 0) + 1
    Log.info("Lot subfile: %d lots, zone histogram %s" % [lots.size(), zones])

# FSH group holding lot base/overlay ground textures; instance = family + zoom 0..4.
const LOT_TEXTURE_GROUP : int = 0x0986135e
const LOT_TEXTURE_ZOOM : int = 4        # highest-res variant, fall back coarser

# Reads the city's lot base-texture subfile (the lawn/pavement/dirt under each
# developed lot) and renders it as terrain-hugging tile quads, batched into one
# mesh per texture family. Tile coords are absolute city tiles; each entry's
# orientation rotates the UVs; priority lifts overlays above their base.
func load_lot_textures():
    var tindex = savefile.indices_by_type.get(0xc97f987c, [])
    if tindex.is_empty():
        Log.info("City has no lot base-texture subfile")
        return
    var idx = tindex[0]
    var tsub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, LotBaseTextureSubfile)
    Log.info("Lot base-texture subfile: %d tile entries" % tsub.tiles.size())

    var root = Node3D.new()
    root.name = "LotTextures"
    $Node3D.add_child(root)

    # Batch tiles by texture family so each family is one mesh + one material.
    var by_family = {}
    for t in tsub.tiles:
        if not by_family.has(t.iid):
            by_family[t.iid] = []
        by_family[t.iid].append(t)

    var missing = 0
    for iid in by_family.keys():
        var tex = _lot_texture(iid)
        if tex == null:
            missing += 1
            continue
        var verts = PackedVector3Array()
        var uvs = PackedVector2Array()
        var colors = PackedColorArray()
        var indices = PackedInt32Array()
        for t in by_family[iid]:
            var lift = 0.015 + 0.004 * (t.priority & 7)   # keep overlays above base
            var base = verts.size()
            for corner in [[0, 0], [0, 1], [1, 1], [1, 0]]:
                var cx = t.x + corner[0]
                var cz = t.z + corner[1]
                verts.append(Vector3(cx, _corner_height(cx, cz) + lift, cz))
                colors.append(t.color)
            # UV corners for orientation 0, rotated a quarter-turn per step.
            var uv_corners = [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]
            for c in range(4):
                uvs.append(uv_corners[(c + t.orientation) % 4])
            for i in [0, 1, 2, 0, 2, 3]:
                indices.append(base + i)
        var arrays = []
        arrays.resize(ArrayMesh.ARRAY_MAX)
        arrays[ArrayMesh.ARRAY_VERTEX] = verts
        arrays[ArrayMesh.ARRAY_TEX_UV] = uvs
        arrays[ArrayMesh.ARRAY_COLOR] = colors
        arrays[ArrayMesh.ARRAY_INDEX] = indices
        var mesh = ArrayMesh.new()
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        var mat = StandardMaterial3D.new()
        mat.albedo_texture = tex
        mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        mat.vertex_color_use_as_albedo = true
        mat.cull_mode = BaseMaterial3D.CULL_DISABLED
        mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
        mesh.surface_set_material(0, mat)
        var mi = MeshInstance3D.new()
        mi.mesh = mesh
        root.add_child(mi)
    if missing > 0:
        Log.warn("load_lot_textures: %d texture families missing from the DATs" % missing)

# Resolves a lot-texture family iid to an ImageTexture, preferring the sharpest
# zoom variant present in the loaded DATs. Returns null if none exist.
func _lot_texture(family_iid : int) -> Variant:
    var candidates = []
    for z in range(LOT_TEXTURE_ZOOM, -1, -1):
        candidates.append(family_iid + z)
    candidates.append(family_iid)
    for cand in candidates:
        if Core.subfile_indices.has(SubfileTGI.TGI2str(0x7ab50e44, LOT_TEXTURE_GROUP, cand)):
            return Core.subfile(0x7ab50e44, LOT_TEXTURE_GROUP, cand, FSHSubfile).get_as_texture()
    return null

# Parsed ground-network tiles (roads, streets, avenues, rail...). Each record
# carries its own finished quad, so rendering reads straight from here. This is
# the raw save data; the tile-keyed view everything else should ask is
# `network_model` below.
var save_network_tiles : Array = []

# The authoritative tile map, seeded from the save and mutated by the build
# tool. Anything that needs to know what is where -- the graph, the renderer,
# the tool -- goes through this rather than the raw arrays.
var network_model : NetworkModel = null

# The routable graph derived from the model: lanes, turns and travel times.
# It keeps itself current off the model's tiles_changed signal.
var network_graph : NetworkGraph = null

# FSH group holding network surface textures; instance = family + zoom 0..4.
# Same group the interactive build tool uses (TransitTiles.gd).
const NETWORK_TEXTURE_GROUP : int = 0x1abe787d
const NETWORK_TEXTURE_ZOOM : int = 4
# Network quads sit at the terrain height SC4 baked into the record, so they
# need lifting clear of the lot base textures. Those go up to
# 0.015 + 0.004 * 7 = 0.043, so the network base must start above that or a
# high-priority lot apron buries the road where they overlap at intersections.
const NETWORK_BASE_LIFT : float = 0.055
const NETWORK_SURFACE_LIFT : float = 0.075

# Reads the city's ground-network subfile and draws every tile.
#
# Unlike the lot base textures we do not synthesise the geometry: each record
# already holds the four corners SC4 computed (terrain-following, so sloped
# roads come out right), their texture coordinates and the lighting colour it
# baked at save time. We draw two stacked quads per tile -- the base texture
# (sidewalk/wealth fill) underneath, the network surface on top -- batched into
# one mesh per texture family.
func load_networks():
    var nindex = savefile.indices_by_type.get(0xc9c05c6e, [])
    if nindex.is_empty():
        Log.info("City has no network subfile")
        return
    var idx = nindex[0]
    var nsub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, NetworkSubfile)
    save_network_tiles = nsub.tiles
    Log.info("Network subfile: %d tiles, %d layout failures, types %s"
        % [save_network_tiles.size(), nsub.layout_failures, nsub.type_histogram()])

    # Seed the tile map before drawing, so anything listening for
    # tiles_changed is populated by the time the meshes exist.
    network_model = NetworkModel.new()
    network_model.seed_from_save(save_network_tiles)
    Log.info("Network model: %d tiles, types %s"
        % [network_model.size(), network_model.type_histogram()])
    var unresolved = network_model.unresolved_pieces()
    if unresolved["connected"].is_empty():
        Log.info("Every connected network piece resolved to an SC4Path file")
    else:
        Log.warn("Connected network pieces with no SC4Path: %s" % unresolved["connected"])
    if not unresolved["inert"].is_empty():
        Log.info("Network pieces with no path and no connections (inert): %s" % unresolved["inert"])
    var orient = network_model.orientation_report()
    var rate = 100.0 * orient["agreed"] / max(1, orient["checked"])
    Log.info("Path/save edge agreement: %d of %d tiles (%.1f%%), %d deferred as 2-tile networks, %d without a path"
        % [orient["agreed"], orient["checked"], rate, orient["deferred"], orient["no_path"]])
    # Build the graph after the model is populated, then let it follow every
    # later edit incrementally.
    network_graph = NetworkGraph.new(network_model)
    network_model.tiles_changed.connect(network_graph.update)
    Log.info("Network graph: %d arcs over %d nodes, classes %s, %d dangling portals"
        % [network_graph.arc_count(), network_graph.node_count(),
           network_graph.class_histogram(), network_graph.dangling_portals()])

    if not orient["mismatches"].is_empty():
        # Grouped so the residual stays diagnosable rather than just being a
        # number that drifts. Expect these to be avenue medians (edge code 4,
        # a shared centre lane the path file does not describe) and diagonals.
        var by_piece = {}
        for m in orient["mismatches"]:
            by_piece[m["piece_id"]] = by_piece.get(m["piece_id"], 0) + 1
        Log.info("  %d disagreeing tiles over %d pieces; worst: %s"
            % [orient["mismatches"].size(), by_piece.size(),
               _top_mismatches(orient["mismatches"], by_piece)])

    var root = Node3D.new()
    root.name = "Networks"
    $Node3D.add_child(root)

    # Batch by (texture family, layer) so each family is one mesh + one material.
    var by_family = {}
    var drawn = 0
    for tile in save_network_tiles:
        if not tile.is_present():
            continue
        drawn += 1
        if tile.base_texture != 0:
            _queue_network_quad(by_family, tile.base_texture, tile, NETWORK_BASE_LIFT)
        if tile.texture_id != 0:
            _queue_network_quad(by_family, tile.texture_id, tile, NETWORK_SURFACE_LIFT)

    # Bridge/elevated decks store the same four-vertex quad, so they batch into
    # the same meshes. They sit above the terrain already, so no lift.
    drawn += _queue_bridges(by_family)

    var missing = {}
    for iid in by_family.keys():
        var tex = _network_texture(iid)
        if tex == null:
            missing[iid] = by_family[iid]["verts"].size() / 4
            continue
        var arrays = []
        arrays.resize(ArrayMesh.ARRAY_MAX)
        arrays[ArrayMesh.ARRAY_VERTEX] = by_family[iid]["verts"]
        arrays[ArrayMesh.ARRAY_TEX_UV] = by_family[iid]["uvs"]
        arrays[ArrayMesh.ARRAY_COLOR] = by_family[iid]["colors"]
        arrays[ArrayMesh.ARRAY_INDEX] = by_family[iid]["indices"]
        var mesh = ArrayMesh.new()
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        var mat = StandardMaterial3D.new()
        mat.albedo_texture = tex
        mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        mat.vertex_color_use_as_albedo = true
        mat.cull_mode = BaseMaterial3D.CULL_DISABLED
        # Each tile's UVs span the full 0..1 of its texture, so the sampler must
        # CLAMP: with the default repeat, a pixel on a tile edge filters against
        # the texture's opposite edge and leaves a hairline seam along every
        # tile boundary. Scissor rather than blend, so these stay in the opaque
        # pass and sort by depth -- alpha-blended networks land in the
        # transparent pass, where per-object ordering let lot aprons and the
        # network's own base layer draw over the road at intersections.
        mat.texture_repeat = false
        mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
        mesh.surface_set_material(0, mat)
        var mi = MeshInstance3D.new()
        mi.mesh = mesh
        root.add_child(mi)
    Log.info("Drew %d network tiles (%d texture families, %d missing from the DATs)"
        % [drawn, by_family.size(), missing.size()])
    if not missing.is_empty():
        Log.warn("load_networks: texture families missing from the DATs: %s" % missing)

# One line per disagreeing piece: what the paths claim vs what the save says.
func _top_mismatches(mismatches : Array, by_piece : Dictionary) -> String:
    var example = {}
    for m in mismatches:
        if not example.has(m["piece_id"]):
            example[m["piece_id"]] = m
    var pieces = by_piece.keys()
    pieces.sort_custom(func(a, b): return by_piece[a] > by_piece[b])
    var parts : Array = []
    for iid in pieces.slice(0, 4):
        var m = example[iid]
        parts.append("%08X x%d (orient %02X, %d crossings, paths %s vs save %s)"
            % [iid, by_piece[iid], m["orientation"], m["crossings"],
               m["from_paths"], m["from_save"]])
    return ", ".join(parts)

# Reads the bridge/elevated subfile and adds its decks to the network batches.
# Returns how many tiles were queued.
func _queue_bridges(by_family : Dictionary) -> int:
    var bindex = savefile.indices_by_type.get(0xca16374f, [])
    if bindex.is_empty():
        return 0
    var idx = bindex[0]
    var bsub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, BridgeNetworkSubfile)
    bridge_tiles = bsub.tiles
    Log.info("Bridge subfile: %d deck tiles, %d layout failures"
        % [bridge_tiles.size(), bsub.layout_failures])
    var drawn = 0
    for tile in bridge_tiles:
        if not tile.is_present():
            continue
        drawn += 1
        if tile.base_texture != 0:
            _queue_network_quad(by_family, tile.base_texture, tile, 0.0)
        if tile.model_id != 0:
            _queue_network_quad(by_family, tile.model_id, tile, 0.0)
    return drawn

# Appends one tile quad to the batch for `iid`, lifted clear of the terrain.
func _queue_network_quad(by_family : Dictionary, iid : int, tile, lift : float):
    if not by_family.has(iid):
        by_family[iid] = {
            "verts": PackedVector3Array(),
            "uvs": PackedVector2Array(),
            "colors": PackedColorArray(),
            "indices": PackedInt32Array(),
        }
    var batch = by_family[iid]
    var base = batch["verts"].size()
    for v in tile.vertices:
        # Record positions are metres in the same frame as the heightmap.
        batch["verts"].append(Vector3(v.position.x / TILE_SIZE,
            v.position.y / TILE_SIZE + lift, v.position.z / TILE_SIZE))
        batch["uvs"].append(v.uv)
        batch["colors"].append(v.color)
    for i in [0, 1, 2, 0, 2, 3]:
        batch["indices"].append(base + i)

# Parsed water-pipe tiles, and the network index the game keeps over all of the
# network subfiles at once.
var pipe_tiles : Array = []
var bridge_tiles : Array = []
var network_index : NetworkIndexSubfile = null
var power_lines : PowerLineSubfile = null
var lot_structures : Array = []
# Exemplar TGI string -> {texture, tiling, iid} or null for known-unskinnable.
var lot_structure_skins : Dictionary = {}

# Wire attachment height above a pylon's origin, and half-width of the drawn
# span, both in world units (tiles).
const POWER_WIRE_HEIGHT : float = 1.6
const POWER_WIRE_WIDTH : float = 0.02

# Reads the pipe subfile. Pipes are underground, so SC4 only shows them in the
# water data view; we build the geometry into a hidden node that
# set_pipes_visible() reveals, rather than drawing it over the city.
func load_pipes():
    var pindex = savefile.indices_by_type.get(0x49c05b9f, [])
    if pindex.is_empty():
        Log.info("City has no pipe subfile")
        return
    var idx = pindex[0]
    var psub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, PipeSubfile)
    pipe_tiles = psub.tiles
    Log.info("Pipe subfile: %d tiles, %d layout failures" % [pipe_tiles.size(), psub.layout_failures])

    var root = Node3D.new()
    root.name = "Pipes"
    root.visible = false
    $Node3D.add_child(root)

    # A flat marker per tile. The pipe's own texture id is a tile-shape code
    # from the network piece tables, not a ground texture, so tinting is more
    # honest than stretching a road texture over it.
    var verts = PackedVector3Array()
    var indices = PackedInt32Array()
    for tile in pipe_tiles:
        if not tile.is_present():
            continue
        var base = verts.size()
        for v in tile.vertices:
            verts.append(Vector3(v.position.x / TILE_SIZE,
                v.position.y / TILE_SIZE + NETWORK_SURFACE_LIFT, v.position.z / TILE_SIZE))
        for i in [0, 1, 2, 0, 2, 3]:
            indices.append(base + i)
    if verts.is_empty():
        return
    var arrays = []
    arrays.resize(ArrayMesh.ARRAY_MAX)
    arrays[ArrayMesh.ARRAY_VERTEX] = verts
    arrays[ArrayMesh.ARRAY_INDEX] = indices
    var mesh = ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    var mat = StandardMaterial3D.new()
    mat.albedo_color = Color(0.25, 0.65, 1.0, 0.75)
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.cull_mode = BaseMaterial3D.CULL_DISABLED
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    # Pipe tiles sit a median 10 m BELOW the terrain surface (measured across
    # this save: -6.5 m to -25.5 m), so drawing them normally just buries them
    # in the ground. The underground view is an x-ray: skip the depth test and
    # draw last, so the network reads through the terrain above it.
    mat.no_depth_test = true
    mat.render_priority = 10
    mesh.surface_set_material(0, mat)
    var mi = MeshInstance3D.new()
    mi.mesh = mesh
    root.add_child(mi)

# Whether the underground (pipe) view is showing. Toggled with U.
var underground_view : bool = false

func set_pipes_visible(on : bool):
    underground_view = on
    var root = $Node3D.get_node_or_null("Pipes")
    if root != null:
        root.visible = on

func toggle_underground_view() -> bool:
    set_pipes_visible(not underground_view)
    return underground_view

# Reads the game's own index over the network subfiles. Nothing renders from it
# -- it is the authority for "which occupant is on this tile", which simulation
# and tool work will need. See NetworkIndexSubfile for what is and is not
# decoded.
func load_network_index():
    var iindex = savefile.indices_by_type.get(0x6a0f82b2, [])
    if iindex.is_empty():
        Log.info("City has no network index subfile")
        return
    var idx = iindex[0]
    network_index = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, NetworkIndexSubfile)
    Log.info("Network index: version %d, %d city tiles, %d/%d tile references recovered, by subfile %s"
        % [network_index.major, network_index.city_tile_count, network_index.tile_refs.size(),
           network_index.network_tile_count, network_index.type_histogram()])

# Resolves a network texture family iid to an ImageTexture, preferring the
# sharpest zoom variant present in the loaded DATs. Returns null if none exist.
func _network_texture(family_iid : int) -> Variant:
    for z in range(NETWORK_TEXTURE_ZOOM, -1, -1):
        if Core.subfile_indices.has(SubfileTGI.TGI2str(0x7ab50e44, NETWORK_TEXTURE_GROUP, family_iid + z)):
            return Core.subfile(0x7ab50e44, NETWORK_TEXTURE_GROUP, family_iid + z, FSHSubfile).get_as_texture()
    if Core.subfile_indices.has(SubfileTGI.TGI2str(0x7ab50e44, NETWORK_TEXTURE_GROUP, family_iid)):
        return Core.subfile(0x7ab50e44, NETWORK_TEXTURE_GROUP, family_iid, FSHSubfile).get_as_texture()
    return null

# Exact heightmap value (world units) at a tile CORNER (grid vertex), unlike
# _height_at which samples per-tile.
func _corner_height(x : int, z : int) -> float:
    var iz = clamp(z, 0, self.height_map.size() - 1)
    var ix = clamp(x, 0, self.height_map[iz].size() - 1)
    return self.height_map[iz][ix] / TILE_SIZE

# Reads the city's Building occupant subfile and renders each placed building:
# occupant record -> building exemplar -> RKT -> S3D model (cached per variant),
# instanced at the record's world position on the terrain.
func load_buildings():
    var bindex = savefile.indices_by_type.get(0xa9bd882d, [])
    if bindex.is_empty():
        Log.info("City has no building subfile")
        return
    var idx = bindex[0]
    var bsub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, BuildingSubfile)
    Log.info("Building subfile: %d records" % bsub.records.size())

    building_root = Node3D.new()
    building_root.name = "Buildings"
    $Node3D.add_child(building_root)
    opaque_mat_base = $Node3D/TestS3D.get_material_override()
    blend_mat_base = $Node3D/S3DBlendBase.get_material_override()

    var cam = $CameraHandler
    current_s3d_zoom = S3D_ZOOM_FOR_CAMERA[cam.zoom - 1]
    current_s3d_rot = posmod(ROT_SIGN * (2 - cam.rotated), 4)
    current_rot_comp = (cam.rotated - 2) * PI / 2.0

    _place_occupants(bsub.records, "buildings")
    load_props()

# Reads the city's Prop occupant subfile (cars, benches, lot trees, AC units...)
# and renders it through the same exemplar -> RKT -> S3D pipeline as buildings.
func load_props():
    var pindex = savefile.indices_by_type.get(0x2977aa47, [])
    if pindex.is_empty():
        Log.info("City has no prop subfile")
        return
    var idx = pindex[0]
    var psub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, PropSubfile)
    Log.info("Prop subfile: %d records" % psub.records.size())
    _place_occupants(psub.records, "props")
    load_flora()

# Reads the city's Flora occupant subfile (god/mayor-mode trees; lot trees are
# props) and renders it through the same pipeline.
func load_flora():
    var findex = savefile.indices_by_type.get(0xa9c05c85, [])
    if findex.is_empty():
        Log.info("City has no flora subfile")
        return
    var idx = findex[0]
    var fsub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, FloraSubfile)
    Log.info("Flora subfile: %d records" % fsub.records.size())
    _place_occupants(fsub.records, "flora")
    load_power_lines()
    load_lot_structures()

# Power lines come as two cross-referencing subfiles: the pylons (which carry an
# Exemplar TGI and so go through the same S3D pipeline as buildings) and the
# spans between them (which name their two pylons by memory address). Runs after
# the occupants so the shared S3D material bases are ready.
func load_power_lines():
    var lindex = savefile.indices_by_type.get(0xc9c05c5d, [])
    var pindex = savefile.indices_by_type.get(0x09c05c6a, [])
    if lindex.is_empty() and pindex.is_empty():
        Log.info("City has no power lines")
        return
    var lsub : PowerLineSubfile = null
    if not lindex.is_empty():
        var li = lindex[0]
        lsub = savefile.get_subfile(li.type_id, li.group_id, li.instance_id, PowerLineSubfile)
    if not pindex.is_empty():
        var pi = pindex[0]
        var psub = savefile.get_subfile(pi.type_id, pi.group_id, pi.instance_id, PowerLineSubfile)
        if lsub == null:
            lsub = psub
        else:
            lsub.adopt_poles(psub)
    power_lines = lsub
    Log.info("Power lines: %d spans, %d pylons, %d layout failures"
        % [lsub.lines.size(), lsub.poles.size(), lsub.layout_failures])

    var pylons = []
    for mem in lsub.poles.keys():
        if lsub.poles[mem].is_present():
            pylons.append(lsub.poles[mem])
    _place_occupants(pylons, "power pylons")
    _draw_power_spans(lsub)

# Exemplar properties on a foundation/retaining-wall exemplar. Each names five
# FSH instances (zoom 0..4) plus the world size, in metres, that one repeat of
# the texture covers.
const WALL_TEXTURES_PROP : int = 0x295961f2
const WALL_TILING_PROP : int = 0x295961f3
const FOUNDATION_TEXTURES_PROP : int = 0x68fcff37
const FOUNDATION_TILING_PROP : int = 0xc911eda0
const WALL_TEXTURE_GROUP : int = 0x891b0e1a       # TERRAIN_FOUNDATION
const FOUNDATION_TEXTURE_GROUP : int = 0x1abe787d # UI_IMAGE2

# Reads the retaining walls and foundations SC4 builds under a lot when the
# ground beneath it is not flat.
#
# These are NOT S3D occupants: their exemplars carry no model reference, only a
# set of five zoom variants of a wall/concrete texture and the world size one
# repeat covers ('LotRetainingWall-r$co', 'Concrete Hori'). SC4 stretches that
# texture over a box sized by the record, so that is what we build -- the four
# vertical faces of a box, from the lot surface down by the record's height.
func load_lot_structures():
    for entry in [[0x49c05c8f, "foundations"], [0x49c05c9f, "retaining walls"]]:
        var sindex = savefile.indices_by_type.get(entry[0], [])
        if sindex.is_empty():
            continue
        var idx = sindex[0]
        var sub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, LotStructureSubfile)
        var present = []
        for s in sub.structures:
            if s.is_present():
                present.append(s)
        lot_structures.append_array(present)
        Log.info("Lot %s: %d records, %d present, %d layout failures"
            % [entry[1], sub.structures.size(), present.size(), sub.layout_failures])
        _draw_lot_structures(present, entry[1])

# Batches structures by texture and emits the sides of each box.
func _draw_lot_structures(items : Array, what : String):
    if items.is_empty():
        return
    var root = $Node3D.get_node_or_null("LotStructures")
    if root == null:
        root = Node3D.new()
        root.name = "LotStructures"
        $Node3D.add_child(root)

    # The population is mixed: most of these exemplars carry a wall/concrete
    # texture to stretch over a box, but some carry an RKT1 S3D model instead
    # (group 0xBADB57F1) and go through the ordinary occupant pipeline.
    var by_texture = {}
    var modelled = []
    for s in items:
        var skin = _lot_structure_skin(s.exemplar_tgi)
        if skin == null:
            modelled.append(s)
            continue
        var key = skin["iid"]
        if not by_texture.has(key):
            by_texture[key] = {"skin": skin, "verts": PackedVector3Array(),
                "uvs": PackedVector2Array(), "indices": PackedInt32Array()}
        _queue_structure_box(by_texture[key], s, skin["tiling"])
    if not modelled.is_empty():
        _place_occupants(modelled, what + " (modelled)")

    for key in by_texture.keys():
        var batch = by_texture[key]
        var arrays = []
        arrays.resize(ArrayMesh.ARRAY_MAX)
        arrays[ArrayMesh.ARRAY_VERTEX] = batch["verts"]
        arrays[ArrayMesh.ARRAY_TEX_UV] = batch["uvs"]
        arrays[ArrayMesh.ARRAY_INDEX] = batch["indices"]
        var mesh = ArrayMesh.new()
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        var mat = StandardMaterial3D.new()
        mat.albedo_texture = batch["skin"]["texture"]
        mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        mat.cull_mode = BaseMaterial3D.CULL_DISABLED
        mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
        mesh.surface_set_material(0, mat)
        var mi = MeshInstance3D.new()
        mi.mesh = mesh
        root.add_child(mi)
    Log.info("Drew %d textured %s (%d texture families); %d were modelled instead"
        % [items.size() - modelled.size(), what, by_texture.size(), modelled.size()])

# Emits the four vertical faces of one structure. The record's altitude is the
# top (the lot surface); the box drops from there by its height.
func _queue_structure_box(batch : Dictionary, s, tiling : float):
    var half_x = s.size_x / 2.0 / TILE_SIZE
    var half_z = s.size_z / 2.0 / TILE_SIZE
    var cx = s.pos_x / TILE_SIZE
    var cz = s.pos_z / TILE_SIZE
    var top = s.altitude / TILE_SIZE
    var bottom = (s.altitude - s.height) / TILE_SIZE
    var corners = [
        Vector2(cx - half_x, cz - half_z),
        Vector2(cx + half_x, cz - half_z),
        Vector2(cx + half_x, cz + half_z),
        Vector2(cx - half_x, cz + half_z),
    ]
    var v_repeats = (s.height / tiling) if tiling > 0.0 else 1.0
    for i in range(4):
        var a = corners[i]
        var b = corners[(i + 1) % 4]
        var run = a.distance_to(b) * TILE_SIZE          # metres along this face
        var u_repeats = (run / tiling) if tiling > 0.0 else 1.0
        var base = batch["verts"].size()
        batch["verts"].append(Vector3(a.x, top, a.y))
        batch["verts"].append(Vector3(b.x, top, b.y))
        batch["verts"].append(Vector3(b.x, bottom, b.y))
        batch["verts"].append(Vector3(a.x, bottom, a.y))
        batch["uvs"].append(Vector2(0.0, 0.0))
        batch["uvs"].append(Vector2(u_repeats, 0.0))
        batch["uvs"].append(Vector2(u_repeats, v_repeats))
        batch["uvs"].append(Vector2(0.0, v_repeats))
        for k in [0, 1, 2, 0, 2, 3]:
            batch["indices"].append(base + k)

# Resolves a foundation/wall exemplar to {texture, tiling, iid}, or null. The
# exemplar lists its five zoom variants explicitly, so we index that array
# rather than doing the usual iid + zoom arithmetic.
func _lot_structure_skin(exemplar_tgi : Array):
    var key = SubfileTGI.TGI2str(exemplar_tgi[0], exemplar_tgi[1], exemplar_tgi[2])
    if lot_structure_skins.has(key):
        return lot_structure_skins[key]
    lot_structure_skins[key] = null
    if not Core.subfile_indices.has(key):
        return null
    var ex = Core.subfile(exemplar_tgi[0], exemplar_tgi[1], exemplar_tgi[2], ExemplarSubfile)
    var textures = ex.properties.get(WALL_TEXTURES_PROP, ex.properties.get(FOUNDATION_TEXTURES_PROP, null))
    if typeof(textures) != TYPE_ARRAY or textures.is_empty():
        return null
    var group = WALL_TEXTURE_GROUP if ex.properties.has(WALL_TEXTURES_PROP) else FOUNDATION_TEXTURE_GROUP
    var tiling = ex.properties.get(WALL_TILING_PROP, ex.properties.get(FOUNDATION_TILING_PROP, 16.0))
    if typeof(tiling) == TYPE_ARRAY:
        tiling = tiling[0]
    for z in range(min(textures.size(), 5) - 1, -1, -1):
        var iid = textures[z]
        if Core.subfile_indices.has(SubfileTGI.TGI2str(0x7ab50e44, group, iid)):
            var skin = {
                "texture": Core.subfile(0x7ab50e44, group, iid, FSHSubfile).get_as_texture(),
                "tiling": float(tiling),
                "iid": iid,
            }
            lot_structure_skins[key] = skin
            return skin
    return null

# Draws each span as a thin quad between the two pylons it names. SC4's own wire
# geometry lives in the undecoded tail of the pylon record, so this is a
# straight run at the pylons' own height rather than a true catenary.
func _draw_power_spans(sub : PowerLineSubfile):
    var verts = PackedVector3Array()
    var indices = PackedInt32Array()
    var unresolved = 0
    for line in sub.lines:
        if not line.is_present():
            continue
        if line.pole_mems.size() != 2 or not sub.poles.has(line.pole_mems[0]) or not sub.poles.has(line.pole_mems[1]):
            unresolved += 1
            continue
        var a = sub.poles[line.pole_mems[0]].position / TILE_SIZE
        var b = sub.poles[line.pole_mems[1]].position / TILE_SIZE
        # Hang the wire near the top of the pylon rather than at its base.
        a.y += POWER_WIRE_HEIGHT
        b.y += POWER_WIRE_HEIGHT
        var side = Vector3(0, 1, 0).cross(b - a).normalized() * POWER_WIRE_WIDTH
        if side == Vector3.ZERO:
            continue
        var base = verts.size()
        verts.append(a - side)
        verts.append(b - side)
        verts.append(b + side)
        verts.append(a + side)
        for i in [0, 1, 2, 0, 2, 3]:
            indices.append(base + i)
    if unresolved > 0:
        Log.warn("load_power_lines: %d spans reference a pylon that is not in the save" % unresolved)
    if verts.is_empty():
        return
    var arrays = []
    arrays.resize(ArrayMesh.ARRAY_MAX)
    arrays[ArrayMesh.ARRAY_VERTEX] = verts
    arrays[ArrayMesh.ARRAY_INDEX] = indices
    var mesh = ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    var mat = StandardMaterial3D.new()
    mat.albedo_color = Color(0.12, 0.12, 0.13)
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.cull_mode = BaseMaterial3D.CULL_DISABLED
    mesh.surface_set_material(0, mat)
    var mi = MeshInstance3D.new()
    mi.mesh = mesh
    mi.name = "PowerSpans"
    $Node3D.add_child(mi)

# Shared placement loop for occupant records (buildings, props, flora). Records
# need exemplar_tgi, pos_x, pos_z and orientation. The occupant's own world
# orientation is folded into which S3D rotation variant is displayed (rotating
# the impostor mesh itself would break the fixed-camera illusion).
func _place_occupants(recs : Array, what : String):
    var placed = 0
    var sprites = 0
    var no_model = 0
    for rec in recs:
        var ref = _model_ref_for_exemplar(rec.exemplar_tgi)
        if ref == null:
            # No 3D model: the occupant may still be one of SC4's 2D sprite
            # props (see the "2D (sprite) props" section below).
            if _place_sprite(rec):
                sprites += 1
            else:
                no_model += 1
            continue
        var vrot = posmod(current_s3d_rot + ROT_SIGN * rec.orientation, 4)
        var model = _resolve_model(ref, current_s3d_zoom, vrot)
        if model == null:
            no_model += 1
            continue
        var mi = MeshInstance3D.new()
        mi.mesh = model["mesh"]
        mi.set_meta("model_ref", ref)
        mi.set_meta("orientation", rec.orientation)
        if ref["prop_key"] == RKT1_PROP:
            mi.rotation.y = current_rot_comp
        var x = rec.pos_x / TILE_SIZE
        var z = rec.pos_z / TILE_SIZE
        mi.position = Vector3(x, _height_at(x, z), z)
        building_root.add_child(mi)
        placed += 1
    Log.info("Placed %d %s, %d as 2D sprites (%d without a resolvable model)"
        % [placed, what, sprites, no_model])

# SC4 building models are referenced via ResourceKeyType1 (RKT1, exemplar property
# 0x27812821): the stored instance id is a BASE, and the real S3D models fan out as
# 5 zoom levels x 4 rotations, encoded  iid = base + (zoom << 8) + (rotation << 4).
# Each zoom x rotation S3D is a 2.5D impostor authored for one fixed isometric
# camera, so exactly ONE variant -- matching the current view -- is rendered, and
# swapped live when the camera zooms or rotates (see set_building_view).
const RKT1_PROP : int = 0x27812821
# Handedness of the baked variant rotations vs Godot's yaw. The one empirical
# unknown of the variant math: flip to -1 if rotating the iso view melts buildings.
const ROT_SIGN : int = -1
# Camera zoom 1..6 (CameraAnchor3D.zoom) -> S3D szoom LOD 0..4.
const S3D_ZOOM_FOR_CAMERA = [0, 1, 2, 3, 4, 4]

var building_root : Node3D
# Concrete variant TGI string -> {"mesh": ArrayMesh} or null for known-unbuildable.
var model_cache = {}
var opaque_mat_base : ShaderMaterial
var blend_mat_base : ShaderMaterial
var current_s3d_zoom : int = 0
var current_s3d_rot : int = 0
var current_rot_comp : float = 0.0

# The first model reference of a building exemplar, or null if unresolvable.
# (-> Variant is load-bearing: without it the analyzer infers the mixed
# Dictionary/null returns as hard null and rejects subscripts on the result.)
func _model_ref_for_exemplar(exemplar_tgi : Array) -> Variant:
    if not Core.subfile_indices.has(SubfileTGI.TGI2str(exemplar_tgi[0], exemplar_tgi[1], exemplar_tgi[2])):
        return null
    var exemplar = Core.subfile(exemplar_tgi[0], exemplar_tgi[1], exemplar_tgi[2], ExemplarSubfile)
    var refs = exemplar.get_all_model_refs()
    if refs.is_empty():
        return null
    return refs[0]

# Zoom fallback order when the target zoom's S3D or its FSH textures are missing
# from the loaded DATs: coarser LODs first, finer ones as a last resort.
func _zoom_candidates(target_zoom : int) -> Array:
    var out = []
    for z in range(target_zoom, -1, -1):
        out.append(z)
    for z in range(target_zoom + 1, 5):
        out.append(z)
    return out

# Resolves a model reference to a cached {"mesh":} for the requested view,
# building it on first use. Returns null if no zoom candidate is buildable.
func _resolve_model(ref : Dictionary, s3d_zoom : int, rot : int) -> Variant:
    var tgi : Array = ref["tgi"]
    # Try the zoom x rotation fanout first (RKT1/RKT4 store base iids), then the
    # literal iid as a fallback (RKT0-style single-model refs).
    var zooms = _zoom_candidates(s3d_zoom) + [null]
    for z in zooms:
        var iid = tgi[2] if z == null else tgi[2] + (z << 8) + (rot << 4)
        var key = SubfileTGI.TGI2str(tgi[0], tgi[1], iid)
        if model_cache.has(key):
            if model_cache[key] != null:
                return model_cache[key]
            continue                       # known-unbuildable at this zoom, try next
        if not Core.subfile_indices.has(key):
            model_cache[key] = null
            continue
        var s3d = Core.subfile(tgi[0], tgi[1], iid, S3DSubfile)
        var built = s3d.build_model(opaque_mat_base, blend_mat_base)
        if built.is_empty():
            model_cache[key] = null
            continue
        model_cache[key] = built
        return built
    return null

# --- 2D (sprite) props -------------------------------------------------------
#
# A minority of SC4 props have no S3D impostor at all. Their exemplar carries a
# ResourceKeyType0 pointing at an ATC animation header (ATCSubfile.gd) instead,
# and SC4 draws them by blitting pre-rendered sprites into the isometric view --
# traffic lights (by far the most common: 362 of them in the tutorial city),
# the animated roof balloons, the exploratorium.
#
# We reproduce that as a camera-facing billboard quad carrying the frame's
# pixels, scaled so it covers exactly the screen area the sprite was authored
# for and offset so the frame's anchor pixel sits on the prop's world position.
#
# Exemplar property: true when the frames are indexed by state rather than
# played over time. Every traffic light sets it, and its four frames are the
# four view rotations of the pole -- the sprite equivalent of an S3D model's
# four baked rotation variants.
const STATES_AS_FRAMES_PROP : int = 0x4a70d491

# Sprite pixels per world unit (one 16 m tile) at appearance zoom 0..4.
#
# Measured from the game's own data rather than assumed: SC4's sprites and its
# S3D impostor textures come out of the same pre-renderer, and an S3D model ties
# world coordinates to texture pixels directly. Least-squares fitting
# (vertex position -> UV * texture size) over ~700 building models per zoom
# yields the world->screen-pixel matrix; the numbers below are its row norms
# (both rows agree to <0.1%, i.e. the projection is conformal in the camera
# plane, which is what lets a single scalar scale a billboard). The same fit
# recovers azimuth 67.5 deg and the per-zoom elevations that CameraAnchor3D
# already uses, so our camera and this art share one projection.
const SPRITE_PX_PER_TILE := [6.449, 12.576, 24.965, 56.170, 112.147]

# Frame advance for time-animated (non state-indexed) sprites: the ATC's rate
# field is read as a count of 1/30 s ticks per frame. The unit is an assumption
# -- rate is 21 for the balloons and 31 for the exploratorium, which lands both
# near one frame per second.
const SPRITE_TICK_HZ : float = 30.0

var sprite_root : Node3D
# Sprites whose frames advance with time (i.e. not STATES_AS_FRAMES_PROP and
# with more than one frame). Kept apart so _process can skip the static ones.
var animated_sprites : Array = []
var sprite_clock : float = 0.0
# ATC TGI string -> {"atc": ATCSubfile, "avp": [AVPSubfile or null per zoom]},
# or null for exemplars whose animation could not be loaded.
var sprite_anim_cache = {}
# "<atc tgi>|<zoom>|<frame>" -> ArrayMesh ready to instance, or null if the
# frame could not be built (missing page, out-of-bounds rectangle).
var sprite_mesh_cache = {}
# "<fsh tgi>|<page>" -> decompressed RGBA8 Image of one sprite-sheet page.
var sprite_page_cache = {}

# The first ATC reference of an exemplar, tagged with whether its frames are
# states, or null if this exemplar is not a sprite prop.
func _sprite_ref_for_exemplar(exemplar_tgi : Array) -> Variant:
    if not Core.subfile_indices.has(SubfileTGI.TGI2str(exemplar_tgi[0], exemplar_tgi[1], exemplar_tgi[2])):
        return null
    var exemplar = Core.subfile(exemplar_tgi[0], exemplar_tgi[1], exemplar_tgi[2], ExemplarSubfile)
    var refs = exemplar.get_all_sprite_refs()
    if refs.is_empty():
        return null
    var ref : Dictionary = refs[0]
    ref["states_as_frames"] = exemplar.properties.get(STATES_AS_FRAMES_PROP, false) == true
    return ref

# Instances one occupant record as a sprite billboard. Returns false (leaving
# nothing in the scene) if the record is not a sprite prop or its frames are
# unavailable, so the caller can go on counting it as unresolvable.
func _place_sprite(rec) -> bool:
    var ref = _sprite_ref_for_exemplar(rec.exemplar_tgi)
    if ref == null:
        return false
    var anim = _sprite_anim(ref["tgi"])
    if anim == null:
        return false
    var frame = _sprite_frame(ref, rec.orientation, current_s3d_rot, 0)
    var mesh = _resolve_sprite(anim, current_s3d_zoom, frame)
    if mesh == null:
        return false
    if sprite_root == null:
        sprite_root = Node3D.new()
        sprite_root.name = "PropSprites"
        $Node3D.add_child(sprite_root)
    var mi = MeshInstance3D.new()
    mi.mesh = mesh
    mi.visible = _sprite_visible_at(anim, current_s3d_zoom)
    mi.set_meta("sprite_ref", ref)
    mi.set_meta("orientation", rec.orientation)
    var x = rec.pos_x / TILE_SIZE
    var z = rec.pos_z / TILE_SIZE
    mi.position = Vector3(x, _height_at(x, z), z)
    sprite_root.add_child(mi)
    if not ref["states_as_frames"] and _sprite_is_animated(anim):
        animated_sprites.append(mi)
    return true

# SC4 stops drawing a sprite prop entirely at zooms its ATC has no frame table
# for -- traffic lights are authored for zooms 2..4 only, and at zoom 0 a pole
# would be a sub-pixel smudge. _resolve_sprite still falls back across zooms so
# the node always holds a usable mesh; this decides whether it is shown.
func _sprite_visible_at(anim : Dictionary, zoom : int) -> bool:
    return anim["avp"][zoom] != null

# Which frame of a sprite prop to show. State-indexed props (traffic lights)
# pick by the occupant's orientation relative to the view, exactly as an S3D
# occupant picks its baked rotation variant in _place_occupants; everything else
# runs off the shared animation clock.
func _sprite_frame(ref : Dictionary, orientation : int, rot : int, tick : int) -> int:
    if ref["states_as_frames"]:
        return posmod(rot + ROT_SIGN * orientation, 4)
    return tick

func _sprite_is_animated(anim : Dictionary) -> bool:
    for avp in anim["avp"]:
        if avp != null and avp.frames.size() > 1:
            return true
    return false

# Loads an ATC and every per-zoom AVP frame table it names. Returns null if the
# animation is unusable; the result (including null) is cached per ATC.
func _sprite_anim(tgi : Array) -> Variant:
    var key = SubfileTGI.TGI2str(tgi[0], tgi[1], tgi[2])
    if sprite_anim_cache.has(key):
        return sprite_anim_cache[key]
    var out = null
    if Core.subfile_indices.has(key):
        var atc = Core.subfile(tgi[0], tgi[1], tgi[2], ATCSubfile)
        if atc != null and atc.is_valid():
            var avps = []
            var any = false
            for z in range(ATCSubfile.ZOOM_COUNT):
                var avp = null
                var iid = atc.avp_by_zoom[z]
                if iid != 0:
                    var akey = SubfileTGI.TGI2str(ATCSubfile.AVP_TYPE, atc.avp_group, iid)
                    if Core.subfile_indices.has(akey):
                        avp = Core.subfile(ATCSubfile.AVP_TYPE, atc.avp_group, iid, AVPSubfile)
                        if avp != null and avp.frames.is_empty():
                            avp = null
                avps.append(avp)
                any = any or avp != null
            if any:
                out = {"atc": atc, "avp": avps}
    sprite_anim_cache[key] = out
    return out

# Resolves an animation to a cached billboard mesh for the requested view,
# falling back through _zoom_candidates when the prop is not authored at the
# current zoom (AppearanceZoomsFlag leaves the far zooms empty for small props).
func _resolve_sprite(anim : Dictionary, s3d_zoom : int, frame : int) -> Variant:
    var atc : ATCSubfile = anim["atc"]
    var atc_key = SubfileTGI.TGI2str(ATCSubfile.TYPE_ID, atc.index.group_id, atc.index.instance_id)
    for z in _zoom_candidates(s3d_zoom):
        var avp = anim["avp"][z]
        if avp == null:
            continue
        var f = posmod(frame, avp.frames.size())
        var key = "%s|%d|%d" % [atc_key, z, f]
        if sprite_mesh_cache.has(key):
            if sprite_mesh_cache[key] != null:
                return sprite_mesh_cache[key]
            continue                       # known-unbuildable at this zoom
        var mesh = _build_sprite_mesh(atc, avp.frames[f], z)
        sprite_mesh_cache[key] = mesh
        if mesh != null:
            return mesh
    return null

# Cuts one frame out of its sprite-sheet page and wraps it in a billboard quad.
#
# The quad lives in the camera plane (BILLBOARD_ENABLED), so its local axes are
# screen right and screen up: one sprite pixel is 1/SPRITE_PX_PER_TILE world
# units along both. Vertices are emitted relative to the frame's anchor pixel,
# which puts the anchor -- the point the sprite was drawn to stand on -- at the
# MeshInstance3D's origin, i.e. on the terrain at the occupant's position.
func _build_sprite_mesh(atc : ATCSubfile, frame, zoom : int) -> Variant:
    if frame.width <= 0 or frame.height <= 0:
        return null
    var page : Image = _sprite_page(atc.fsh_tgi, frame.page)
    if page == null:
        return null
    var x0 = frame.offset % page.get_width()
    var y0 = frame.offset / page.get_width()
    if x0 + frame.width > page.get_width() or y0 + frame.height > page.get_height():
        Log.warn("ATC %08x: frame %dx%d at (%d,%d) runs off its %dx%d page" % [
            atc.index.instance_id, frame.width, frame.height, x0, y0,
            page.get_width(), page.get_height()])
        return null
    var img = Image.create_empty(frame.width, frame.height, false, Image.FORMAT_RGBA8)
    img.blit_rect(page, Rect2i(x0, y0, frame.width, frame.height), Vector2i.ZERO)

    var upx = 1.0 / SPRITE_PX_PER_TILE[zoom]
    # Sprite pixel (px, py) -> quad-local (x right, y up), anchor at the origin.
    var left = (0 - frame.anchor_x) * upx
    var right = (frame.width - frame.anchor_x) * upx
    var top = (frame.anchor_y - 0) * upx
    var bottom = (frame.anchor_y - frame.height) * upx
    var verts = PackedVector3Array([
        Vector3(left, top, 0.0), Vector3(left, bottom, 0.0), Vector3(right, bottom, 0.0),
        Vector3(left, top, 0.0), Vector3(right, bottom, 0.0), Vector3(right, top, 0.0),
    ])
    var uvs = PackedVector2Array([
        Vector2(0.0, 0.0), Vector2(0.0, 1.0), Vector2(1.0, 1.0),
        Vector2(0.0, 0.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0),
    ])
    var arrays = []
    arrays.resize(ArrayMesh.ARRAY_MAX)
    arrays[ArrayMesh.ARRAY_VERTEX] = verts
    arrays[ArrayMesh.ARRAY_TEX_UV] = uvs
    var mesh = ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

    var mat = StandardMaterial3D.new()
    mat.albedo_texture = ImageTexture.create_from_image(img)
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    # The sheets are DXT1 (1-bit alpha) or DXT3; scissoring keeps sprites
    # depth-sorted against the terrain and each other without a transparent pass.
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
    mat.alpha_scissor_threshold = 0.5
    mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
    mat.cull_mode = BaseMaterial3D.CULL_DISABLED
    mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
    mat.billboard_keep_scale = true
    mesh.surface_set_material(0, mat)
    return mesh

# One page (FSH directory entry) of a sprite sheet, decompressed to RGBA8.
func _sprite_page(fsh_tgi : Array, page : int) -> Variant:
    var key = "%s|%d" % [SubfileTGI.TGI2str(fsh_tgi[0], fsh_tgi[1], fsh_tgi[2]), page]
    if sprite_page_cache.has(key):
        return sprite_page_cache[key]
    var img = null
    if Core.subfile_indices.has(SubfileTGI.TGI2str(fsh_tgi[0], fsh_tgi[1], fsh_tgi[2])):
        var fsh = Core.subfile(fsh_tgi[0], fsh_tgi[1], fsh_tgi[2], FSHSubfile)
        if fsh != null:
            img = fsh.page_image(page)
    sprite_page_cache[key] = img
    return img

# Advances time-animated sprites. Static ones (traffic lights) never enter
# animated_sprites, so a city without animated props costs nothing here.
func _process(delta : float) -> void:
    if animated_sprites.is_empty():
        return
    sprite_clock += delta
    for mi in animated_sprites:
        if not mi.visible:
            continue
        var ref = mi.get_meta("sprite_ref")
        var anim = _sprite_anim(ref["tgi"])
        if anim == null:
            continue
        var rate : int = max(anim["atc"].rate, 1)
        var tick = int(sprite_clock * SPRITE_TICK_HZ / float(rate))
        if mi.get_meta("sprite_tick", -1) == tick:
            continue
        mi.set_meta("sprite_tick", tick)
        var mesh = _resolve_sprite(anim, current_s3d_zoom, tick)
        if mesh != null:
            mi.mesh = mesh

# Swaps every sprite prop to the frame and zoom matching the current view.
func _set_sprite_view(zoom : int, rot : int):
    if sprite_root == null:
        return
    for mi in sprite_root.get_children():
        var ref = mi.get_meta("sprite_ref")
        var anim = _sprite_anim(ref["tgi"])
        if anim == null:
            continue
        mi.visible = _sprite_visible_at(anim, zoom)
        if not mi.visible:
            continue
        var frame = _sprite_frame(ref, mi.get_meta("orientation", 0), rot,
            mi.get_meta("sprite_tick", 0))
        var mesh = _resolve_sprite(anim, zoom, frame)
        if mesh != null:
            mi.mesh = mesh             # else keep the previous frame

# Swaps every building to the S3D variant matching the current view. Called by
# CameraAnchor3D on zoom/rotation changes. `free_rot` >= 0 is the free-orbit
# camera's nearest rotation index (computed with sign +1; ROT_SIGN applied here).
func set_building_view(cam_zoom : int, rotated : int, free_rot : int = -1):
    if building_root == null and sprite_root == null:
        return
    var zoom = S3D_ZOOM_FOR_CAMERA[cam_zoom - 1]
    var rot : int
    var comp : float
    if free_rot >= 0:
        rot = posmod(ROT_SIGN * free_rot, 4)
        # Cancel the variant's baked rotation so the building stays world-oriented
        # while the free camera orbits it, swapping shells at 45-degree boundaries.
        comp = -ROT_SIGN * rot * PI / 2.0
    else:
        rot = posmod(ROT_SIGN * (2 - rotated), 4)
        # Counter-rotate the world rotation so the impostor always faces the fixed
        # iso camera in its authored orientation.
        comp = (rotated - 2) * PI / 2.0
    if zoom == current_s3d_zoom and rot == current_s3d_rot and comp == current_rot_comp:
        return
    current_s3d_zoom = zoom
    current_s3d_rot = rot
    current_rot_comp = comp
    if building_root != null:
        for mi in building_root.get_children():
            var ref = mi.get_meta("model_ref")
            var vrot = posmod(rot + ROT_SIGN * mi.get_meta("orientation", 0), 4)
            var model = _resolve_model(ref, zoom, vrot)
            if model != null:
                mi.mesh = model["mesh"]        # else keep the previous variant
            mi.rotation.y = comp
    _set_sprite_view(zoom, rot)

# Terrain altitude (world units) at tile coordinate (x, z), matching create_terrain's
# heightmap[z][x] convention; clamps to the map edges.
func _height_at(x : float, z : float) -> float:
    var iz = clamp(int(z), 0, self.height_map.size() - 1)
    if self.height_map.is_empty() or self.height_map[iz].is_empty():
        return 0.0
    var ix = clamp(int(x), 0, self.height_map[iz].size() - 1)
    return self.height_map[iz][ix] / TILE_SIZE

func set_cursor():
    var TGI_cur = {"T": 0xaa5c3144, "G": 0x00000032, "I":0x13b138d0}
    self.vec_hot = Core.subfile(TGI_cur["T"], TGI_cur["G"], TGI_cur["I"], CURSubfile).entries[0].vec_hotspot
    self.cur_img = Core.subfile(TGI_cur["T"], TGI_cur["G"], TGI_cur["I"], CURSubfile).get_as_texture()
    Input.set_custom_mouse_cursor(cur_img, Input.CURSOR_ARROW, vec_hot)
    
func coord_to_uv(x, y, z):
    var TerrainTexTilingFactor = 0.2 # 0x6534284a,0x88cd66e9,0x00000001 describes this as 100m of terrain corresponds to this fraction of texture in farthest zoom
    var x_factored = (float(x)*16.0/100.0) * TerrainTexTilingFactor
    var y_factored = (float(z)*16.0/100.0) * TerrainTexTilingFactor
    var temp = max(min(32-int((y-15.0) * 1.312), 31),0) # 0x6534284a,0x7a4a8458,0x1a2fdb6b describes AltitudeTemperatureFactor of 0.082, i multiplied this by 16
    
    var moist = 6
    var inst_key = $Node3D/Terrain.tm_table[temp][moist]
    return [Vector2(x_factored, y_factored), self.ind_layer[inst_key]]
    
func get_normal(vert : Vector3, heightmap):
    var min_x = 0.0
    if vert.x > 0:
        min_x = -1.0
    var max_x = 0.0
    if vert.x < (len(heightmap)-1):
        max_x = 1.0
    var min_z = 0.0
    if vert.z > 0:
        min_z = -1.0
    var max_z = 0.0
    if vert.z < (len(heightmap)-1):
        max_z = 1.0
    var vert_c = [[1.0, 0.0], [0.0, 1.0], [-1.0, 0.0], [0.0, -1.0]]
    var vertices = []
    for coord in vert_c:
        vertices.append(
            Vector3(vert.x + coord[0], 
            (heightmap[(vert.z) + min(max(coord[1], min_z), max_z)][(vert.x) + min(max(coord[0], min_x), max_x)])/16.0, 
            vert.z + coord[1])
        )
    var s_normals = Vector3(0.0, 0.0, 0.0)
    #print(vert, "\t", vertices)
    for v_i in range(len(vertices)):
        var v1 = vert
        var v2 = vertices[v_i]
        var v3 = vertices[(v_i - 1)%(len(vertices)-1)]
        var v : Vector3 = v2 - v1
        var u : Vector3 = v3 - v1
        var normal : Vector3 = v.cross(u).normalized()
        #var normal2 : Vector3 = u.cross(v)
        #print([v1, v2, v3], "\t", u, "\t", v, "\t", normal, "\t", normal2)
        s_normals = s_normals + normal
    var norm = (s_normals/len(vertices)).normalized()
    return norm
    
func test_exemplar():
    var TGI = {"T": 0x6534284a, "G": 0xea12f32c, "I": 0x5}
    var exemplar = Core.subfile(TGI["T"], TGI["G"], TGI["I"], ExemplarSubfile)
    print("ParentCohort", exemplar.parent_cohort)
    for key in exemplar.properties.keys():
        print(key, "\t", exemplar.key_description(key), "\t", exemplar.properties[key])
        
