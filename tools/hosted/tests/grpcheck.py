# The consistency CPython's test_grp checks: every getgrall() entry must round-trip through getgrgid/getgrnam
import grp
bad = 0
for e in grp.getgrall():
    try:
        a = grp.getgrgid(e.gr_gid); b = grp.getgrnam(e.gr_name)
        if a.gr_gid != e.gr_gid or b.gr_gid != e.gr_gid:
            print("mismatch", e.gr_name, e.gr_gid, a.gr_name, a.gr_gid, b.gr_gid); bad += 1
    except KeyError as x:
        print("missing", e.gr_name, e.gr_gid, x); bad += 1
print("groups", len(grp.getgrall()), "bad", bad)
