extends Node

# Headless regression harness for the SC4Path parser (addons/dbpf/SC4PathSubfile.gd).
#
# Loads the game DATs the way BootScreen does, then parses every SC4Path record
# in both network-path groups and checks the totals against baselines measured
# from the shipped data. Any drift in those numbers means the grammar handling
# changed. A clean run ends with "PATH DUMP COMPLETE".
#
# Run as a scene (NOT with -s: --script main loops can't compile scripts that
# reference autoload singletons like Core/Log):
#   godot --headless --path . res://tools/DumpPaths.tscn

const PATH_TYPE : int = 0x296678f7
const GROUP_TEXTURED : int = 0x69668828    # ground networks, keyed by FSH texture id
const GROUP_3D : int = 0xa966883f          # elevated/highway pieces, keyed by S3D id

# Measured across all 3,411 records of SimCity_1.dat before the parser existed.
const EXPECT_TOTAL : int = 3411
const EXPECT_BY_GROUP : Dictionary = {GROUP_TEXTURED: 340, GROUP_3D: 3071}
const EXPECT_VERSIONS : Dictionary = {"1.0": 160, "1.1": 378, "1.2": 2873}
const EXPECT_CLASSES : Dictionary = {
    "Car": 10567, "Sim": 1702, "Train": 486, "Subway": 439,
    "ElTrain": 198, "Monorail": 190,
}
const EXPECT_STOPS : Dictionary = {1: 2105, 2: 543}
# junctionFlag == 1 agreed with a "_J" comment suffix on every 1.2 record.
const EXPECT_JUNCTION_AGREEMENT : int = 1840

var dat_files = [
    "SimCity_1.dat",
    "SimCity_2.dat",
    "SimCity_3.dat",
    "SimCity_4.dat",
    "SimCity_5.dat",
    "EP1.dat",
]

var failures : int = 0

func _ready():
    if Core.game_dir == null:
        var config = INI.new("user://config.ini")
        if config.sections.has("paths"):
            Core.game_dir = config.sections["paths"]["sc4_files"]
        else:
            Core.game_dir = ProjectSettings.globalize_path("res://")
    print("game_dir: %s" % Core.game_dir)

    for dat_file in dat_files:
        var dbpf = DBPF.new(Core.game_dir + "/" + dat_file)
        Core.add_dbpf(dbpf)
    print("DATs loaded")

    var by_group := {}
    var versions := {}
    var classes := {}
    var stop_types := {}
    var junction_ok := 0
    var junction_bad := 0
    var parse_failures := 0
    var total := 0
    var empty_paths := 0

    for group in [GROUP_TEXTURED, GROUP_3D]:
        var key = [PATH_TYPE, group]
        if not Core.sub_by_type_and_group.has(key):
            print("no SC4Path subfiles in group %08X" % group)
            continue
        for iid in Core.sub_by_type_and_group[key].keys():
            var sub = Core.subfile(PATH_TYPE, group, iid, SC4PathSubfile)
            if sub == null:
                parse_failures += 1
                continue
            total += 1
            by_group[group] = by_group.get(group, 0) + 1
            parse_failures += sub.layout_failures
            var ver = "%d.%d" % [sub.version_major, sub.version_minor]
            versions[ver] = versions.get(ver, 0) + 1
            if sub.paths.is_empty():
                empty_paths += 1
            for name in sub.class_histogram().keys():
                classes[name] = classes.get(name, 0) + sub.class_histogram()[name]
            for stop in sub.stops:
                stop_types[stop.stop_type] = stop_types.get(stop.stop_type, 0) + 1
            # The junction flag should mirror the file's own naming convention.
            if sub.version_minor >= 2:
                for rec in sub.paths:
                    if rec.name.is_empty():
                        continue
                    if rec.is_junction == rec.name.ends_with("_J"):
                        junction_ok += 1
                    else:
                        junction_bad += 1

    print("\n--- SC4Path parse results ---")
    print("records: %d   parse failures: %d   files with no paths: %d"
        % [total, parse_failures, empty_paths])
    print("by group: %s" % _hex_keys(by_group))
    print("versions: %s" % versions)
    print("classes:  %s" % classes)
    print("stops:    %s" % stop_types)
    print("junction flag vs '_J' suffix: %d agree, %d disagree" % [junction_ok, junction_bad])

    _check("total records", total, EXPECT_TOTAL)
    _check("parse failures", parse_failures, 0)
    for group in EXPECT_BY_GROUP.keys():
        _check("group %08X" % group, by_group.get(group, 0), EXPECT_BY_GROUP[group])
    for ver in EXPECT_VERSIONS.keys():
        _check("version %s" % ver, versions.get(ver, 0), EXPECT_VERSIONS[ver])
    for name in EXPECT_CLASSES.keys():
        _check("class %s" % name, classes.get(name, 0), EXPECT_CLASSES[name])
    for kind in EXPECT_STOPS.keys():
        _check("stop type %d" % kind, stop_types.get(kind, 0), EXPECT_STOPS[kind])
    _check("junction agreement", junction_ok, EXPECT_JUNCTION_AGREEMENT)
    _check("junction disagreement", junction_bad, 0)

    _check_transforms()

    if failures > 0:
        push_error("PATH DUMP FAILED: %d checks did not match" % failures)
        get_tree().quit(1)
        return
    print("\nPATH DUMP COMPLETE")
    get_tree().quit()

# The placement transforms are pure maths, so they can be checked outright
# rather than inferred from how the city happens to look.
func _check_transforms():
    print("\n--- placement transforms ---")
    # A quarter turn advances the edge index by one, all the way round.
    for side in range(4):
        _check("rotate side %d by 1" % side,
            SC4PathSubfile.transform_dir(side, 1), (side + 1) % 4)
    _check("SIDE_NONE survives rotation",
        SC4PathSubfile.transform_dir(SC4PathSubfile.SIDE_NONE, 3), SC4PathSubfile.SIDE_NONE)

    # The edge indices and the coordinate axes have to rotate together, or the
    # geometry and the connectivity disagree about which way the tile faces.
    var unit = {
        SC4PathSubfile.SIDE_WEST: Vector3(-8, 0, 0),
        SC4PathSubfile.SIDE_NORTH: Vector3(0, 8, 0),
        SC4PathSubfile.SIDE_EAST: Vector3(8, 0, 0),
        SC4PathSubfile.SIDE_SOUTH: Vector3(0, -8, 0),
    }
    # Cover the flipped orientations too. The flip applies after the rotation
    # and the two do not commute, so an order slip here shows up as a handful
    # of tiles whose paths point at edges the save says are not connected --
    # scattered enough to look like noise rather than a systematic bug.
    for orientation in [0, 1, 2, 3, 0x80, 0x81, 0x82, 0x83]:
        for side in unit.keys():
            var moved = SC4PathSubfile.transform_local(unit[side], orientation)
            var expected = unit[SC4PathSubfile.transform_dir(side, orientation)]
            if moved.distance_to(expected) > 0.001:
                push_error("transform mismatch: side %d at orientation 0x%02X -> %s, edge maps to %s"
                    % [side, orientation, moved, expected])
                failures += 1
    print("edge/coordinate transforms agree over all 4 turns, flipped and not")

    # The mirror swaps west and east and leaves north and south alone.
    _check("flip maps west to east",
        SC4PathSubfile.transform_dir(SC4PathSubfile.SIDE_WEST, 0x80), SC4PathSubfile.SIDE_EAST)
    _check("flip leaves north alone",
        SC4PathSubfile.transform_dir(SC4PathSubfile.SIDE_NORTH, 0x80), SC4PathSubfile.SIDE_NORTH)
    # Flip-after-rotate: a quarter turn takes west to north, which the mirror
    # then leaves alone. Flipping first would have given south.
    _check("rotate then flip, not flip then rotate",
        SC4PathSubfile.transform_dir(SC4PathSubfile.SIDE_WEST, 0x81), SC4PathSubfile.SIDE_NORTH)

    # North is -z in this project's frame, so a path leaving by the north edge
    # must land at a SMALLER world z than the tile centre.
    var north_edge = SC4PathSubfile.to_world(Vector3(0, 8, 0), 10, 20, 0, 5.0)
    _check_float("north edge world x", north_edge.x, 10.5)
    _check_float("north edge world z", north_edge.z, 20.0)
    var east_edge = SC4PathSubfile.to_world(Vector3(8, 0, 0), 10, 20, 0, 5.0)
    _check_float("east edge world x", east_edge.x, 11.0)
    _check_float("east edge world z", east_edge.z, 20.5)
    # The third coordinate component is height, not depth.
    var lifted = SC4PathSubfile.to_world(Vector3(0, 0, 16), 10, 20, 0, 5.0)
    _check_float("height rides on the third component", lifted.y, 6.0)

func _check(what : String, got, want):
    if got == want:
        print("  ok    %-28s %s" % [what, got])
    else:
        push_error("MISMATCH %s: got %s, expected %s" % [what, got, want])
        failures += 1

func _check_float(what : String, got : float, want : float):
    if abs(got - want) < 0.001:
        print("  ok    %-28s %.3f" % [what, got])
    else:
        push_error("MISMATCH %s: got %f, expected %f" % [what, got, want])
        failures += 1

func _hex_keys(dict : Dictionary) -> String:
    var parts : Array = []
    for key in dict.keys():
        parts.append("%08X: %d" % [key, dict[key]])
    return "{%s}" % ", ".join(parts)
