extends RefCounted

# The authoritative map of which lot occupies which city tile.
#
# The same role NetworkModel plays for network tiles, and for the same reason:
# a lot's visuals are scattered across five subfiles (buildings, props, flora,
# base textures, foundations/retaining walls) with nothing tying them back to
# the lot they belong to, so "remove this lot" has no single place to happen
# unless one exists. Every mutation goes through here and reports the cells it
# freed; City.gd rebuilds the affected batches off that, and the build tools
# never touch geometry directly.
#
# Only GROWABLE lots can be bulldozed by the road tool. SC4 lets a road eat a
# zoned building that got in its way, but not a stadium or a power plant -- a
# plopped lot has to be demolished deliberately. `zone_type` is the only thing
# that separates them, so it is the whole test (see is_growable).
class_name LotModel

# zone_type: 1-3 residential low/med/high, 4-6 commercial, 7-9 industrial.
# 15 is a plopped building; the values between are the plopped special zones
# (military, airport, seaport, landfill), which are equally not growable.
const ZONE_GROWABLE_FIRST : int = 1
const ZONE_GROWABLE_LAST : int = 9

signal lots_changed(cells : Array)

# Every lot record from the save, in file order. Never mutated -- a bulldozed
# lot is recorded in `_removed` rather than spliced out, because the save's
# subfiles still contain it and the renderers index into them by record.
var lots : Array = []
# Vector2i -> LotSubfile.LotRecord. A lot covering nine tiles appears nine times.
var by_cell : Dictionary = {}
# The lots that have been bulldozed, as an identity set.
var _removed : Dictionary = {}

static func is_growable(lot) -> bool:
    return lot.zone_type >= ZONE_GROWABLE_FIRST and lot.zone_type <= ZONE_GROWABLE_LAST

func seed_from_save(records : Array) -> void:
    lots = records
    by_cell = {}
    for lot in records:
        for cell in cells_of(lot):
            # Lot rects do overlap in some saves -- a plopped lot placed over an
            # older one leaves the loser's rect behind. Last writer wins, which
            # matches the draw order.
            by_cell[cell] = lot
    lots_changed.emit(by_cell.keys())

static func cells_of(lot) -> Array:
    var out : Array = []
    for x in range(lot.min_x, lot.max_x + 1):
        for z in range(lot.min_z, lot.max_z + 1):
            out.append(Vector2i(x, z))
    return out

func lot_at(cell : Vector2i):
    var lot = by_cell.get(cell)
    return null if lot == null or _removed.has(lot) else lot

func has_lot(cell : Vector2i) -> bool:
    return lot_at(cell) != null

func size() -> int:
    return lots.size() - _removed.size()

# The distinct lots covering any of `cells`. `growable_only` is what the build
# tools pass: a road drag may flatten a zoned building but must leave a plopped
# one standing.
func lots_over(cells : Array, growable_only : bool = true) -> Array:
    var seen := {}
    var out : Array = []
    for cell in cells:
        var lot = lot_at(cell)
        if lot == null or seen.has(lot):
            continue
        if growable_only and not is_growable(lot):
            continue
        seen[lot] = true
        out.append(lot)
    return out

# Removes whole lots -- never part of one. A road clipping the corner of a
# house takes the whole house, which is what SC4 does and what keeps the model
# consistent: half a lot has no meaning in any of the subfiles.
#
# Returns every cell freed, which is what City.gd rebuilds against.
func remove(to_remove : Array) -> Array:
    var freed : Array = []
    for lot in to_remove:
        if _removed.has(lot):
            continue
        _removed[lot] = true
        freed.append_array(cells_of(lot))
    if freed.is_empty():
        return []
    lots_changed.emit(freed)
    return freed

func zone_histogram() -> Dictionary:
    var hist : Dictionary = {}
    for lot in lots:
        if _removed.has(lot):
            continue
        hist[lot.zone_type] = hist.get(lot.zone_type, 0) + 1
    return hist
