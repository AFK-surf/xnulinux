cd /tmp
rm -f /tmp/msgSends-*
I="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
NSObjCMessageLoggingEnabled=YES "$I" /tmp/t.icon --export-image --output-file /tmp/t.png --platform macOS --rendition Default --width 16 --height 16 --scale 2 > /dev/null 2>&1
for f in /tmp/msgSends-*; do echo "== $f $(wc -l < $f)"; grep -n "XcmBackendDevice\|MTLLoader\|TargetDeviceArch" $f | tail -25 | cut -c1-160; done
