# The PNG ictool rendered (base64 to the console), then Stats with its own, unmodified project (icon step included)
echo "PNGB64BEGIN"; base64 -i /tmp/t.png | tr -d '\n'; echo; echo "PNGB64END"
cd /var/root/src/stats-master && git status --short 2>/dev/null | head -3
grep -c "Generate menu bar icon" Stats.xcodeproj/project.pbxproj
time xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Release -derivedDataPath /tmp/statsdd CODE_SIGNING_ALLOWED=NO build > /tmp/stats.log 2>&1
echo "STATS rc=$?"
grep -a -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*" /tmp/stats.log | tail -1
grep -a "error:" /tmp/stats.log | head -5
grep -a -A3 "Generate menu bar icon" /tmp/stats.log | head -8
ls -la /tmp/statsdd/Build/Products/Release/Stats.app/Contents/Resources/ 2>/dev/null | grep -i "menubar\|icon" | head
