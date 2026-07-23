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

# Shared placement loop for occupant records (buildings, props, flora). Records
# need exemplar_tgi, pos_x, pos_z and orientation. The occupant's own world
# orientation is folded into which S3D rotation variant is displayed (rotating
# the impostor mesh itself would break the fixed-camera illusion).
func _place_occupants(recs : Array, what : String):
    var placed = 0
    var no_model = 0
    for rec in recs:
        var ref = _model_ref_for_exemplar(rec.exemplar_tgi)
        if ref == null:
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
    Log.info("Placed %d %s (%d without a resolvable model)" % [placed, what, no_model])

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

# Swaps every building to the S3D variant matching the current view. Called by
# CameraAnchor3D on zoom/rotation changes. `free_rot` >= 0 is the free-orbit
# camera's nearest rotation index (computed with sign +1; ROT_SIGN applied here).
func set_building_view(cam_zoom : int, rotated : int, free_rot : int = -1):
    if building_root == null:
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
    for mi in building_root.get_children():
        var ref = mi.get_meta("model_ref")
        var vrot = posmod(rot + ROT_SIGN * mi.get_meta("orientation", 0), 4)
        var model = _resolve_model(ref, zoom, vrot)
        if model != null:
            mi.mesh = model["mesh"]        # else keep the previous variant
        mi.rotation.y = comp

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
        
