"""VPP_PC / STR2_PC v6 reader for Saints Row: The Third.

Differs from tools/vpp.py in the non-condensed compressed path. SR3 stores each entry as its
own zlib stream, 2048-aligned, but TRUNCATED at csize: the final block terminator and adler32
are cut off. zlib.decompress() therefore raises "incomplete or truncated stream" even though
every byte of payload is present, which is why the plain-decompress path fails on
misc_tables.vpp_pc. Using a decompressobj and accepting eof=False returns exactly usize bytes.

Index entry (24 bytes, from 0x800):
    0x00 name offset   0x04 pad   0x08 data offset (UNCOMPRESSED space, 2048-aligned)
    0x0C uncompressed size        0x10 compressed size        0x14 pad
"""
import struct, zlib

MAGIC, ALIGN, ENTRY, DIR_AT = 0x51890ACE, 2048, 24, 0x800
def up(v, a=ALIGN): return (v + a - 1) // a * a

class Pack:
    def __init__(self, data):
        self.d = data
        assert struct.unpack_from("<I", data, 0)[0] == MAGIC, "not a vpp/str2 v6 container"
        g = lambda o: struct.unpack_from("<I", data, o)[0]
        self.flags, self.count = g(0x14C), g(0x154)
        self.idx_sz, self.nm_sz, self.data_sz, self.comp_sz = g(0x15C), g(0x160), g(0x164), g(0x168)
        self.compressed, self.condensed = bool(self.flags & 1), bool(self.flags & 2)
        self.names_at = DIR_AT + up(self.idx_sz)
        self.data_at  = self.names_at + up(self.nm_sz)

    def entries(self):
        for i in range(self.count):
            o = DIR_AT + i * ENTRY
            name_off, _p0, doff, usize, csize, _p1 = struct.unpack_from("<6I", self.d, o)
            n = self.d.index(b"\0", self.names_at + name_off)
            yield self.d[self.names_at + name_off:n].decode("latin1"), doff, usize, csize

    def read_all(self):
        whole = None
        if self.compressed and self.condensed:
            whole = zlib.decompressobj().decompress(self.d[self.data_at:])
        off = 0
        for name, doff, usize, csize in self.entries():
            if whole is not None:
                blob = whole[doff:doff + usize]
            elif self.compressed and csize != 0xFFFFFFFF:
                at = self.data_at + off
                blob = zlib.decompressobj().decompress(self.d[at:at + csize])
                off = up(off + csize)
            else:
                blob = self.d[self.data_at + doff:self.data_at + doff + usize]
            yield name, blob, usize
