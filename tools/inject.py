#!/usr/bin/env python3
"""
Inject a dylib into an already modded TikTok .ipa and repack it unsigned.

  python tools/inject.py --ipa gtok.ipa --dylib GTokGlass.dylib --out gtok-glass.ipa

What it does:
  1. unpacks the ipa
  2. copies the dylib to Payload/TikTok.app/Frameworks/
  3. adds LC_LOAD_DYLIB @executable_path/Frameworks/<dylib> to the main binary
  4. enables file sharing so Documents/GTokGlass is visible in Files.app
  5. drops _CodeSignature / embedded.mobileprovision (stale after patching)
  6. repacks with correct unix permissions (0755 for Mach-O, 0644 for data)

The result is unsigned: sign it with your own certificate (ESign / Feather).
"""

import argparse
import os
import shutil
import stat
import struct
import sys
import tempfile
import zipfile

LC_LOAD_DYLIB = 0xC
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE


def align(x, a):
    return (x + a - 1) & ~(a - 1)


def parse_macho(path):
    with open(path, 'rb') as f:
        data = f.read(1 << 20)
    magic = struct.unpack('>I', data[:4])[0]
    if magic != MH_CIGAM_64:
        raise SystemExit('%s: not a thin little-endian arm64 Mach-O' % path)
    ncmds, sizeofcmds = struct.unpack('<II', data[16:24])
    off = 32
    first_section_off = None
    dylibs = []
    segs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', data[off:off + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            body = data[off + 8:off + cmdsize]
            nsects = struct.unpack('<I', body[56:60])[0]
            o = 64
            for _ in range(nsects):
                s = body[o:o + 80]
                o += 80
                ssize = struct.unpack('<Q', s[40:48])[0]
                sfileoff = struct.unpack('<I', s[48:52])[0]
                if ssize and sfileoff:
                    if first_section_off is None or sfileoff < first_section_off:
                        first_section_off = sfileoff
        elif cmd in (0xC, 0xD):
            body = data[off + 8:off + cmdsize]
            name_off = struct.unpack('<I', body[:4])[0]
            name = body[name_off - 8:].split(b'\x00')[0].decode('utf-8', 'replace')
            dylibs.append(name)
        off += cmdsize
    return dict(ncmds=ncmds, sizeofcmds=sizeofcmds, first_section=first_section_off, dylibs=dylibs)


def add_load_command(path, dylib_path, verbose=True):
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    magic = struct.unpack('>I', data[:4])[0]
    if magic != MH_CIGAM_64:
        raise SystemExit('main binary is not thin arm64')
    ncmds, sizeofcmds = struct.unpack('<II', data[16:24])
    info = parse_macho(path)
    if dylib_path in info['dylibs']:
        if verbose:
            print('  = LC_LOAD_DYLIB already present, skipping')
        return False

    name = dylib_path.encode('utf-8') + b'\x00'
    cmdsize = align(24 + len(name), 8)
    cmd = struct.pack('<IIIIII', LC_LOAD_DYLIB, cmdsize, 24, 2, 0x00010000, 0x00010000)
    blob = cmd + name + b'\x00' * (cmdsize - 24 - len(name))

    end = 32 + sizeofcmds
    limit = info['first_section'] or end
    if end + cmdsize > limit:
        raise SystemExit('no room for a new load command (%d bytes needed, %d free)' % (cmdsize, limit - end))

    data[end:end + cmdsize] = blob
    struct.pack_into('<II', data, 16, ncmds + 1, sizeofcmds + cmdsize)
    with open(path, 'wb') as f:
        f.write(data)

    check = parse_macho(path)
    assert dylib_path in check['dylibs'], 'patch verification failed'
    if verbose:
        print('  + LC_LOAD_DYLIB %s (ncmds %d -> %d)' % (dylib_path, ncmds, ncmds + 1))
    return True


def patch_info_plist(path, verbose=True):
    import plistlib
    with open(path, 'rb') as f:
        pl = plistlib.load(f)
    changed = False
    for k, v in (('UIFileSharingEnabled', True), ('LSSupportsOpeningDocumentsInPlace', True)):
        if pl.get(k) != v:
            pl[k] = v
            changed = True
    if changed:
        with open(path, 'wb') as f:
            plistlib.dump(pl, f, fmt=plistlib.FMT_BINARY)
        if verbose:
            print('  + Info.plist: file sharing enabled')
    return changed


def is_macho(path):
    try:
        with open(path, 'rb') as f:
            head = f.read(4)
        return head in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xce\xfa\xed\xfe')
    except OSError:
        return False


def pack(src_dir, out_path, verbose=True):
    entries = []
    for root, dirs, files in os.walk(src_dir):
        for d in dirs:
            p = os.path.join(root, d)
            entries.append((p, True))
        for f in files:
            entries.append((os.path.join(root, f), False))

    total = 0
    with zipfile.ZipFile(out_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path, is_dir in entries:
            arc = os.path.relpath(path, src_dir).replace('\\', '/')
            if is_dir:
                arc += '/'
                zi = zipfile.ZipInfo(arc)
                zi.external_attr = (0o40755 << 16) | 0x10
                z.writestr(zi, b'')
                continue
            mode = 0o100755 if is_macho(path) else 0o100644
            zi = zipfile.ZipInfo(arc, date_time=(2024, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = mode << 16
            with open(path, 'rb') as f:
                data = f.read()
            total += len(data)
            z.writestr(zi, data)
    size = os.path.getsize(out_path)
    if verbose:
        print('  packed %d entries, %d MB raw -> %d MB zip' % (len(entries), total >> 20, size >> 20))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ipa', required=True)
    ap.add_argument('--dylib', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--keep-temp', action='store_true')
    a = ap.parse_args()

    dylib_name = os.path.basename(a.dylib)
    tmp = tempfile.mkdtemp(prefix='gtokgl_')
    print('[*] unpacking %s' % a.ipa)
    with zipfile.ZipFile(a.ipa) as z:
        z.extractall(tmp)

    payload = os.path.join(tmp, 'Payload')
    apps = [d for d in os.listdir(payload) if d.endswith('.app')]
    if len(apps) != 1:
        raise SystemExit('expected exactly one .app in Payload, got %r' % apps)
    app = os.path.join(payload, apps[0])
    print('[*] app: %s' % apps[0])

    frameworks = os.path.join(app, 'Frameworks')
    os.makedirs(frameworks, exist_ok=True)
    dst = os.path.join(frameworks, dylib_name)
    shutil.copy2(a.dylib, dst)
    print('  + copied %s (%d KB)' % (dylib_name, os.path.getsize(dst) >> 10))

    exe = os.path.join(app, 'TikTok')
    if not os.path.exists(exe):
        raise SystemExit('main binary not found: %s' % exe)
    print('[*] patching %s' % os.path.basename(exe))
    add_load_command(exe, '@executable_path/Frameworks/' + dylib_name)

    print('[*] patching Info.plist')
    patch_info_plist(os.path.join(app, 'Info.plist'))

    for junk in ('_CodeSignature', 'SC_Info', 'embedded.mobileprovision'):
        p = os.path.join(app, junk)
        if os.path.exists(p):
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
            print('  - removed %s' % junk)

    # nested code signatures are stale after patching the main binary; the
    # signing app (ESign / Feather) recreates them. Leaving them in place makes
    # some signers reject or skip the nested bundles.
    removed = 0
    for root, dirs, files in os.walk(payload):
        for d in list(dirs):
            if d in ('_CodeSignature', 'SC_Info'):
                shutil.rmtree(os.path.join(root, d), ignore_errors=True)
                dirs.remove(d)
                removed += 1
            elif d == '__MACOSX':
                shutil.rmtree(os.path.join(root, d), ignore_errors=True)
                dirs.remove(d)
                removed += 1
    macosx = os.path.join(tmp, '__MACOSX')
    if os.path.isdir(macosx):
        shutil.rmtree(macosx, ignore_errors=True)
        removed += 1
    if removed:
        print('  - removed %d nested _CodeSignature/SC_Info/__MACOSX dirs' % removed)

    print('[*] packing %s' % a.out)
    pack(tmp, a.out)
    if not a.keep_temp:
        shutil.rmtree(tmp, ignore_errors=True)
    print('[ok] %s is ready, sign it with your certificate' % os.path.basename(a.out))


if __name__ == '__main__':
    main()
