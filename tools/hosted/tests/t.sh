cd /tmp
xcrun swiftc -O m.swift -o m 2>&1 | tail -3
./m 2>&1 | tail -5
I="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
rm -rf /tmp/t.icon /tmp/t.png; cp -R "/var/root/src/stats-master/Stats/Supporting Files/Stats.icon" /tmp/t.icon
"$I" /tmp/t.icon --export-image --output-file /tmp/t.png --platform macOS --rendition Default --width 16 --height 16 --scale 2 > /tmp/ic.log 2>&1
echo "ictool rc=$?"; grep -v "^$" /tmp/ic.log | tail -8; ls -la /tmp/t.png
log show --last 2m --style compact 2>/dev/null | grep -i "metal\|gpubundle\|XnuCpu\|IOGPU" | tail -15
grep -rln "8080" /var/root/src/Alamofire-5.10.2/Tests | head -3
grep -rn "8080\|firewalk" /var/root/src/Alamofire-5.10.2/Tests/*.swift | head -4
