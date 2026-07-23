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
        if settings & 0x01:
            self.groups[grpind].alphatest = true
        if settings & 0x02:
            self.groups[grpind].depthtest = true
        if settings & 0x08:
            self.groups[grpind].backfacecull = true
        if settings & 0x10:
            self.groups[grpind].framebuffblnd = true
        if settings & 0x20:
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
        
# Builds a reusable, origin-centred model: an ArrayMesh in the S3D's own local
# space, materials baked in per surface so one model can be instanced many times
# across a city with a bare `mi.mesh = ...` assignment.
# Groups are split into two surfaces: opaque ones (alpha-scissor material) and
# blend-flagged ones -- baked ground shadows and other translucent quads -- which
# must alpha-blend; scissoring them renders semi-transparent black shadow texels
# as solid black shapes. Each surface gets its own Texture2DArray (one layer per
# group, layer index stashed in vertex COLOR.r) and a duplicate of the matching
# base material. Returns {"mesh": ArrayMesh} or {} if any group's FSH texture is
# missing from the loaded DATs (caller falls back to a different zoom LOD).
func build_model(opaque_mat_base : ShaderMaterial, blend_mat_base : ShaderMaterial) -> Dictionary:
    if self.groups.is_empty():
        return {}
    var buckets = {"opaque": [], "blend": []}   # [{group, img}]
    for group in self.groups:
        # Missing textures are expected for some zoom LODs (the caller falls back
        # to another zoom), so probe the index rather than let Core.subfile log
        # an error for every miss.
        if not Core.subfile_indices.has(SubfileTGI.TGI2str(0x7ab50e44, 0x1ABE787D, group.mat_id)):
            return {}
        var fsh = Core.subfile(0x7ab50e44, 0x1ABE787D, group.mat_id, FSHSubfile)
        if fsh == null:
            return {}
        var is_blend = group.framebuffblnd or group.group_name.to_lower().contains("shadow")
        if is_blend:
            Log.debug("S3D %08x blend group '%s': srcblend=%d destblend=%d" % [
                self.index.instance_id, group.group_name, group.srcblend, group.destblend])
        buckets["blend" if is_blend else "opaque"].append({"group": group, "img": fsh.img})

    var array_mesh : ArrayMesh = ArrayMesh.new()
    var surface := 0
    for bucket_name in ["opaque", "blend"]:
        var entries : Array = buckets[bucket_name]
        if entries.is_empty():
            continue
        # Every Texture2DArray layer must share one size + format. Decompress to
        # RGBA8: the FSH textures are DXT1 (BC1), whose 1-bit punch-through alpha
        # marks the sprite's transparent background. Godot uploads FORMAT_DXT1 to
        # the GPU as an OPAQUE BC1 format, so that alpha would be ignored and the
        # transparent (pure-black) texels would render as solid black boxes.
        var w = 0
        var h = 0
        for e in entries:
            w = max(w, e["img"].get_width())
            h = max(h, e["img"].get_height())
        var prepared : Array[Image] = []
        for e in entries:
            var im = e["img"].duplicate()
            if im.is_compressed():
                im.decompress()
            im.convert(Image.FORMAT_RGBA8)
            if im.get_width() != w or im.get_height() != h:
                im.resize(w, h)
            prepared.append(im)
        var textarr = Texture2DArray.new()
        textarr.create_from_images(prepared)

        var vertices = PackedVector3Array([])
        var UVs = PackedVector2Array([])
        var layers = PackedColorArray([])
        for layer in range(entries.size()):
            var group = entries[layer]["group"]
            var lf : float = float(layer) / 255.0
            for vertind in range(group.vertices.size() - 1, -1, -1):
                vertices.append(group.vertices[vertind])
                UVs.append(group.UVs[vertind])
                layers.append(Color(lf, 0.0, 0.0, 1.0))
        var arrays : Array = []
        arrays.resize(ArrayMesh.ARRAY_MAX)
        arrays[ArrayMesh.ARRAY_VERTEX] = vertices
        arrays[ArrayMesh.ARRAY_TEX_UV] = UVs
        arrays[ArrayMesh.ARRAY_COLOR] = layers
        array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        var mat = (blend_mat_base if bucket_name == "blend" else opaque_mat_base).duplicate()
        mat.set_shader_parameter("s3dtexture", textarr)
        array_mesh.surface_set_material(surface, mat)
        surface += 1
    if surface == 0:
        return {}
    return {"mesh": array_mesh}

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
