extends DBPFSubfile

class_name S3DSubfile

var groups = []
var max_text_width = 0
var max_text_height = 0
var formats = []

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)
    file.seek(index.location)
    var ind = 0
    assert(len(raw_data) > 0) #,"DBPFSubfile.load: no data")
    # 4 bytes (char) - signature
    var signature = raw_data.slice(ind, ind+4).get_string_from_ascii()
    assert(signature == "3DMD") #,"DBPFSubfile.load: not an FSH file")
    ind += 4
    # 4 bytes ? seems size and complexity related
    ind += 4
    "-HEAD block-"
    var h_head =  raw_data.slice(ind, ind+4).get_string_from_ascii()
    ind += 4
    var h_length = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    # seems to be always 1, might be anim related?
    ind += 2
    # seems to always be 5
    ind += 2
    if ind != h_length + 8:
        print("exception different HEAD length in %d", self.index.instance_id)
        ind = h_length + 8
        
    "-VERT block-"
    var v_vert =  raw_data.slice(ind, ind+4).get_string_from_ascii()
    ind += 4
    # seems field length for single group fields but gets freaky for multiple groups and animations
    ind += 4
    var v_grpcnt = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    var vertices = PackedVector3Array([])
    var UVs = PackedVector2Array([])
    for _grpind in range(v_grpcnt):
        var group = S3D_Group.new()
        self.groups.append(group)
        # 2 Bytes always 0?
        ind += 2
        var vert_count : int = self.get_int_from_bytes(raw_data.slice(ind, ind+2))
        ind += 2
        var format : int = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
        ind += 4
        for _i in range(vert_count):
            var x = self.get_float_from_bytes(raw_data.slice(ind, ind+4))/16.0
            ind += 4
            var y = self.get_float_from_bytes(raw_data.slice(ind, ind+4))/16.0
            ind += 4
            var z = self.get_float_from_bytes(raw_data.slice(ind, ind+4))/16.0
            ind += 4
            vertices.append(Vector3(x, y, z))
            var u = self.get_float_from_bytes(raw_data.slice(ind, ind+4))
            ind += 4
            var v = self.get_float_from_bytes(raw_data.slice(ind, ind+4))
            ind += 4
            UVs.append(Vector2(u, v))
    
    "-INDX block-"
    var i_indx =  raw_data.slice(ind, ind+4).get_string_from_ascii()
    ind += 4
    var i_length = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    var i_grpcnt = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    for grpind in range(i_grpcnt):
        # always 0?
        ind += 2
        # always 2?
        ind += 2
        var indxcnt = self.get_int_from_bytes(raw_data.slice(ind, ind+2))
        ind += 2
        for _indxind in range(indxcnt):
            var vert_indx = self.get_int_from_bytes(raw_data.slice(ind, ind+2))
            ind += 2
            var verts_tmp = self.groups[grpind].vertices
            verts_tmp.append(vertices[vert_indx])
            self.groups[grpind].vertices = verts_tmp
            var UVs_tmp = self.groups[grpind].UVs
            UVs_tmp.append(UVs[vert_indx])
            self.groups[grpind].UVs = UVs_tmp
    
    "-PRIM block-: this does nothing as everything seems to always just be triangles"
    var p_prim = raw_data.slice(ind, ind+4).get_string_from_ascii()
    ind += 4
    var p_length = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    var p_grpcnt = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    for grpind in range(p_grpcnt):
        var p_type = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
        ind += 4
        if p_type != 1:
            print("unexpected primary type in %d", self.index.instance_id)
        # 6 Bytes ???
        ind += 6
        # 4 Bytes int number of vertices
        ind += 4
    
    "-MATS block-"
    var m_mats = raw_data.slice(ind, ind+4).get_string_from_ascii()
    ind += 4
    var m_length = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    var m_grpcnt = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    for grpind in range(m_grpcnt):
        var settings = raw_data[ind]
        ind += 1
        if settings && 0x01:
            self.groups[grpind].alphatest = true
        if settings && 0x02:
            self.groups[grpind].depthtest = true
        if settings && 0x08:
            self.groups[grpind].backfacecull = true
        if settings && 0x10:
            self.groups[grpind].framebuffblnd = true
        if settings && 0x20:
            self.groups[grpind].texturing = true
        # 3 Bytes ?
        ind += 3
        self.groups[grpind].alphafunc = raw_data[ind]
        ind += 1
        self.groups[grpind].depthfunc = raw_data[ind]
        ind += 1
        self.groups[grpind].srcblend = raw_data[ind]
        ind += 1
        self.groups[grpind].destblend = raw_data[ind]
        ind += 1
        self.groups[grpind].alphathreshold = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
        ind += 4
        # 4 Bytes 0x01000000 some mask?
        ind += 4
        self.groups[grpind].mat_id = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
        ind += 4
        self.groups[grpind].wrapmodeU = raw_data[ind]
        ind += 1
        self.groups[grpind].wrapmodeV = raw_data[ind]
        ind += 1
        self.groups[grpind].magfilter = raw_data[ind]
        ind += 1
        self.groups[grpind].minfilter = raw_data[ind]
        ind += 1
        # 4 Bytes 0x00020021 (reset to zeroes when editing in reader)
        ind += 4
        var str_length = raw_data[ind]
        ind += 1
        self.groups[grpind].group_name = raw_data.slice(ind, ind+str_length).get_string_from_ascii()
        ind += str_length
        # 1 Byte end string 0x00
        ind += 1
        
        "-ANIM block- TODO"
        "-PROP block- TODO"
        "-REGP block- TODO"
        
func add_to_mesh(mesh: MeshInstance3D, location: Vector3):
    """this is temporary to test if it loads and how its size is compared to regulater terrain"""
    var vertices = PackedVector3Array([])
    var UVs = PackedVector2Array([])
    var images = []
    for group in self.groups:
        var loc_vert = PackedVector3Array([])
        var loc_UV = PackedVector2Array([])
        for vertind in range(group.vertices.size()-1, -1, -1):
            loc_vert.append(location + group.vertices[vertind])
            loc_UV.append(group.UVs[vertind])
        vertices.append_array(loc_vert)
        UVs.append_array(loc_UV)
        var image = get_texture_from_mat_id(group.mat_id)
        images.append(image)
    var fmt = self.formats[0]
    var prepared : Array[Image] = []
    for img in images:
        var im = img
        if im.get_format() != fmt:
            im = im.duplicate()
            im.convert(fmt)
        if im.get_width() != self.max_text_width or im.get_height() != self.max_text_height:
            if im == img:
                im = img.duplicate()
            im.resize(self.max_text_width, self.max_text_height)
        prepared.append(im)
    var textarr = Texture2DArray.new()
    textarr.create_from_images(prepared)

    var array_mesh : ArrayMesh = mesh.mesh
    var arrays : Array = []
    arrays.resize(ArrayMesh.ARRAY_MAX)
    arrays[ArrayMesh.ARRAY_VERTEX] = vertices
    arrays[ArrayMesh.ARRAY_TEX_UV] = UVs 
    array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.mesh = array_mesh
    var mat = mesh.get_material_override()
    mat.set_shader_parameter("s3dtexture", textarr)
    mesh.set_material_override(mat)
    
# Builds a reusable, origin-centred model: an ArrayMesh in the S3D's own local
# space plus a Texture2DArray of its group textures. Unlike add_to_mesh (which
# bakes a single world location and mutates a passed node), this returns the
# resources so one model can be instanced many times across a city.
# Returns {"mesh": ArrayMesh, "texture": Texture2DArray} or null if empty.
func build_instance():
    if self.groups.is_empty():
        return null
    var images = []
    for group in self.groups:
        var img = get_texture_from_mat_id(group.mat_id)
        if img == null:
            # A group's texture isn't in the loaded DATs (happens for some zoom
            # LODs). Bail so the caller can fall back to a different LOD.
            return null
        images.append(img)
    if images.is_empty() or self.formats.is_empty():
        return null
    # Texture2DArray requires every layer to share one size and format.
    var fmt = self.formats[0]
    var w = self.max_text_width
    var h = self.max_text_height
    var prepared : Array[Image] = []
    for img in images:
        var im = img
        if im.get_format() != fmt:
            im = im.duplicate()
            im.convert(fmt)
        if im.get_width() != w or im.get_height() != h:
            if im == img:
                im = img.duplicate()
            im.resize(w, h)
        prepared.append(im)
    var textarr = Texture2DArray.new()
    textarr.create_from_images(prepared)

    # Each group's texture is a separate Texture2DArray layer (same order as
    # `prepared` above). Stash the group's layer index in the vertex COLOR so the
    # shader can sample the right layer instead of always layer 0 -- otherwise
    # secondary groups (e.g. a building's semi-transparent shadow quad) render
    # with the wrong opaque texture and show up as a black box.
    var vertices = PackedVector3Array([])
    var UVs = PackedVector2Array([])
    var layers = PackedColorArray([])
    var layer := 0
    for group in self.groups:
        var lf : float = float(layer) / 255.0
        for vertind in range(group.vertices.size() - 1, -1, -1):
            vertices.append(group.vertices[vertind])
            UVs.append(group.UVs[vertind])
            layers.append(Color(lf, 0.0, 0.0, 1.0))
        layer += 1
    var array_mesh : ArrayMesh = ArrayMesh.new()
    var arrays : Array = []
    arrays.resize(ArrayMesh.ARRAY_MAX)
    arrays[ArrayMesh.ARRAY_VERTEX] = vertices
    arrays[ArrayMesh.ARRAY_TEX_UV] = UVs
    arrays[ArrayMesh.ARRAY_COLOR] = layers
    array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return {"mesh": array_mesh, "texture": textarr}

func get_texture_from_mat_id(iid):
    var fsh_subfile = Core.subfile(
                        0x7ab50e44, 0x1ABE787D, iid, FSHSubfile
                        )
    if fsh_subfile == null:
        return null
    if self.max_text_width < fsh_subfile.width:
        self.max_text_width = fsh_subfile.width
    if self.max_text_height < fsh_subfile.height:
        self.max_text_height = fsh_subfile.height
    self.formats.append(fsh_subfile.img.get_format())
    return fsh_subfile.img
    
    
func get_int_from_bytes(bytearr):
    var r_int = 0
    var shift = 0
    for byte in bytearr:
        r_int = (r_int) | (byte << shift)
        shift += 8
    return r_int
    
func get_float_from_bytes(bytearr):
    var buff = StreamPeerBuffer.new()
    buff.data_array = bytearr
    return buff.get_float()
