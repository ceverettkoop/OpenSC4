#!/usr/bin/env python3
"""Headless DBPF (.dat/.sc4) inspector -- stdlib only, no Godot needed.

Subcommands:
  types    Per-type subfile histogram for one file; diff when given two files
           (highlights placed-object subfiles that only appear once a city is
           developed).
  extract  Decompress a single subfile (QFS/RefPack, ported from
           addons/dbpf/DBPFSubfile.gd) and hexdump it and/or save it to disk.

Examples:
  tools/dat_dump.py types "Regions/Timbuktu/City - Big City Tutorial.sc4"
  tools/dat_dump.py types "<empty.sc4>" "<developed.sc4>"
  tools/dat_dump.py extract "<city.sc4>" 0xA9BD882D --hexdump 256
  tools/dat_dump.py extract "<city.sc4>" 0xA9BD882D --out building.bin
"""

import argparse
import struct
import sys
from collections import defaultdict

# Type IDs we already understand, so the output is legible. The
# building/prop/flora/lot/network entries were identified by diffing an empty
# city against a developed one (see the `types` diff output).
KNOWN = {
    0x6534284A: "EXEMPLAR",
    0x05342861: "COHORT",
    0x2026960B: "LTEXT",
    0x5AD0E817: "S3D",
    0x7AB50E44: "FSH",
    0x856DDBAC: "PNG",
    0xE86B1EEF: "DBDF (dir)",
    0xCA027EDB: "SC4RegionalCity (stats)",
    0xA9DD6FF4: "cSTETerrain (altitudes)",
    # placed-object subfiles (hop 1 of the model chain)
    0xA9BD882D: "Building subfile",
    0x2977AA47: "Prop subfile",
    0xA9C05C85: "Flora subfile",
    0xC9BD5D4A: "Lot subfile",
    0x6A0F82B2: "Network subfile",
}

DBDF_TYPE = 0xE86B1EEF

# Group IDs worth annotating when they appear inside occupant records (subset of
# Core.gd group_dict_to_text -- the building/prop parent cohorts).
GROUPS = {
    0x67BDDF0C: "RES_BLDG_PARENTS",
    0x47BDDF12: "DEV_COMMERCIAL",
    0x89AC5643: "EXEMPLAR_TRANSIT_PIECES",
    0x2A2458F9: "PROPS_ANIM",
    0xA9C05C85: "FLORA",
}


class Subfile:
    __slots__ = ("type_id", "group_id", "instance_id", "location", "size")

    def __init__(self, type_id, group_id, instance_id, location, size):
        self.type_id = type_id
        self.group_id = group_id
        self.instance_id = instance_id
        self.location = location
        self.size = size

    @property
    def tgi(self):
        return (self.type_id, self.group_id, self.instance_id)


class DBPF:
    """Parses a DBPF container: index table + DBDF compressed-file directory."""

    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        if self.data[:4] != b"DBPF":
            raise ValueError(f"{path}: not a DBPF file")
        # Header layout mirrors addons/dbpf/DBPF.gd: magic, version major/minor,
        # 3 unused u32, two date u32, index major version, entry count, offset.
        entry_count = struct.unpack_from("<I", self.data, 36)[0]
        index_offset = struct.unpack_from("<I", self.data, 40)[0]

        self.subfiles = []          # list[Subfile]
        self.by_tgi = {}            # (t,g,i) -> Subfile
        off = index_offset
        for _ in range(entry_count):
            t, g, i, loc, size = struct.unpack_from("<IIIII", self.data, off)
            sf = Subfile(t, g, i, loc, size)
            self.subfiles.append(sf)
            self.by_tgi[sf.tgi] = sf
            off += 20

        # DBDF directory: each 16-byte record (t, g, i, final_size) marks a
        # QFS-compressed subfile and gives its decompressed size.
        self.compressed = {}        # (t,g,i) -> final_size
        for sf in self.subfiles:
            if sf.type_id == DBDF_TYPE:
                for k in range(sf.size // 16):
                    t, g, i, fs = struct.unpack_from("<IIII", self.data,
                                                     sf.location + k * 16)
                    self.compressed[(t, g, i)] = fs

    def raw_bytes(self, sf):
        """Return the subfile's on-disk bytes, decompressing if it's in the DBDF."""
        block = self.data[sf.location:sf.location + sf.size]
        if sf.tgi in self.compressed:
            data = qfs_decompress(block)
            expected = self.compressed[sf.tgi]
            if len(data) != expected:
                print(f"WARNING: decompressed {len(data)} bytes, DBDF expected "
                      f"{expected}", file=sys.stderr)
            return data
        return block

    def find(self, type_id, group_id=None, instance_id=None):
        """All subfiles matching a type (and optionally group/instance)."""
        out = []
        for sf in self.subfiles:
            if sf.type_id != type_id:
                continue
            if group_id is not None and sf.group_id != group_id:
                continue
            if instance_id is not None and sf.instance_id != instance_id:
                continue
            out.append(sf)
        return out


def qfs_decompress(block):
    """QFS/RefPack decompression, ported from DBPFSubfile.decompress().

    `block` is the full on-disk subfile (index.size bytes): a 9-byte header
    (4 redundant bytes, 2-byte 0x10FB signature, 3-byte big-endian decompressed
    size) followed by the compressed control stream.
    """
    pos = 0
    pos += 4                                     # 4 redundant bytes
    pos += 2                                     # compression signature (0x10FB)
    # 3-byte decompressed size, big-endian (unused here but validated by caller)
    pos += 3
    out = bytearray()
    length = len(block) - 9                      # bytes of control stream, == size - 9

    while length > 0:
        cc = block[pos]; pos += 1
        length -= 1
        byte1 = byte2 = byte3 = 0
        if cc >= 252:
            numplain = cc & 0x03
            if numplain > length:
                numplain = length
            numcopy = 0
            offset = 0
        elif cc >= 224:
            numplain = (cc - 0xDF) << 2
            numcopy = 0
            offset = 0
        elif cc >= 192:
            length -= 3
            byte1 = block[pos]; pos += 1
            byte2 = block[pos]; pos += 1
            byte3 = block[pos]; pos += 1
            numplain = cc & 0x03
            numcopy = ((cc & 0x0C) << 6) + 5 + byte3
            offset = ((cc & 0x10) << 12) + (byte1 << 8) + byte2
        elif cc >= 128:
            length -= 2
            byte1 = block[pos]; pos += 1
            byte2 = block[pos]; pos += 1
            numplain = (byte1 & 0xC0) >> 6
            numcopy = (cc & 0x3F) + 4
            offset = ((byte1 & 0x3F) << 8) + byte2
        else:
            length -= 1
            byte1 = block[pos]; pos += 1
            numplain = cc & 0x03
            numcopy = ((cc & 0x1C) >> 2) + 3
            offset = ((cc & 0x60) << 3) + byte1

        length -= numplain
        if numplain > 0:
            out += block[pos:pos + numplain]
            pos += numplain

        fromoffset = len(out) - (offset + 1)
        for i in range(numcopy):
            out.append(out[fromoffset + i])

    return bytes(out)


# Exemplar property IDs worth naming (subset). RKT* = ResourceKeyType, the
# properties that point a building/prop exemplar at its S3D model.
PROP_NAMES = {
    0x00000010: "Exemplar Type",
    0x00000020: "Exemplar Name",
    0x27812820: "ResourceKeyType0 (RKT0)",
    0x27812821: "ResourceKeyType1 (RKT1)",
    0x27812822: "ResourceKeyType2 (RKT2)",
    0x27812823: "ResourceKeyType3 (RKT3)",
    0x27812870: "ResourceKeyType4 (RKT4)",
    0x27812920: "ResourceKeyType5 (RKT5)",
    0x88EDC900: "Occupant Size",
    0x88EDC790: "Occupant Groups",
    0xAA1DD396: "Query Exemplar GUID",
}
S3D_TYPE = 0x5AD0E817


def _val(data, ind, fmt):
    """Read one value of exemplar format `fmt` at `ind`; return (value, new_ind).
    Mirrors ExemplarSubfile.val_from_format()."""
    if fmt == 0x1 or fmt == 0x5:                 # uint8 / sint8
        return data[ind], ind + 1
    if fmt == 0x2 or fmt == 0x6:                 # uint16 / sint16
        return struct.unpack_from("<H", data, ind)[0], ind + 2
    if fmt == 0x3 or fmt == 0x7:                 # uint32 / sint32
        return struct.unpack_from("<I", data, ind)[0], ind + 4
    if fmt == 0x4 or fmt == 0x8:                 # uint64 / sint64
        return struct.unpack_from("<Q", data, ind)[0], ind + 8
    if fmt == 0x9:                               # float32
        return struct.unpack_from("<f", data, ind)[0], ind + 4
    if fmt == 0xA:                               # float64
        return struct.unpack_from("<d", data, ind)[0], ind + 8
    if fmt == 0xB:                               # bool
        return data[ind] != 0, ind + 1
    raise ValueError(f"unknown exemplar value format 0x{fmt:x} at {ind}")


def parse_exemplar(data):
    """Parse a binary EQZB exemplar. Returns (parent_cohort_tgi, {prop_id: value}).
    Ported from addons/dbpf/ExemplarSubfile.gd."""
    if data[:4] != b"EQZB":
        raise ValueError(f"not an EQZB exemplar (sig={data[:4]!r})")
    ind = 8                                       # EQZB + 4-byte format/parent indicator
    pc = struct.unpack_from("<III", data, ind)    # parent cohort T,G,I
    ind += 12
    num = struct.unpack_from("<I", data, ind)[0]
    ind += 4
    props = {}
    for _ in range(num):
        key = struct.unpack_from("<I", data, ind)[0]
        ind += 4
        ind += 1                                  # spacing byte (0x00)
        typ = struct.unpack_from("<I", data, ind)[0]
        ind += 4
        multi = (typ & 0xF000) > 0
        fmt = typ & 0xF
        if multi:
            length = struct.unpack_from("<I", data, ind)[0]
            ind += 4
            if fmt == 0xC:                        # string
                value = data[ind:ind + length - 1].decode("ascii", "replace")
                ind += length
            else:
                value = []
                for _i in range(length):
                    v, ind = _val(data, ind, fmt)
                    value.append(v)
        else:
            value, ind = _val(data, ind, fmt)
        props[key] = value
    return pc, props


def scan_s3d_refs(data):
    """Desync-proof: find every S3D type marker (0x5AD0E817) in the raw bytes and
    read it plus the following two u32s as a (T, G, I) model key."""
    marker = struct.pack("<I", S3D_TYPE)
    refs = []
    start = 0
    while True:
        o = data.find(marker, start)
        if o < 0:
            break
        if o + 12 <= len(data):
            t, g, i = struct.unpack_from("<III", data, o)
            refs.append((o, t, g, i))
        start = o + 4
    return refs


def walk_records(data):
    """Split a length-prefixed record array. Each record begins with a u32 size
    that includes the size field itself; the next record follows immediately.

    Returns (records, leftover_bytes) where records is a list of (offset, size,
    body). A record whose size runs past the buffer ends the walk.
    """
    records = []
    pos = 0
    n = len(data)
    while pos + 4 <= n:
        size = struct.unpack_from("<I", data, pos)[0]
        if size < 4 or pos + size > n:
            records.append((pos, size, None))  # malformed -- stop after recording
            return records, n - pos
        records.append((pos, size, data[pos:pos + size]))
        pos += size
    return records, n - pos


def annotate_record(body):
    """Find embedded known type/group IDs (unaligned) and plausible float
    coordinates (4-aligned) inside one record body."""
    ids = []
    for o in range(0, len(body) - 3):
        v = struct.unpack_from("<I", body, o)[0]
        if v in KNOWN:
            ids.append((o, v, "TYPE:" + KNOWN[v]))
        elif v in GROUPS:
            ids.append((o, v, "GROUP:" + GROUPS[v]))
    # SC4 occupant coordinates are stored big-endian, so try both and prefer the
    # plausible one (little-endian tagged "", big-endian tagged "be").
    floats = []
    for o in range(0, len(body) - 3, 4):
        for tag, fmt in (("", "<f"), ("be", ">f")):
            f = struct.unpack_from(fmt, body, o)[0]
            if f == f and abs(f) != float("inf") and (f == 0.0 or 0.1 <= abs(f) <= 65536.0):
                floats.append((o, f, tag))
                break
    return ids, floats


def dump_records(data, limit):
    records, leftover = walk_records(data)
    complete = [r for r in records if r[2] is not None]
    print(f"# {len(complete)} records, {leftover} leftover bytes"
          + ("  (clean framing)" if leftover == 0 and len(complete) == len(records)
             else "  (!! framing mismatch)"))
    for idx, (off, size, body) in enumerate(records[:limit]):
        if body is None:
            print(f"\n#{idx} off=0x{off:x} size={size}  <malformed>")
            continue
        ids, floats = annotate_record(body)
        print(f"\n#{idx} off=0x{off:x} size={size}")
        hexdump(body, min(len(body), 96))
        if ids:
            print("  ids:    " + ", ".join(f"@0x{o:02x}=0x{v:08x} {tag}" for o, v, tag in ids))
        if floats:
            print("  floats: " + ", ".join(f"@0x{o:02x}={f:.4g}{tag}" for o, f, tag in floats))


def hexdump(data, limit=None):
    n = len(data) if limit is None else min(limit, len(data))
    for base in range(0, n, 16):
        row = data[base:base + 16]
        hexs = " ".join(f"{b:02x}" for b in row)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        print(f"{base:08x}  {hexs:<47}  {text}")
    if limit is not None and len(data) > limit:
        print(f"... ({len(data) - limit} more bytes)")


# --- subcommands -----------------------------------------------------------

def histogram(dbpf):
    hist = defaultdict(lambda: [0, 0])
    for sf in dbpf.subfiles:
        hist[sf.type_id][0] += 1
        hist[sf.type_id][1] += sf.size
    return hist


def dump_hist(path, hist):
    total = sum(c for c, _ in hist.values())
    print(f"\n### {path}   ({total} subfiles, {len(hist)} types)")
    print(f"{'type':<12} {'count':>8} {'bytes':>12}   name")
    for t in sorted(hist, key=lambda t: hist[t][0], reverse=True):
        print(f"0x{t:08x}   {hist[t][0]:>8} {hist[t][1]:>12}   {KNOWN.get(t, '')}")


def dump_diff(base_path, base, dev_path, dev, factor):
    print(f"\n### DIFF: types new or >={factor}x larger in\n###   {dev_path}\n### vs\n###   {base_path}")
    print(f"{'type':<12} {'base_bytes':>12} {'dev_bytes':>12}   name")
    for t in sorted(dev, key=lambda t: dev[t][1], reverse=True):
        base_bytes = base[t][1] if t in base else 0
        dev_bytes = dev[t][1]
        if base_bytes == 0 or dev_bytes >= base_bytes * factor:
            print(f"0x{t:08x}   {base_bytes:>12} {dev_bytes:>12}   {KNOWN.get(t, '')}")


def cmd_types(args):
    dbpfs = [DBPF(p) for p in args.files]
    hists = [histogram(d) for d in dbpfs]
    for path, h in zip(args.files, hists):
        dump_hist(path, h)
    if len(args.files) == 2:
        dump_diff(args.files[0], hists[0], args.files[1], hists[1], args.factor)


def cmd_extract(args):
    dbpf = DBPF(args.file)
    matches = dbpf.find(args.type, args.group, args.instance)
    if not matches:
        print(f"no subfile of type 0x{args.type:08x} found", file=sys.stderr)
        return 1
    if len(matches) > 1 and (args.group is None or args.instance is None):
        print(f"{len(matches)} subfiles match type 0x{args.type:08x}; "
              f"narrow with --group/--instance. Using the first:", file=sys.stderr)
    sf = matches[0]
    data = dbpf.raw_bytes(sf)
    compressed = sf.tgi in dbpf.compressed
    print(f"# 0x{sf.type_id:08x} 0x{sf.group_id:08x} 0x{sf.instance_id:08x}  "
          f"{KNOWN.get(sf.type_id, '')}")
    print(f"# on-disk {sf.size} bytes, {'decompressed ' + str(len(data)) if compressed else 'uncompressed'} bytes")
    if args.out:
        with open(args.out, "wb") as f:
            f.write(data)
        print(f"# wrote {len(data)} bytes to {args.out}")
    if args.records is not None:
        dump_records(data, args.records)
    elif args.hexdump or not args.out:
        hexdump(data, args.hexdump if args.hexdump else 256)
    return 0


def _fmt_val(v):
    if isinstance(v, str):
        return repr(v)
    if isinstance(v, list):
        if v and all(isinstance(x, int) for x in v):
            return "[" + ", ".join(f"0x{x:08x}" for x in v) + "]"
        return "[" + ", ".join(f"{x:.4g}" if isinstance(x, float) else str(x) for x in v) + "]"
    if isinstance(v, int):
        return f"0x{v:08x} ({v})"
    return str(v)


def cmd_exemplar(args):
    dbpf = DBPF(args.file)
    matches = dbpf.find(args.type, args.group, args.instance)
    if not matches:
        print(f"no subfile 0x{args.type:08x} "
              f"{'0x%08x' % args.group if args.group is not None else '*'} "
              f"{'0x%08x' % args.instance if args.instance is not None else '*'} found",
              file=sys.stderr)
        return 1
    sf = matches[0]
    data = dbpf.raw_bytes(sf)
    print(f"# 0x{sf.type_id:08x} 0x{sf.group_id:08x} 0x{sf.instance_id:08x}  ({len(data)} bytes)")

    try:
        pc, props = parse_exemplar(data)
        print(f"# parent cohort: 0x{pc[0]:08x} 0x{pc[1]:08x} 0x{pc[2]:08x}")
        print(f"# {len(props)} properties")
        for key in props:
            name = PROP_NAMES.get(key, "")
            print(f"  0x{key:08x} {name:<26} {_fmt_val(props[key])}")
    except Exception as e:
        print(f"# exemplar parse failed ({e}); falling back to raw S3D scan", file=sys.stderr)

    refs = scan_s3d_refs(data)
    if refs:
        print(f"# S3D model references ({len(refs)} found by raw scan):")
        seen = set()
        for o, t, g, i in refs:
            k = (t, g, i)
            tag = "" if k not in seen else "  (dup)"
            seen.add(k)
            print(f"  @0x{o:04x}  T=0x{t:08x} G=0x{g:08x} I=0x{i:08x}{tag}")
    else:
        print("# no S3D (0x5AD0E817) reference found in this exemplar "
              "(model key may be inherited from the parent cohort)")
    return 0


def auto_int(s):
    return int(s, 0)


def main():
    ap = argparse.ArgumentParser(description="Inspect DBPF (.dat/.sc4) files.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_types = sub.add_parser("types", help="subfile-type histogram / diff")
    p_types.add_argument("files", nargs="+", help="DBPF files (.dat/.sc4)")
    p_types.add_argument("--factor", type=int, default=8,
                         help="diff threshold: flag types >= this many times larger (default 8)")
    p_types.set_defaults(func=cmd_types)

    p_ext = sub.add_parser("extract", help="decompress a subfile and hexdump/save it")
    p_ext.add_argument("file", help="DBPF file (.dat/.sc4)")
    p_ext.add_argument("type", type=auto_int, help="type id, e.g. 0xA9BD882D")
    p_ext.add_argument("--group", type=auto_int, default=None, help="group id filter")
    p_ext.add_argument("--instance", type=auto_int, default=None, help="instance id filter")
    p_ext.add_argument("--out", help="write decompressed bytes to this path")
    p_ext.add_argument("--hexdump", type=int, nargs="?", const=256, default=0,
                       help="hexdump the first N bytes (default 256; default action if --out absent)")
    p_ext.add_argument("--records", type=int, nargs="?", const=8, default=None,
                       help="walk length-prefixed records, showing the first N (default 8)")
    p_ext.set_defaults(func=cmd_extract)

    p_exm = sub.add_parser("exemplar", help="parse an EQZB exemplar and decode its S3D model refs")
    p_exm.add_argument("file", help="DBPF file (.dat/.sc4)")
    p_exm.add_argument("type", type=auto_int, nargs="?", default=0x6534284A,
                       help="type id (default 0x6534284A EXEMPLAR)")
    p_exm.add_argument("--group", type=auto_int, default=None)
    p_exm.add_argument("--instance", type=auto_int, default=None)
    p_exm.set_defaults(func=cmd_exemplar)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
