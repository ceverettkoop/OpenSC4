extends RefCounted

# Air pollution as a field: building sources stamped onto the map plus a
# traffic term, recomputed whole every tick. Writes SimGrids.DERIVED_AIR_POLLUTION
# in the 0..1024 domain -- that is the "Maximum scale" SC4's own Air Pollution
# data view declares (exemplar property 0x4A0B47EC), so the authentic ramp
# renders it without further scaling.
#
# Sources come from the occupants' exemplars: "Pollution at centre"
# (0x27812851, [air, water, garbage, radiation] -- signed, trees absorb) and
# "Pollution Radius" (0x68EE9764, radii in tiles). Growable buildings carry
# these on their FAMILY COHORT, not their own exemplar, which is what
# Core.exemplar_prop's cohort-chain walk exists for. Each source contributes
# magnitude * (1 - d / (radius + 1)) out to its radius, and contributions sum.
#
# IMPORTANT calibration caveat: the shipped saves store NO air pollution grid
# to calibrate against. The layers dev_notes/simulation_plan.md nominated as
# "prime candidates" (0x49D5B964 / 0x49D5B953) turned out to be the
# FLAMMABILITY pair once crosstabbed per building (see SimGridSubfile) -- and
# every other 128x128 layer identified as zone type, power or wealth codes.
# So like land value, pollution is recomputed by SC4 at load and never saved.
# The SOURCE terms above are SC4's own numbers off the DATs; the two scale
# constants below are OURS, chosen so a dirty-industry cluster saturates
# around the view's yellow-orange band. The harness therefore gates structure
# (industry pollutes more than residential, determinism, edit response), not
# a saved target.
class_name PollutionSim

const PROP_POLLUTION_CENTRE : int = 0x27812851
const PROP_POLLUTION_RADIUS : int = 0x68EE9764

# Invented (see above): stamp sum -> 0..1024 domain, and the "Traffic air
# pollution factor" 0.25 from the Utilities exemplar (G 0xE7E2C2DB
# I 0xC911E35B, property 0x69501944) applied to per-tile traffic volume.
# SOURCE_SCALE is sized to the measured stamp-sum distribution (p99 ~450,
# max ~480 on Big City Tutorial's industrial core): 2.0 puts the dirtiest
# cluster near the top of the domain WITHOUT clamping it flat -- at 25 the
# entire industrial zone pegged at 1024 and the field lost its gradient.
const SOURCE_SCALE : float = 2.0
const TRAFFIC_FACTOR : float = 0.25
const DOMAIN_MAX : float = 1024.0

var city = null                  # City.gd node; the hub every model hangs off
var _sources : Array = []        # of [cell: Vector2i, magnitude: float, radius: float]
var _sources_dirty : bool = true

func _init(city_):
    city = city_
    if city.lot_model != null:
        # A razed lot takes its buildings' pollution with it.
        city.lot_model.lots_changed.connect(func(_cells): _sources_dirty = true)

# The monthly system entry point, registered with Simulation.
func tick(_month : int) -> void:
    var grids : SimGrids = city.sim_grids_model()
    var side : int = grids.map_tiles
    if _sources_dirty:
        _rebuild_sources()
    var field : Array = []
    field.resize(side * side)
    field.fill(0.0)
    for src in _sources:
        _stamp(field, side, src[0], src[1] * SOURCE_SCALE, src[2])
    _add_traffic(field, side, grids)
    for i in range(field.size()):
        field[i] = clampf(field[i], 0.0, DOMAIN_MAX)
    grids.commit_derived(SimGrids.DERIVED_AIR_POLLUTION, field, side)

# Occupant sources from the building records the city kept. A building whose
# lot has been bulldozed is gone: its cell is in the lot model's map but no
# longer resolves to a lot. Buildings that never had a lot (rare civic edge
# cases) always count.
func _rebuild_sources() -> void:
    _sources_dirty = false
    _sources = []
    for rec in city.building_records:
        var cell : Vector2i = occupant_cell(rec)
        if _razed(cell):
            continue
        var centre = Core.exemplar_prop(rec.exemplar_tgi[1], rec.exemplar_tgi[2], PROP_POLLUTION_CENTRE)
        var radius = Core.exemplar_prop(rec.exemplar_tgi[1], rec.exemplar_tgi[2], PROP_POLLUTION_RADIUS)
        if typeof(centre) != TYPE_ARRAY or typeof(radius) != TYPE_ARRAY \
                or centre.is_empty() or radius.is_empty():
            continue
        var mag : float = _signed32(centre[0])
        var rad : float = radius[0]
        if mag != 0.0 and rad > 0.0:
            _sources.append([cell, mag, rad])

func _razed(cell : Vector2i) -> bool:
    var lots = city.lot_model
    return lots != null and lots.by_cell.has(cell) and lots.lot_at(cell) == null

static func _stamp(field : Array, side : int, cell : Vector2i, magnitude : float, radius : float) -> void:
    var r : int = int(radius)
    for dx in range(-r, r + 1):
        for dz in range(-r, r + 1):
            var x : int = cell.x + dx
            var z : int = cell.y + dz
            if x < 0 or z < 0 or x >= side or z >= side:
                continue
            var dist : float = sqrt(float(dx * dx + dz * dz))
            if dist <= radius:
                field[x * side + z] += magnitude * (1.0 - dist / (radius + 1.0))

# Traffic volumes: the save's own TRAFFIC_TOTAL when it exists -- SC4's
# simulator is the better-calibrated source, and the land-value constants
# were fitted against it -- falling back to our own assignment
# (DERIVED_TRAFFIC, step 4) on saves that carry no traffic snapshot. Once
# our volumes are validated for MAGNITUDE (the harness currently gates only
# their shape), flipping this preference is the intended next step.
func _add_traffic(field : Array, side : int, grids : SimGrids) -> void:
    var traffic = grids.grid(SimGridSubfile.TRAFFIC_TOTAL)
    if traffic == null:
        traffic = grids.grid(SimGrids.DERIVED_TRAFFIC)
    if traffic == null:
        return
    for x in range(side):
        for z in range(side):
            var v : float = traffic.at_tile(x, z, side)
            if v > 0.0:
                field[x * side + z] += TRAFFIC_FACTOR * v

static func _signed32(v : int) -> float:
    return float(v - (1 << 32)) if v >= (1 << 31) else float(v)

# The tile an occupant record stands on -- City.occupant_cell, duplicated
# because City.gd has no class_name to reference without a load cycle.
static func occupant_cell(rec) -> Vector2i:
    return Vector2i(int(rec.pos_x / 16.0), int(rec.pos_z / 16.0))
