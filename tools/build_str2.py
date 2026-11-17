"""Rebuild store_clothing.str2_pc with a replacement store_clothing.lua, and the matching record in
patch_vint_doc_containers.asm_pc. Both go loose in the game root.

    python tools/build_str2.py <orig str2> <orig asm> <new lua or -> <out str2> <out asm>
    (pass "-" as the lua to rebuild the originals unchanged: the byte-exact control)

str2_pc (vpp v6), as shipped for this container: flags 0x4803 (compressed + condensed). Index of
24-byte entries at 0x800 {name_off, 0, data_off (uncompressed, contiguous), usize, csize, 0}, name
table at 0x800 + up(index), data at names + up(names). The data is ONE zlib stream (level 9) with a
SYNC flush after each file and no final block (csize = bytes emitted per file). Header: 0x154 count,
0x158 total file size, 0x15C index size, 0x160 names size, 0x164 data usize, 0x168 data csize.

asm_pc v11 record (reverse-engineered; the size fields are checked by the byte-exact control): {lpstr name, u8 kind, u16 flags, s16 n,
u32 header_region_size, lpstr source, u32 extra_len (+extra), u32 payload_length,
n x (u32 primary, u32 secondary), n x entry{lpstr name, u8 type, u8 pool, u8 flags, u8 variant,
u32 primary, u32 secondary, u8 group}}. payload_length == str2 0x168; sizes == the files' usizes.
"""
import struct, sys, zlib

ALIGN = 0x800
def up(v): return (v + ALIGN - 1) // ALIGN * ALIGN


def read_str2(b):
    g = lambda o: struct.unpack_from('<I', b, o)[0]
    flags, count, isz, nsz = g(0x14C), g(0x154), g(0x15C), g(0x160)
    assert flags == 0x4803, hex(flags)
    names_at = 0x800 + up(isz); data_at = names_at + up(nsz)
    whole = zlib.decompressobj().decompress(b[data_at:])
    files = []
    for i in range(count):
        noff, _, doff, us, cs, _ = struct.unpack_from('<6I', b, 0x800 + 24 * i)
        n = b.index(b'\0', names_at + noff)
        files.append([b[names_at + noff:n].decode(), whole[doff:doff + us]])
    return b[:0x800], files


def write_str2(head, files):
    c = zlib.compressobj(9)
    comp, idx, names, doff = [], b'', b'', 0
    for name, blob in files:
        z = c.compress(blob) + c.flush(zlib.Z_SYNC_FLUSH)
        idx += struct.pack('<6I', len(names), 0, doff, len(blob), len(z), 0)
        names += name.encode() + b'\0'
        comp.append(z); doff += len(blob)
    data = b''.join(comp)
    names_at = 0x800 + up(len(idx)); data_at = names_at + up(len(names))
    out = bytearray(head) + bytearray(data_at - 0x800)
    out[0x800:0x800 + len(idx)] = idx
    out[names_at:names_at + len(names)] = names
    out += data
    for off, v in ((0x154, len(files)), (0x158, len(out)), (0x15C, len(idx)), (0x160, len(names)),
                   (0x164, doff), (0x168, len(data))):
        struct.pack_into('<I', out, off, v)
    return bytes(out), data_at, len(data)


class R:
    def __init__(s, b, o=0): s.b, s.o = b, o
    def u(s, f):
        v = struct.unpack_from(f, s.b, s.o)[0]; s.o += struct.calcsize(f); return v
    def lp(s):
        n = s.u('<H'); v = s.b[s.o:s.o + n]; s.o += n; return v


def patch_asm(asm, record, sizes, header_region, payload_len):
    """Rewrite one record's size fields in place (sizes: {entry name: primary size})."""
    r = R(asm, 8)
    for _ in range(3):
        for _ in range(r.u('<I')): r.lp(); r.u('<B')
    nrec = struct.unpack_from('<H', asm, 6)[0]
    out = bytearray(asm); hits = 0
    for _ in range(nrec):
        name = r.lp().decode()
        r.u('<B'); r.u('<H'); n = r.u('<h')
        hr_at = r.o; r.u('<I'); r.lp()
        ext = r.u('<I'); r.o += ext
        pl_at = r.o; r.u('<I')
        st_at = r.o; r.o += 8 * n
        ents = []
        for k in range(n):
            en = r.lp().decode(); r.o += 4
            pr_at = r.o; r.o += 9
            ents.append((en, pr_at))
        if name.lower() == record.lower():
            hits += 1
            struct.pack_into('<I', out, hr_at, header_region)
            struct.pack_into('<I', out, pl_at, payload_len)
            for k, (en, pr_at) in enumerate(ents):
                if en in sizes:
                    struct.pack_into('<I', out, pr_at, sizes[en])
                    struct.pack_into('<I', out, st_at + 8 * k, sizes[en])
            print(f'asm record {name}: entries {[e for e, _ in ents]}')
    assert r.o == len(asm), f'asm not consumed exactly ({r.o} of {len(asm)})'
    assert hits == 1, f'record {record} found {hits} times'
    return bytes(out)


def main(str2_in, asm_in, lua_in, str2_out, asm_out):
    orig = open(str2_in, 'rb').read()
    head, files = read_str2(orig)
    if lua_in != '-':
        new = open(lua_in, 'rb').read()
        files = [[n, new if n == 'store_clothing.lua' else b] for n, b in files]
    out, data_at, clen = write_str2(head, files)
    asm = patch_asm(open(asm_in, 'rb').read(), 'store_clothing.vint_doc', {n: len(b) for n, b in files}, data_at, clen)
    open(str2_out, 'wb').write(out); open(asm_out, 'wb').write(asm)
    if lua_in == '-':
        print('control str2 identical:', out == orig, '| asm identical:', asm == open(asm_in, 'rb').read())
    print(f'str2 {len(out)} bytes, data usize {sum(len(b) for _, b in files)}, csize {clen}; files {[(n, len(b)) for n, b in files]}')


if __name__ == '__main__':
    main(*sys.argv[1:6])
