#!/usr/bin/env python3
"""Build the flashable module zip. Works on Windows, macOS and Linux.

    python pack.py            -> mount_ubuntu_data_<version>.zip next to this file

* every text file is written with LF line endings and without a UTF-8 BOM
  (CRLF in customize.sh / module.prop is what breaks flashing in KernelSU/Magisk)
* zip paths use "/" and scripts carry the 0755 bit
* repo-only files (.git*, .editorconfig, pack.py, *.zip) are left out
"""
import os, re, subprocess, sys, zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SKIP_NAMES = {'pack.py', '.gitattributes', '.gitignore', '.editorconfig', '.DS_Store', 'Thumbs.db'}
SKIP_DIRS = {'.git', '.github', '__pycache__'}
EXEC = {'update-binary', 'action.sh', 'customize.sh', 'service.sh', 'uninstall.sh', 'ubuntu-data.sh', 'setup-sharing.sh'}
BINARY_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.woff', '.woff2', '.ttf', '.zip', '.dex'}

def files():
    for d, dirs, names in os.walk(ROOT):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for n in sorted(names):
            if n in SKIP_NAMES or n.endswith('.zip'):
                continue
            full = os.path.join(d, n)
            yield os.path.relpath(full, ROOT).replace(os.sep, '/'), full

def main():
    prop = open(os.path.join(ROOT, 'module.prop'), encoding='utf-8-sig').read()
    kv = dict(l.split('=', 1) for l in prop.replace('\r', '').split('\n') if '=' in l and not l.startswith('#'))
    for k in ('id', 'name', 'version', 'versionCode'):
        if not kv.get(k, '').strip():
            sys.exit('module.prop: missing ' + k)
    out = os.path.join(ROOT, '%s_%s.zip' % (kv['id'].strip(), kv['version'].strip().lstrip('v')))
    entries = sorted(files(), key=lambda t: (not t[0].startswith('META-INF/'), t[0] != 'module.prop', t[0]))
    fixed = []
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for rel, full in entries:
            data = open(full, 'rb').read()
            if os.path.splitext(rel)[1].lower() not in BINARY_EXT:
                new = data
                if new.startswith(b'\xef\xbb\xbf'):
                    new = new[3:]
                new = new.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
                if new != data:
                    fixed.append(rel)
                data = new
                if os.path.basename(rel) in EXEC and os.path.basename(rel) != 'customize.sh':   # customize.sh is sourced, no shebang
                    if not data.startswith(b'#!'):
                        sys.exit(rel + ': missing #! line')
            zi = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
            zi.create_system = 3
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (0o100755 if os.path.basename(rel) in EXEC else 0o100644) << 16
            z.writestr(zi, data)
    # verify what was written
    with zipfile.ZipFile(out) as z:
        for n in z.namelist():
            b = z.read(n)
            if os.path.splitext(n)[1].lower() not in BINARY_EXT and (b'\r' in b or b.startswith(b'\xef\xbb\xbf')):
                sys.exit('CR/BOM left in ' + n)
            if n.endswith('.sh'):
                p = subprocess.run(['sh', '-n'], input=b, capture_output=True) if os.name != 'nt' else None
                if p is not None and p.returncode != 0:
                    sys.exit('sh -n failed for %s: %s' % (n, p.stderr.decode(errors='replace')))
    if fixed:
        print('converted to LF (fix your editor/git settings):', ', '.join(fixed))
    print('built', out, '(%d files)' % len(entries))

if __name__ == '__main__':
    main()
