#!/usr/bin/env python3
"""Make the hosted macOS's local user and automatic login, in a mounted system tree (run as root).

    gui-user.py ROOT TEMPLATE [NAME PASSWORD UID]

ROOT is where the user data lives: the whole system disk (HFS+) or a Mac's Data volume (APFS). TEMPLATE is the system's
"System/Library/User Template" (on APFS, from the System volume). Nothing comes from the host: one local administrator
(default xnu / xnulinux, uid 501) with the password as opendirectoryd keeps it (SALTED-SHA512-PBKDF2), member of admin and
staff, a home from the system's own template, automatic login (loginwindow's autoLoginUser plus /etc/kcpassword), and
Setup Assistant marked done for the system and the user.
"""
import hashlib, os, plistlib, subprocess, sys, uuid

root, template = sys.argv[1], sys.argv[2]
name = sys.argv[3] if len(sys.argv) > 3 else 'xnu'
pw = sys.argv[4] if len(sys.argv) > 4 else 'xnulinux'
uid = int(sys.argv[5]) if len(sys.argv) > 5 else 501
D = root + '/private/var/db/dslocal/nodes/Default'


def dump(path, value, mode=0o600):
    with open(path, 'wb') as f:
        plistlib.dump(value, f, fmt=plistlib.FMT_BINARY)
    os.chmod(path, mode)


salt, iters = os.urandom(32), 45000
shadow = plistlib.dumps({'SALTED-SHA512-PBKDF2': {'entropy': hashlib.pbkdf2_hmac('sha512', pw.encode(), salt, iters, 128),
                                                  'iterations': iters, 'salt': salt}}, fmt=plistlib.FMT_BINARY)
guid = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'xnulinux.user.' + name)).upper()
dump(D + '/users/%s.plist' % name, {
    'name': [name], 'uid': [str(uid)], 'gid': ['20'], 'home': ['/Users/' + name], 'shell': ['/bin/zsh'], 'realname': [name],
    'generateduid': [guid], 'passwd': ['********'], 'authentication_authority': [';ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>'],
    'ShadowHashData': [shadow]})


def member(group, gid, gguid):
    p = D + '/groups/%s.plist' % group
    g = plistlib.load(open(p, 'rb')) if os.path.exists(p) else {'name': [group], 'gid': [str(gid)], 'generateduid': [gguid]}
    g['users'] = sorted(set(g.get('users', [])) | {name})
    g['groupmembers'] = sorted(set(g.get('groupmembers', [])) | {guid})
    dump(p, g)


member('admin', 80, 'ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000050')
member('staff', 20, 'ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000014')
# automatic login: the user from loginwindow's preferences, the password from /etc/kcpassword (XORed with loginwindow's
# fixed key, padded with NULs to a multiple of 12 bytes)
key = bytes([0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F])
b = pw.encode() + b'\0'
b += b'\0' * (-len(b) % 12)
os.makedirs(root + '/private/etc', exist_ok=True)
with open(root + '/private/etc/kcpassword', 'wb') as f:
    f.write(bytes(c ^ key[i % len(key)] for i, c in enumerate(b)))
os.chmod(root + '/private/etc/kcpassword', 0o600)
lp = root + '/Library/Preferences/com.apple.loginwindow.plist'
lw = plistlib.load(open(lp, 'rb')) if os.path.exists(lp) else {}
lw.update({'autoLoginUser': name, 'autoLoginUserUID': uid, 'GuestEnabled': False})
dump(lp, lw, 0o644)
open(root + '/private/var/db/.AppleSetupDone', 'w').close()
# the home from the system's user template, the user's own Setup Assistant panes marked seen
home = root + '/Users/' + name
if not os.path.isdir(home):
    os.makedirs(home)
    for sub in ('Non_localized', 'English.lproj'):
        if os.path.isdir(os.path.join(template, sub)):
            subprocess.run(['cp', '-a', os.path.join(template, sub) + '/.', home + '/'], check=False)
os.makedirs(home + '/Library/Preferences', exist_ok=True)
seen = {k: True for k in ['DidSeeCloudSetup', 'DidSeePrivacy', 'DidSeeSiriSetup', 'DidSeeTouchIDSetup', 'DidSeeScreenTime',
        'DidSeeAppearanceSetup', 'DidSeeAccessibility', 'DidSeeActivationLock', 'DidSeeTermsOfAddress', 'DidSeeIntelligence',
        'DidSeeApplePaySetup', 'DidSeeAvatarSetup', 'DidSeeiCloudLoginForStorageServices', 'DidSeeSyncSetup',
        'DidSeeSyncSetup2', 'DidSeeTrueTonePrivacy', 'DidSeeWalletSetup', 'SkipFirstLoginOptimization']}
seen.update({'LastSeenCloudProductVersion': '99.0', 'LastSeenBuddyBuildVersion': '99Z999',
             'LastPreLoginTasksPerformedVersion': '99.0', 'LastPreLoginTasksPerformedBuild': '99Z999'})
dump(home + '/Library/Preferences/com.apple.SetupAssistant.plist', seen, 0o644)
subprocess.run(['chown', '-R', '%d:20' % uid, home], check=True)
os.chmod(home, 0o755)
print('gui-user: %s (%d), admin, automatic login, home from the template' % (name, uid))
