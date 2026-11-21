cd /tmp
bash /tmp/upd.sh
./m 2>&1 | grep -v "^metal2vulkan" | tail -4
I="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
rm -f /tmp/t.png; XNU_CPU_METAL_TRACE=1 "$I" /tmp/t.icon --export-image --output-file /tmp/t.png --platform macOS --rendition Default --width 16 --height 16 --scale 2 > /tmp/ic.log 2>&1
echo "ictool rc=$?"; grep -v "^metal2vulkan\|^XCM new\|^XCM render\|^XCM compute" /tmp/ic.log | tail -12; ls -la /tmp/t.png; file /tmp/t.png
