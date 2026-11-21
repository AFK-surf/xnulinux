# Round-6 Metal bundle into the running system, then Stats from its unmodified project (both icon renders)
bash /tmp/upd.sh
cd /var/root/src/stats-master
time xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Release -derivedDataPath /tmp/statsdd2 CODE_SIGNING_ALLOWED=NO build > /tmp/stats2.log 2>&1
echo "STATS2 rc=$?"; grep -a -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*" /tmp/stats2.log | tail -1
grep -a -A4 "The following build commands failed" /tmp/stats2.log | cut -c1-200
grep -a "stubbed" /tmp/stats2.log | sort | uniq -c | head
R=/tmp/statsdd2/Build/Products/Release/Stats.app/Contents/Resources; ls -la $R/MenuBarIcon*.png; file $R/MenuBarIcon*.png
du -sh /tmp/statsdd2/Build/Products/Release/Stats.app; file /tmp/statsdd2/Build/Products/Release/Stats.app/Contents/MacOS/Stats
echo "PNGB64BEGIN"; base64 -i $R/MenuBarIcon@2x.png | tr -d '\n'; echo; echo "PNGB64END"
