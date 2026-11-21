cd /tmp
XNU_CPU_METAL_TRACE=1 "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" /tmp/t.icon --export-image --output-file /tmp/t.png --platform macOS --rendition Default --width 16 --height 16 --scale 2 > /tmp/ic2.log 2>&1
echo "rc=$?"; grep -c . /tmp/ic2.log
grep -v "^metal2vulkan" /tmp/ic2.log | grep -i "XCM\|stub" | sort | uniq -c | sort -nr | head -40 | cut -c1-200
