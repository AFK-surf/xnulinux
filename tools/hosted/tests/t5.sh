cd /tmp
xcrun clang s.m -framework Foundation -framework Metal -o s 2>&1 | grep -v warning | tail -4
./s 2>&1 | cut -c1-200 | head -80
