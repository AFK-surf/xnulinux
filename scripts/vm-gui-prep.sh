#!/bin/bash
# In the VM: make the golden full disk boot into a graphical session.
#  - loginwindow back in /System/Library/LaunchDaemons (earlier disks parked it). logind starts it when it opens the console
#    session at boot; with loginwindow absent then, logind's SOStartSessionWithOptions dies (_xpc_api_misuse) and no
#    later restart of logind or WindowServer opens the session again.
#  - one local administrator made here (never copied from the host): name GUI_USER (xnu), password GUI_PASSWORD (xnulinux),
#    uid 501, home from the system's own user template, member of admin and staff
#  - automatic login as that user (loginwindow's autoLoginUser plus /etc/kcpassword), and Setup Assistant marked done
#    for the system (.AppleSetupDone) and for the user, so the session goes straight to the desktop
set -e -o pipefail
IMG=${IMG:-/var/tmp/full.img}
USERNAME=${GUI_USER:-xnu}; PASSWORD=${GUI_PASSWORD:-xnulinux}; UID_=${GUI_UID:-501}
sudo dmsetup remove xnusys 2>/dev/null || true; for l in $(losetup -j $IMG -O NAME -n); do sudo losetup -d $l; done
sudo fsck.hfsplus -fy $IMG 2>&1 | tail -1
sudo mkdir -p /mnt/sys; sudo mount -o loop,rw,force -t hfsplus $IMG /mnt/sys
M=/mnt/sys
[ -e $M/private/var/xnulinux-parked/com.apple.loginwindow.plist ] && sudo mv $M/private/var/xnulinux-parked/com.apple.loginwindow.plist $M/System/Library/LaunchDaemons/
sudo M=$M USERNAME="$USERNAME" PASSWORD="$PASSWORD" UID_="$UID_" python3 - <<'PY'
import hashlib, os, plistlib, uuid
M, name, pw, uid = os.environ["M"], os.environ["USERNAME"], os.environ["PASSWORD"], int(os.environ["UID_"])
D = M + "/private/var/db/dslocal/nodes/Default"
# the password as opendirectoryd keeps it: SALTED-SHA512-PBKDF2 inside a binary plist in ShadowHashData
salt, iters = os.urandom(32), 45000
shadow = plistlib.dumps({"SALTED-SHA512-PBKDF2": {"entropy": hashlib.pbkdf2_hmac("sha512", pw.encode(), salt, iters, 128),
                                                  "iterations": iters, "salt": salt}}, fmt=plistlib.FMT_BINARY)
guid = str(uuid.uuid5(uuid.NAMESPACE_DNS, "xnulinux.user." + name)).upper()
user = {"name": [name], "uid": [str(uid)], "gid": ["20"], "home": ["/Users/" + name], "shell": ["/bin/zsh"],
        "realname": [name], "generateduid": [guid], "passwd": ["********"],
        "authentication_authority": [";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"], "ShadowHashData": [shadow]}
with open(D + "/users/%s.plist" % name, "wb") as f:
    plistlib.dump(user, f, fmt=plistlib.FMT_BINARY)
os.chmod(D + "/users/%s.plist" % name, 0o600)
def member(group, gid, gguid):
    p = D + "/groups/%s.plist" % group
    g = plistlib.load(open(p, "rb")) if os.path.exists(p) else {"name": [group], "gid": [str(gid)], "generateduid": [gguid]}
    g["users"] = sorted(set(g.get("users", [])) | {name})
    g["groupmembers"] = sorted(set(g.get("groupmembers", [])) | {guid})
    with open(p, "wb") as f:
        plistlib.dump(g, f, fmt=plistlib.FMT_BINARY)
    os.chmod(p, 0o600)
member("admin", 80, "ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000050")
member("staff", 20, "ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000014")
# automatic login: loginwindow reads the user from its preferences and the password from /etc/kcpassword (the password
# XORed with loginwindow's fixed key, padded with NULs to a multiple of 12 bytes)
key = bytes([0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F])
b = pw.encode() + b"\0"; b += b"\0" * (-len(b) % 12)
with open(M + "/private/etc/kcpassword", "wb") as f:
    f.write(bytes(c ^ key[i % len(key)] for i, c in enumerate(b)))
os.chmod(M + "/private/etc/kcpassword", 0o600)
lp = M + "/Library/Preferences/com.apple.loginwindow.plist"
lw = plistlib.load(open(lp, "rb")) if os.path.exists(lp) else {}
lw.update({"autoLoginUser": name, "autoLoginUserUID": uid, "GuestEnabled": False})
with open(lp, "wb") as f:
    plistlib.dump(lw, f, fmt=plistlib.FMT_BINARY)
open(M + "/private/var/db/.AppleSetupDone", "w").close()
PY
# the home directory from the system's user template, and the user's own Setup Assistant panes marked seen
H=$M/Users/$USERNAME
if [ ! -d $H ]; then
  sudo mkdir -p $H
  sudo cp -a "$M/System/Library/User Template/Non_localized/." $H/ 2>/dev/null || true
  sudo cp -a "$M/System/Library/User Template/English.lproj/." $H/ 2>/dev/null || true
fi
sudo mkdir -p $H/Library/Preferences
sudo H=$H python3 - <<'PY'
import os, plistlib
p = {k: True for k in ["DidSeeCloudSetup", "DidSeePrivacy", "DidSeeSiriSetup", "DidSeeTouchIDSetup", "DidSeeScreenTime",
     "DidSeeAppearanceSetup", "DidSeeAccessibility", "DidSeeActivationLock", "DidSeeTermsOfAddress", "DidSeeIntelligence",
     "DidSeeApplePaySetup", "DidSeeAvatarSetup", "DidSeeiCloudLoginForStorageServices", "DidSeeSyncSetup", "DidSeeSyncSetup2",
     "DidSeeTrueTonePrivacy", "DidSeeWalletSetup", "SkipFirstLoginOptimization"]}
p.update({"LastSeenCloudProductVersion": "99.0", "LastSeenBuddyBuildVersion": "99Z999", "LastPreLoginTasksPerformedVersion": "99.0",
          "LastPreLoginTasksPerformedBuild": "99Z999"})
with open(os.environ["H"] + "/Library/Preferences/com.apple.SetupAssistant.plist", "wb") as f:
    plistlib.dump(p, f, fmt=plistlib.FMT_BINARY)
PY
sudo chown -R $UID_:20 $H; sudo chmod 755 $H
echo "gui-prep: loginwindow $(ls $M/System/Library/LaunchDaemons/com.apple.loginwindow.plist 2>/dev/null | wc -l), user $USERNAME ($UID_), home $(sudo du -sh $H | cut -f1), autologin set"
sudo umount /mnt/sys; sudo fsck.hfsplus -fy $IMG 2>&1 | tail -1; sync
