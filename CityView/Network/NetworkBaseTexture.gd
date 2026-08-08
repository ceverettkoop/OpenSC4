extends RefCounted

# Which ground texture -- the sidewalk, verge or industrial apron -- sits under
# a network tile.
#
# A network tile draws TWO quads: the piece texture on top (24-31% of its pixels
# are transparent, measured over the RUL textures) and a fully opaque ground
# family underneath showing through those gaps. The save records the ground
# family per tile in NetworkTile.base_texture; City.gd draws it at
# NETWORK_BASE_LIFT under the piece at NETWORK_SURFACE_LIFT.
#
# Drawn roads have no such record -- nothing in the RUL files names a ground
# family -- so the rule below reconstructs one from the lots beside the tile.
# It was derived by correlating base_texture against the adjacent lots over
# 5,825 network tiles in four shipped saves (Big City / Rush Hour / Making
# Money Tutorial and Berlin's Tegel):
#
#   adjacent lots      base_texture          agreement
#   ---------------------------------------------------------------
#   none               0 (no quad)           408/446   91%
#   wealth 0           MEDIUM                224/224  100%
#   wealth $, industry INDUSTRIAL            929/929  100%
#   wealth $, resi     LOW                  2752/2760 100%
#   wealth $, comm     LOW                   334/347   96%
#   wealth $$          MEDIUM                771/901   86%
#
# Scored again over all eight populated saves -- 9,336 tiles -- this lands at
# 93.0% overall, per city 72.9% (Konradshohe) to 98.0% (Fulham). Five other
# rules were measured against the same 9,336 tiles and every one of them was
# worse, on the total and on all but one city individually:
#
#   this rule (radius 1, $$$ -> HIGH, industry overrides at $)      93.0%
#   radius 1, $$$ -> MEDIUM                                         91.8%
#   radius 2                                                        86.3%
#   radius 3                                                        82.7%
#   radius 2, no industrial override                                73.6%
#   radius 2, industry overrides at $ and $$                        73.3%
#
# It cannot be made exact from adjacency alone. The base_texture the save stores
# is a function of SC4's own `wealth_texture` byte -- which predicts it almost
# perfectly, taking values 0..7 (NetworkSubfile.gd calls it "0..3") -- and that
# byte is simulation state over land value, not a property of the neighbouring
# lots. A road being drawn for the first time has no such state, so adjacency is
# the most it can see. Konradshohe is the worst case for exactly that reason: it
# is dense with $$$ residential and heavy industry, where SC4's kerb follows the
# land value rather than the zoning next door.
class_name NetworkBaseTexture

# No ground quad at all: open country, where the piece texture carries its own
# shoulders. 348 tiles in the sample sit on undeveloped land and 91% of them
# store nothing here.
const NONE : int = 0
const LOW : int = 0x08100000         # the $ sidewalk, and the overwhelming default
const MEDIUM : int = 0x08200000      # $$ sidewalk, and any developed lot of no wealth
const HIGH : int = 0x08300000        # $$$ sidewalk
const INDUSTRIAL : int = 0x08400000  # the industrial apron -- no kerb, no verge

# The families that have to be packed into the build tool's Texture2DArray.
# They appear in no RUL file, so NetworkPieceDB would never see them otherwise.
const FAMILIES : Array = [LOW, MEDIUM, HIGH, INDUSTRIAL]

# LotSubfile zone types. 1-3 residential, 4-6 commercial, 7-9 industrial by
# density; 15 and above are plopped.
const ZONE_INDUSTRIAL_FIRST : int = 7
const ZONE_INDUSTRIAL_LAST : int = 9

# Wealth -> family for a tile that has at least one lot beside it. Index is
# LotRecord.zone_wealth, 0..3 = none/$/$$/$$$.
const BY_WEALTH : Array = [MEDIUM, LOW, MEDIUM, HIGH]

# The ground family for `cell`, or NONE. `lots` is a LotModel (or null, in which
# case there is nothing to go on and the tile gets no ground quad).
#
# The 3x3 neighbourhood is what the agreement figures above were measured over.
# Whether the four orthogonal sides alone would do as well was not tested.
static func pick(cell : Vector2i, lots) -> int:
    if lots == null:
        return NONE
    var wealth : int = -1
    var industrial := false
    for dx in [-1, 0, 1]:
        for dz in [-1, 0, 1]:
            var lot = lots.lot_at(cell + Vector2i(dx, dz))
            if lot == null:
                continue
            wealth = maxi(wealth, lot.zone_wealth)
            if lot.zone_type >= ZONE_INDUSTRIAL_FIRST and lot.zone_type <= ZONE_INDUSTRIAL_LAST:
                industrial = true
    if wealth < 0:
        return NONE
    # Industry only overrides at $: an industrial lot that has grown to $$ takes
    # the ordinary $$ sidewalk (641 of 711 such tiles in the sample).
    if industrial and wealth == 1:
        return INDUSTRIAL
    return BY_WEALTH[clampi(wealth, 0, BY_WEALTH.size() - 1)]
