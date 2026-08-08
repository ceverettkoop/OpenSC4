extends DBPFSubfile

class_name ExemplarSubfile

var parent_cohort = {}
var num_properties: int
var properties = {}
var ind
var keys_dict = {}

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)
    file.seek(index.location)
    ind = 0
    assert(len(raw_data) > 0) #,"DBPFSubfile.load: no data")
    # 4 bytes (char) - signature. EQZB is an exemplar, CQZB a cohort (type
    # 0x05342861); the two formats are byte-identical after the signature,
    # and cohorts are what growable buildings inherit their simulation
    # properties (pollution, flammability...) from -- see Core.exemplar_prop.
    var signature = raw_data.slice(ind, ind+4).get_string_from_ascii()
    assert(signature == "EQZB" or signature == "CQZB") #,"DBPFSubfile.load: not an Exemplar/Cohort file")
    ind += 4
    # 4 bytes - parent cohort indicator always 0x23232331
    ind += 4
    self.parent_cohort["T"] = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    self.parent_cohort["G"] = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    self.parent_cohort["I"] = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    self.num_properties = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
    ind += 4
    for _property in range(self.num_properties):
        var key = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
        ind += 4
        # 1 Byte spacing always 0x00
        ind += 1
        var type = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
        ind += 4
        var multi :bool = (type & 0xF000) > 0
        var format :int = type & 0xF
        var value
        var length = 1
        if multi:
            length = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
            ind += 4
            if format == 0xC: #string
                # `length` is the exact byte count -- exemplar strings are NOT
                # NUL-terminated (verified: 0 of 9,230 string properties across
                # the eight shipped DATs end in 0x00), so slicing to length-1
                # dropped the final character of every name ("Constructio").
                value = raw_data.slice(ind, ind+length).get_string_from_ascii()
                ind += length
            else:
                value = []
                for _i in range(length):
                    value.append(self.val_from_format(format))
        else:
            value = self.val_from_format(format)
        self.properties[key] = value
    return OK

    
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
    
func val_from_format(format):
    "storing less thant 32bit ints as 32bit ints seems bad, should do this in C++ to remedy that"
    if format == 0x1: #Uint8
        var val = raw_data[ind]
        ind += 1
        return val
    elif format == 0x2: #Uint16 not used?
        var val = self.get_int_from_bytes(raw_data.slice(ind, ind+2))
        ind += 2
        return val
    elif format == 0x3: #Uint32
        var val = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
        ind += 4
        return val
    elif format == 0x4:  #Uint64? not used?
        var val = self.get_int_from_bytes(raw_data.slice(ind, ind+8))
        ind += 8
        return val
    elif format == 0x5: #int8? not used?
        var val = raw_data[ind]
        ind += 1
        return val
    elif format == 0x6: #int16? not used?
        var val = self.get_int_from_bytes(raw_data.slice(ind, ind+2))
        ind += 2
        return val
    elif format == 0x7: #int32? not used?
        var val = self.get_int_from_bytes(raw_data.slice(ind, ind+4))
        ind += 4
        return val
    elif format == 0x8: #int64? not used?
        var val = self.get_int_from_bytes(raw_data.slice(ind, ind+8))
        ind += 8
        return val
    elif format == 0x9: #float32
        var val = self.get_float_from_bytes(raw_data.slice(ind, ind+4))
        ind += 4
        return val
    elif format == 0xA: #float64?
        var val = self.get_float_from_bytes(raw_data.slice(ind, ind+8))
        ind += 8
        return val
    elif format == 0xB: #bool
        var val = raw_data[ind]
        ind += 1
        return (val != 0)
    else:
        print("ERROR, unkown format: %d", format)
        
const S3D_TYPE : int = 0x5ad0e817
const ATC_TYPE : int = 0x29a5d1ec

# Returns the [type, group, instance] of this exemplar's S3D model, or null.
# Works across every ResourceKeyType variant (RKT0/1/4/5) by scanning property
# values for the S3D type marker and reading the following two ids as group and
# instance -- the same approach as tools/dat_dump.py scan_s3d_refs().
func get_model_tgi():
    for key in self.properties.keys():
        var value = self.properties[key]
        if typeof(value) != TYPE_ARRAY:
            continue
        for i in range(value.size() - 2):
            if value[i] == S3D_TYPE:
                return [value[i], value[i + 1], value[i + 2]]
    return null

# Returns every S3D [type, group, instance] reference embedded in this exemplar's
# array-valued properties, each tagged with the property key (RKT variant) it came
# from. The key matters: an RKT1 (0x27812821) ref is a *base* instance that fans
# out to 5 zoom x 4 rotation models, so the caller must offset it to pick an LOD.
func get_all_model_refs() -> Array:
    return _scan_refs(S3D_TYPE)

# The sprite counterpart of get_all_model_refs(). Props with no 3D model at all
# -- traffic lights, animated balloons, the exploratorium -- reference an ATC
# animation header (see ATCSubfile.gd) instead, normally under ResourceKeyType0.
func get_all_sprite_refs() -> Array:
    return _scan_refs(ATC_TYPE)

# Scans array-valued properties for `type_id` followed by two more ids, and
# returns each hit as {"prop_key": <RKT variant>, "tgi": [type, group, instance]}.
func _scan_refs(type_id : int) -> Array:
    var refs = []
    for key in self.properties.keys():
        var value = self.properties[key]
        if typeof(value) != TYPE_ARRAY:
            continue
        var i = 0
        while i <= value.size() - 3:
            if value[i] == type_id:
                refs.append({"prop_key": key, "tgi": [value[i], value[i + 1], value[i + 2]]})
                i += 3   # skip past the triple we just consumed
            else:
                i += 1
    return refs

func key_description(key):
    if len(self.keys_dict) == 0:
        var file = FileAccess.open("res://exemplar_types.dict", FileAccess.READ)
        self.keys_dict = str_to_var(file.get_as_text())
        file.close()
    var ret = null
    if self.keys_dict.keys().has(key):
        ret = self.keys_dict[key]
    return ret
    


