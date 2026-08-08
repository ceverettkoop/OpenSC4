extends RefCounted

# SC4's data-view definitions, read from the game's own DataView exemplars
# (group 0x690F693F "DATA_VIEW_PARENTS", ~30 of them in SimCity_1.dat). Each
# carries a display name, a colour ramp of (threshold, 0xAARRGGBB) stops, and
# a "data source" -- a SMALL ENUM private to the view system (Land value = 2),
# NOT the savegame SimGrid dataId. Nothing on disc links the enum to a dataId,
# so the pairs we know are hand-curated in DATA_SOURCE_TO_GRID below, each
# with its evidence.
#
# The group also holds unrelated exemplars (Drive-vehicle panels, trend bars);
# anything without a colour ramp is skipped. The views' shared parent cohort
# (type 0x05342861, I=0x4A0B6700) has signature CQZB, which ExemplarSubfile
# (asserts EQZB) cannot parse -- deliberately NOT requested. The view
# exemplars carry their own ramps, so cohort property inheritance is not
# needed; if a future view genuinely needs it, that is an ExemplarSubfile
# change, not a workaround here.
class_name DataViewCatalogue

const EXEMPLAR_TYPE : int = 0x6534284a
const GROUP_DATA_VIEWS : int = 0x690f693f    # Core group_dict "DATA_VIEW_PARENTS"

const PROP_NAME : int = 0x00000020           # "Exemplar Name"
const PROP_COLOUR_RAMP : int = 0x4a0b47e4    # flat u32 array: t0,c0,t1,c1,...
const PROP_DATA_SOURCE : int = 0x4a0b47e5    # view-system enum, see above
const PROP_ZONE_OPACITY : int = 0x4a0b47e6   # 0..100
const PROP_INTERPOLATE : int = 0x4a0b47e7    # SC4 smooths between cells when set
const PROP_MAX_SCALE : int = 0x4a0b47ec      # top of the view's value domain

# data-source enum -> SimGrid dataId, saved or derived. Provenance per entry:
#   2 (Land value) -> OCCUPANT_CODE, the save's wealth grid (decode evidence
#        on SimGridSubfile.OCCUPANT_CODE_WEALTH). What actually renders is
#        City's affair: live simulated land value once the simulation has
#        produced one, live lot wealth otherwise -- the saved grid stays the
#        load-time identification gate either way.
#   8 (Air pollution) -> our simulated field (no save stores one; the
#        candidates the plan nominated decoded as flammability, see
#        SimGridSubfile.FLAMMABILITY_BASE). The field lives in the view's
#        own declared domain: "Maximum scale" = 1024, ramp stops 128..255,
#        hence the air_to_ramp transform below.
# The remaining enums stay unmapped until their grid exists: 4 is shared by
# the Crime AND Police views, so it cannot carry a single mapping -- those
# two are wired by NAME below.
const DATA_SOURCE_TO_GRID : Dictionary = {
    2: SimGridSubfile.OCCUPANT_CODE,
    8: SimGrids.DERIVED_AIR_POLLUTION,
}

# Lowercased view name -> dataId, for views whose data-source enum is
# ambiguous (Crime and Police share enum 4). Wins over the enum table.
const NAME_TO_GRID : Dictionary = {
    "crime": SimGrids.DERIVED_CRIME,
    "police": SimGrids.DERIVED_POLICE_COVERAGE,
}

# Wealth class -> representative land value, fed to the authentic Land value
# colour ramp. The Land Value Sim exemplar (G 0xE7E2C2DB I 0xE7E2C8D8,
# property 0x47E2C301) puts the wealth boundaries at [70, 120]: land value
# below 70 is $, 70..120 is $$, above is $$$. Midpoints of those bands (and 0
# for undeveloped) give each wealth class SC4's own colour for it.
const WEALTH_TO_LAND_VALUE : Array = [0.0, 35.0, 95.0, 180.0]

# Grid transform for the Land value view: occupant code -> wealth class ->
# representative land value in the ramp's 0..255 domain.
static func wealth_code_to_land_value(code : float) -> float:
    var wealth : int = SimGridSubfile.OCCUPANT_CODE_WEALTH.get(int(code), 0)
    return WEALTH_TO_LAND_VALUE[wealth]

# Grid transform for the Air Pollution view: the field lives in 0..1024 (the
# view's own "Maximum scale") but the ramp's stops run 128..255 -- below the
# midpoint the view is transparent, i.e. light pollution does not colour the
# ground. Linear map of the domain onto that stop range.
static func air_to_ramp(value : float) -> float:
    return 128.0 + 127.0 * clampf(value / 1024.0, 0.0, 1.0)

class DataView:
    var instance_id : int = 0
    var name : String = ""       # "Land value" -- "DataView: " prefix stripped
    var data_source : int = -1   # raw enum from the exemplar, -1 if absent
    var data_id : int = 0        # SimGrid dataId, 0 = no known mapping
    var ramp : Array = []        # of {"t": int, "color": Color}, ascending t
    var interpolate : bool = false
    var zone_opacity : int = 100
    var max_scale : int = 0      # top of the value domain, 0 = not declared
    var transform : Callable = Callable()   # raw grid value -> ramp domain

    # Raw grid value -> the value the ramp is indexed by. Identity unless the
    # view needs a decode step (the Land value view's occupant codes).
    func ramp_value(value : float) -> float:
        if transform.is_valid():
            return transform.call(value)
        return value

    # Colour for a raw grid value: piecewise over the ramp stops, lerping
    # between them when the view asks for interpolation (colour-domain only
    # -- SC4's spatial cell smoothing is a renderer concern, not handled
    # here), stepping otherwise. Clamps outside the ramp's range.
    func color_for(value : float) -> Color:
        if ramp.is_empty():
            return Color(0, 0, 0, 0)
        if value <= ramp[0]["t"]:
            return ramp[0]["color"]
        for i in range(1, ramp.size()):
            if value <= ramp[i]["t"]:
                if not interpolate:
                    return ramp[i - 1]["color"]
                var lo : float = ramp[i - 1]["t"]
                var hi : float = ramp[i]["t"]
                var f : float = 0.0 if hi <= lo else (value - lo) / (hi - lo)
                return ramp[i - 1]["color"].lerp(ramp[i]["color"], f)
        return ramp[-1]["color"]

var views : Array = []           # of DataView, catalogue load order
var _by_name : Dictionary = {}   # lowercased name -> DataView

# Reads every renderable data view out of the loaded DATs. Returns the count.
func load_from_core() -> int:
    var by_iid : Dictionary = Core.sub_by_type_and_group.get(
        [EXEMPLAR_TYPE, GROUP_DATA_VIEWS], {})
    var iids : Array = by_iid.keys()
    iids.sort()
    for iid in iids:
        var ex = Core.subfile(EXEMPLAR_TYPE, GROUP_DATA_VIEWS, iid, ExemplarSubfile)
        if ex == null or not ex.properties.has(PROP_COLOUR_RAMP):
            continue
        var view = _parse_view(ex, iid)
        if view == null:
            continue
        views.append(view)
        _by_name[view.name.to_lower()] = view
    return views.size()

func view_named(name : String):
    return _by_name.get(name.to_lower())

# The views that resolve to a known SimGrid layer -- the ones we can render.
func mapped_views() -> Array:
    var out : Array = []
    for view in views:
        if view.data_id != 0:
            out.append(view)
    return out

func _parse_view(ex : ExemplarSubfile, iid : int):
    var raw_ramp = ex.properties.get(PROP_COLOUR_RAMP)
    if typeof(raw_ramp) != TYPE_ARRAY or raw_ramp.size() < 4 or raw_ramp.size() % 2 != 0:
        return null
    var view := DataView.new()
    view.instance_id = iid
    var raw_name = ex.properties.get(PROP_NAME, "")
    view.name = str(raw_name).trim_prefix("DataView: ").trim_prefix("DataView; ")
    for i in range(0, raw_ramp.size(), 2):
        view.ramp.append({"t": int(raw_ramp[i]), "color": _argb(int(raw_ramp[i + 1]))})
    var source = ex.properties.get(PROP_DATA_SOURCE)
    if typeof(source) == TYPE_INT:
        view.data_source = source
        view.data_id = DATA_SOURCE_TO_GRID.get(source, 0)
        if source == 2:
            view.transform = Callable(DataViewCatalogue, "wealth_code_to_land_value")
        elif source == 8:
            view.transform = Callable(DataViewCatalogue, "air_to_ramp")
    if NAME_TO_GRID.has(view.name.to_lower()):
        view.data_id = NAME_TO_GRID[view.name.to_lower()]
    view.interpolate = bool(ex.properties.get(PROP_INTERPOLATE, false))
    var opacity = ex.properties.get(PROP_ZONE_OPACITY)
    if typeof(opacity) == TYPE_INT:
        view.zone_opacity = opacity
    var max_scale = ex.properties.get(PROP_MAX_SCALE)
    if typeof(max_scale) == TYPE_INT:
        view.max_scale = max_scale
    return view

# Ramp colours are 0xAARRGGBB (Land value runs 0x99FF0000 red -> 0x9900FF00
# green, alpha 0x99).
static func _argb(c : int) -> Color:
    return Color(
        ((c >> 16) & 0xff) / 255.0,
        ((c >> 8) & 0xff) / 255.0,
        (c & 0xff) / 255.0,
        ((c >> 24) & 0xff) / 255.0)
