#!/usr/bin/env python3
# Disassemble [va, va+len) of a fileset kernel collection (top-level LC_SEGMENT_64s) with llvm-mc. Debugging aid.
import struct, subprocess, sys
path, va, n = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 0)
d = open(path, 'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]; off = 32
for _ in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, off)
    if cmd == 0x19:
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off + 24)
        if vmaddr <= va < vmaddr + filesize:
            fo = fileoff + (va - vmaddr); code = d[fo:fo + n]
            words = struct.unpack('<%dI' % (len(code) // 4), code)
            src = ''.join('0x%02x 0x%02x 0x%02x 0x%02x\n' % (w & 255, (w >> 8) & 255, (w >> 16) & 255, w >> 24) for w in words)
            out = subprocess.run(['xcrun', 'llvm-mc', '--disassemble', '-triple=arm64e-apple-macos', '-mattr=+v8.5a,+pauth'],
                                 input=src, capture_output=True, text=True).stdout.splitlines()
            ins = [l for l in out if l.strip() and not l.strip().startswith('.')]
            for i, l in enumerate(ins):
                print('%x %s' % (va + 4 * i, l.strip()))
            sys.exit(0)
    off += sz
print('va not found')
