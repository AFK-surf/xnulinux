# GPU plugin round 7 in the hosted macOS: ictool on Stats' menu bar icon, the bundle on disk vs the new one (time, peak RSS, output)
I="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
ICON=$(find /var/root/src/stats-master -name "*.icon" -maxdepth 4 | head -1); echo "icon: $ICON"
run() { /usr/bin/time -l "$I" "$ICON" --export-image --output-file /tmp/g7-$1.png --platform macOS --rendition Default --width 16 --height 16 --scale 2 > /tmp/g7-$1.log 2>&1
  echo "$1 rc=$? $(grep -a 'real\|maximum resident' /tmp/g7-$1.log | tr -s ' ' | tr '\n' ' ') md5=$(md5 -q /tmp/g7-$1.png 2>/dev/null)"; }
run old1; run old2
bash /tmp/upd.sh
run new1; run new2; run new3
ls -la /var/tmp/xnu-cpu-metal-0 2>/dev/null | head -5; du -sh /var/tmp/xnu-cpu-metal-0/* 2>/dev/null
grep -a -c stubbed /tmp/g7-new3.log
