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
        load_buildings()

# Reads the city's Building occupant subfile and renders each placed building:
# occupant record -> building exemplar -> RKT -> S3D model (cached per model),
# instanced at the record's world position on the terrain.
func load_buildings():
    var bindex = savefile.indices_by_type.get(0xa9bd882d, [])
    if bindex.is_empty():
        Log.info("City has no building subfile")
        return
    var idx = bindex[0]
    var bsub = savefile.get_subfile(idx.type_id, idx.group_id, idx.instance_id, BuildingSubfile)
    Log.info("Building subfile: %d records" % bsub.records.size())

    var root = Node3D.new()
    root.name = "Buildings"
    $Node3D.add_child(root)
    var base_mat : ShaderMaterial = $Node3D/TestS3D.get_material_override()

    var model_cache = {}      # S3D TGI string -> {"mesh":, "material":} (or null)
    var placed = 0
    var no_model = 0
    for rec in bsub.records:
        var model = _model_for_exemplar(rec.exemplar_tgi, model_cache, base_mat)
        if model == null:
            no_model += 1
            continue
        var mi = MeshInstance3D.new()
        mi.mesh = model["mesh"]
        mi.material_override = model["material"]
        var x = rec.pos_x / TILE_SIZE
        var z = rec.pos_z / TILE_SIZE
        mi.position = Vector3(x, _height_at(x, z), z)
        root.add_child(mi)
        placed += 1
    Log.info("Placed %d buildings (%d without a resolvable model)" % [placed, no_model])

# SC4 building models are referenced via ResourceKeyType1 (RKT1, exemplar property
# 0x27812821): the stored instance id is a BASE, and the real S3D models fan out as
# 5 zoom levels x 4 rotations, encoded  iid = base + (zoom << 8) + (rotation << 4).
# The base itself is zoom 0 (coarsest LOD), which is why buildings rendered blurry.
const RKT1_PROP : int = 0x27812821
const LOD_ZOOM : int = 4        # highest detail; modern HW renders full LOD at all camera distances
const LOD_ROTATION : int = 0

# Ordered list of candidate model TGIs for an exemplar's S3D reference, highest
# LOD first. For RKT1 refs that's zoom 4 -> 0 (rotation 0); a non-RKT1 / explicit
# ref is its single self. Not every zoom's S3D or its textures are present in the
# loaded DATs, so the caller tries these in order and takes the first that builds.
func _lod_candidates(ref : Dictionary) -> Array:
    var tgi : Array = ref["tgi"]
    if ref["prop_key"] != RKT1_PROP:
        return [tgi]
    var out = []
    for zoom in range(LOD_ZOOM, -1, -1):
        out.append([tgi[0], tgi[1], tgi[2] + (zoom << 8) + (LOD_ROTATION << 4)])
    return out

# Resolves a building exemplar to a cached model, loading + building it on first
# use. Falls back down the LOD list when the highest zoom's S3D or textures are
# missing from the loaded DATs.
func _model_for_exemplar(exemplar_tgi : Array, cache : Dictionary, base_mat : ShaderMaterial):
    if not Core.subfile_indices.has(SubfileTGI.TGI2str(exemplar_tgi[0], exemplar_tgi[1], exemplar_tgi[2])):
        return null
    var exemplar = Core.subfile(exemplar_tgi[0], exemplar_tgi[1], exemplar_tgi[2], ExemplarSubfile)
    var refs = exemplar.get_all_model_refs()
    if refs.is_empty():
        return null
    var ref = refs[0]
    var is_rkt1 = (ref["prop_key"] == RKT1_PROP)
    for model_tgi in _lod_candidates(ref):
        var key = SubfileTGI.TGI2str(model_tgi[0], model_tgi[1], model_tgi[2])
        if cache.has(key):
            if cache[key] != null:
                return cache[key]
            continue                       # known-unbuildable at this LOD, try next
        if not Core.subfile_indices.has(key):
            cache[key] = null
            continue
        var built = _build_model(model_tgi, is_rkt1)
        if built.is_empty():
            cache[key] = null
            continue
        var mat = base_mat.duplicate()
        mat.set_shader_parameter("s3dtexture", built["texture"])
        var model = {"mesh": built["mesh"], "material": mat}
        cache[key] = model
        return model
    return null

# Builds the renderable mesh+texture for a rotation-0 S3D TGI. RKT1 models are 2.5D
# per rotation, so this composites rotation 0 (full: walls + roof) with rotation 2
# (walls only, turned 180 degrees) into a four-walled mesh. Non-RKT1 / explicit
# models have no rotation family and use their single variant as-is. Returns {} if
# the model's textures aren't in the loaded DATs (caller falls back to a lower LOD).
func _build_model(rot0_tgi : Array, is_rkt1 : bool) -> Dictionary:
    var s3d0 = Core.subfile(rot0_tgi[0], rot0_tgi[1], rot0_tgi[2], S3DSubfile)
    # Rotation 0 provides the full model (walls + roof). The other three rotations,
    # turned back to canonical (+rot*90 deg) and reduced to their walls, fill in the
    # remaining sides and corners without their roofs z-fighting rotation 0's.
    var variants = [{"s3d": s3d0, "angle": 0.0, "walls_only": false, "scale": 1.0}]
    if is_rkt1:
        # rotation -> [canonicalizing angle, XZ inset]. The inset nests each variant
        # a hair inside the last so overlapping walls resolve by depth, not z-fight.
        for spec in [[1, PI / 2.0, 0.99], [2, PI, 0.98], [3, -PI / 2.0, 0.97]]:
            var iid = rot0_tgi[2] + (spec[0] << 4)
            if Core.subfile_indices.has(SubfileTGI.TGI2str(rot0_tgi[0], rot0_tgi[1], iid)):
                var s3d = Core.subfile(rot0_tgi[0], rot0_tgi[1], iid, S3DSubfile)
                variants.append({"s3d": s3d, "angle": spec[1], "walls_only": true, "scale": spec[2]})
    return S3DSubfile.build_composite(variants)

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
        
