extends RefCounted

# The catalogue of network tile pieces, read from SC4's RUL files.
#
# A RUL describes, for every combination of edge codes a tile can have (its
# WNES signature), which texture to draw and how to rotate and flip it. There
# are 24 RUL files, a basic and an advanced one per network family. This class
# loads them once, indexes them by network name and WNES, and packs every
# texture they reference into one Texture2DArray for the build tool's shader.
#
# Split out of TransitTiles.gd, which was doing this alongside input handling,
# drag solving and mesh building in one 996-line file. This half is immutable
# and shared: it depends only on the game data, not on the city, so it is built
# once and handed to whoever needs it.
class_name NetworkPieceDB

const RUL_TYPE : int = 0x0a5bcf4b
const RUL_GROUP : int = 0xaa5bcf57
const FSH_TYPE : int = 0x7ab50e44
const TRANSIT_TEXTURE_GROUP : int = 0x1abe787d
# The build tool draws at the closest zoom, where the textures are largest.
const TEXTURE_ZOOM : int = 4

# RUL instance -> network name. Each family has two: a basic and an advanced
# rule set, both indexed into the same table.
const RUL_NETWORKS : Dictionary = {
    0x01: "Elevated Highway", 0x02: "Elevated Highway",
    0x03: "WaterPipe",        0x04: "WaterPipe",
    0x05: "Rail",             0x06: "Rail",
    0x07: "Road",             0x08: "Road",
    0x09: "Street",           0x0A: "Street",
    0x0B: "Subway",           0x0C: "Subway",
    0x0D: "Avenue",           0x0E: "Avenue",
    0x0F: "Elevated Rail",    0x10: "Elevated Rail",
    0x11: "One-Way Road",     0x12: "One-Way Road",
    0x13: "Dirt Road",        0x14: "Dirt Road",
    0x15: "Monorail",         0x16: "Monorail",
    0x17: "Ground Highway",   0x18: "Ground Highway",
}

# The ground networks the build tool offers, in the order it cycles them.
const BUILDABLE : Array = [
    "Road", "Street", "Avenue", "One-Way Road", "Dirt Road", "Rail",
]

# network name -> WNES signature -> Array[TransitTile] variants.
var pieces : Dictionary = {}
# Texture2DArray layer index -> FSH instance id, in packing order.
var layer_ids : Array = []
var texture_array : Texture2DArray = null

func _init():
    _load_rules()
    _register_base_textures()
    _pack_textures()

# The ground families a network tile draws underneath its piece appear in no RUL
# file -- the save carries them per tile instead -- so they have to be added to
# the pack explicitly or a drawn road has no sidewalk to show through the gaps
# in its piece texture. See NetworkBaseTexture.
func _register_base_textures() -> void:
    for iid in NetworkBaseTexture.FAMILIES:
        if not layer_ids.has(iid) and _texture_exists(iid):
            layer_ids.append(iid)

func _load_rules() -> void:
    for rul_id in RUL_NETWORKS.keys():
        var network = RUL_NETWORKS[rul_id]
        if not pieces.has(network):
            pieces[network] = {}
        var rul = Core.subfile(RUL_TYPE, RUL_GROUP, rul_id, RULSubfile)
        if rul == null:
            continue
        for wnes in rul.RUL_wnes.keys():
            if not pieces[network].has(wnes):
                pieces[network][wnes] = []
            for variant in rul.RUL_wnes[wnes]:
                pieces[network][wnes].append(_build_piece(wnes, variant))

# One RUL variant becomes one TransitTile: its 2-lines are neighbour
# constraints, its 3-lines name a texture with a rotation and a flip.
func _build_piece(wnes, variant : Array) -> TransitTile:
    var edges := {0: wnes}
    var ids := {}
    var layers := {}
    for line in variant:
        if line[0] == 2:
            edges[line[1]] = line.slice(2, 6)
            continue
        # 3-line: [3, sub_tile, texture_iid, rotation, flip]
        ids[line[1]] = line.slice(2, 5)
        var iid = line[2]
        if not layer_ids.has(iid) and _texture_exists(iid):
            layer_ids.append(iid)
        if layer_ids.has(iid):
            layers[line[1]] = layer_ids.find(iid)
    return TransitTile.new(edges, ids, layers)

func _texture_exists(iid : int) -> bool:
    var key = [FSH_TYPE, TRANSIT_TEXTURE_GROUP]
    return Core.sub_by_type_and_group.has(key) \
        and Core.sub_by_type_and_group[key].has(iid)

# FSH images may be DXT-compressed and differently sized, so normalise each to
# RGBA8 at the first layer's size before packing -- Texture2DArray requires
# every layer to match.
func _pack_textures() -> void:
    var images : Array[Image] = []
    var ref_w := 0
    var ref_h := 0
    for iid in layer_ids:
        var fsh = Core.subfile(FSH_TYPE, TRANSIT_TEXTURE_GROUP, iid + TEXTURE_ZOOM, FSHSubfile)
        if fsh == null:
            continue
        var img : Image = fsh.img.duplicate()
        if img.is_compressed():
            img.decompress()
        img.convert(Image.FORMAT_RGBA8)
        if ref_w == 0:
            ref_w = img.get_width()
            ref_h = img.get_height()
        elif img.get_width() != ref_w or img.get_height() != ref_h:
            img.resize(ref_w, ref_h)
        images.append(img)
    if images.is_empty():
        return
    texture_array = Texture2DArray.new()
    texture_array.create_from_images(images)

# --- lookups -----------------------------------------------------------------

func has_network(network : String) -> bool:
    return pieces.has(network)

# Every variant for one network and edge signature, or an empty array.
func variants(network : String, wnes) -> Array:
    if not pieces.has(network):
        return []
    return pieces[network].get(wnes, [])

func has_shape(network : String, wnes) -> bool:
    return pieces.has(network) and pieces[network].has(wnes)

# The texture id behind a Texture2DArray layer, for handing a placed tile to
# NetworkModel: the model keys pieces by FSH id, the shader by layer index.
func texture_id_for_layer(layer : int) -> int:
    if layer < 0 or layer >= layer_ids.size():
        return 0
    return layer_ids[layer]

# The inverse: the Texture2DArray layer a texture id was packed into, or -1 if
# it is not in the pack (its FSH is missing from the loaded DATs).
func layer_for_texture(iid : int) -> int:
    return layer_ids.find(iid)

func stats() -> Dictionary:
    var shapes := 0
    for network in pieces.keys():
        shapes += pieces[network].size()
    return {"networks": pieces.size(), "shapes": shapes, "textures": layer_ids.size()}
