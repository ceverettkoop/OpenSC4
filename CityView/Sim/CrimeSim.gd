extends RefCounted

# Crime as a field: criminality sourced on developed tiles, damped by police
# coverage. Writes SimGrids.DERIVED_CRIME (0..255, the Crime view's ramp
# domain) and SimGrids.DERIVED_POLICE_COVERAGE (raw coverage strength).
#
# The shape follows the Crime Simulator exemplar (T 0x6534284A G 0xE7E2C2DB
# I 0xC8E8F6C5): base criminality per wealth class falls as wealth rises
# (the "R$/R$$/R$$$ EQ -> Base Criminality" curves open at 0.15 / 0.10 /
# 0.07), land value depresses it further, and police protection attenuates
# what remains ("Police Protection -> Crime Attenuation" = 0.8). Police
# coverage comes from the stations' own exemplars: "Police Station, Centre
# Strength" (0x48D71ED0) and "Police Station, Radius" in METRES (0x48D71ED2),
# stamped with linear falloff like every other radial effect here.
#
# No shipped save stores a crime grid to calibrate against -- the u8 layers
# the plan nominated (0x49D5BB8C / 0x49D5BBA1) are a near-identical bitfield
# pair that follows power corridors, not crime (see the note in
# SimGridSubfile). So, like pollution, the harness gates structure: wealthy
# tiles score below poor ones, police coverage lowers crime under it, and
# the field is deterministic.
class_name CrimeSim

const PROP_POLICE_STRENGTH : int = 0x48D71ED0
const PROP_POLICE_RADIUS : int = 0x48D71ED2      # metres; / 16 for tiles

# Criminality per wealth class (0 = undeveloped), scaled into the ramp
# domain. 0.15/0.10/0.07 are the Crime Simulator curves' opening values;
# CRIMINALITY_SCALE is ours, chosen so an unpoliced slum sits in the view's
# upper band.
const BASE_CRIMINALITY : Array = [0.0, 0.15, 0.10, 0.07]
const CRIMINALITY_SCALE : float = 1400.0
const POLICE_ATTENUATION : float = 0.8           # 0x8A0CBAAC
# Land value effect: high land value suppresses crime. Fraction of the
# criminality removed at land value 255.
const LAND_VALUE_DAMPING : float = 0.5

const DOMAIN_MAX : float = 255.0

var city = null

func _init(city_):
    city = city_

func tick(_month : int) -> void:
    var grids : SimGrids = city.sim_grids_model()
    var side : int = grids.map_tiles
    var coverage : Array = _police_coverage(side)
    var land = grids.grid(SimGrids.DERIVED_LAND_VALUE)

    var field : Array = []
    field.resize(side * side)
    field.fill(0.0)
    var lots = city.lot_model
    if lots != null:
        for cell in lots.by_cell.keys():
            var lot = lots.lot_at(cell)
            if lot == null or cell.x < 0 or cell.y < 0 or cell.x >= side or cell.y >= side:
                continue
            var i : int = cell.x * side + cell.y
            var crim : float = BASE_CRIMINALITY[clampi(lot.zone_wealth, 0, 3)] * CRIMINALITY_SCALE
            if land != null:
                crim *= 1.0 - LAND_VALUE_DAMPING * land.at_tile(cell.x, cell.y, side) / 255.0
            var cover : float = coverage[i]
            if cover > 0.0:
                crim *= 1.0 - POLICE_ATTENUATION * minf(cover / 100.0, 1.0)
            field[i] = clampf(crim, 0.0, DOMAIN_MAX)
    grids.commit_derived(SimGrids.DERIVED_POLICE_COVERAGE, coverage, side)
    grids.commit_derived(SimGrids.DERIVED_CRIME, field, side)

# Coverage strength per tile from every police-station occupant still
# standing. Razed lots take their station with them, same test as
# PollutionSim.
func _police_coverage(side : int) -> Array:
    var field : Array = []
    field.resize(side * side)
    field.fill(0.0)
    var lots = city.lot_model
    for rec in city.building_records:
        var strength = Core.exemplar_prop(rec.exemplar_tgi[1], rec.exemplar_tgi[2], PROP_POLICE_STRENGTH)
        var radius_m = Core.exemplar_prop(rec.exemplar_tgi[1], rec.exemplar_tgi[2], PROP_POLICE_RADIUS)
        if strength == null or radius_m == null:
            continue
        var cell : Vector2i = PollutionSim.occupant_cell(rec)
        if lots != null and lots.by_cell.has(cell) and lots.lot_at(cell) == null:
            continue
        var radius : float = float(radius_m) / 16.0
        PollutionSim._stamp(field, side, cell, float(strength), radius)
    return field
