"""add_dylib.py BINARY DYLIB_PATH: append an LC_LOAD_DYLIB to a thin arm64 Mach-O (the header must have room)."""
import struct, sys
path, dylib = sys.argv[1], sys.argv[2].encode() + b'\0'
d = bytearray(open(path, 'rb').read())
magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, res = struct.unpack_from('<IiiIIIII', d, 0)
assert magic == 0xfeedfacf
off, first_sect = 32, None
for i in range(ncmds):
    cmd, size = struct.unpack_from('<II', d, off)
    if cmd in (0xc, 0x80000018) and dylib.rstrip(b'\0') in d[off:off+size]:
        sys.exit('already there')
    if cmd == 0x19:
        for j in range(struct.unpack_from('<I', d, off+64)[0]):
            so = struct.unpack_from('<I', d, off + 72 + j*80 + 48)[0]
            if so and (first_sect is None or so < first_sect): first_sect = so
    off += size
cmdsize = (24 + len(dylib) + 7) & ~7
assert off + cmdsize <= first_sect, 'no room after the load commands'
assert d[off:off+cmdsize] == bytes(cmdsize), 'the room is not empty'
lc = struct.pack('<IIIIII', 0xc, cmdsize, 24, 2, 0, 0) + dylib
d[off:off+cmdsize] = lc + bytes(cmdsize - len(lc))
struct.pack_into('<II', d, 16, ncmds + 1, sizeofcmds + cmdsize)
open(path, 'wb').write(d)
print(f'added {dylib.decode().rstrip(chr(0))}, ncmds {ncmds}->{ncmds+1}')
