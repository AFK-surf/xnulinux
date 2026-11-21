# Alamofire's own scheme (ThreadSanitizer on) on its offline test groups; then Stats from its unmodified project (icon step included)
cd /var/root/src/Alamofire-5.10.2
time launchctl asuser 0 xcodebuild -project Alamofire.xcodeproj -scheme "Alamofire macOS" -configuration Debug -destination "platform=macOS" -derivedDataPath /tmp/aftsan CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 -only-testing:"Alamofire macOS Tests/URLEncodedFormEncoderTests" -only-testing:"Alamofire macOS Tests/HTTPHeadersTests" -only-testing:"Alamofire macOS Tests/JSONParameterEncoderTests" test > /tmp/aftsan.log 2>&1
echo "AFTSAN rc=$?"; grep -a -E "Executed [0-9]+ tests|\*\* TEST" /tmp/aftsan.log | tail -2; grep -a -c "ThreadSanitizer\|enableThreadSanitizer\|libclang_rt.tsan" /tmp/aftsan.log; grep -a "FATAL\|incompatible with TSan" /tmp/aftsan.log | head -3
cd /var/root/src/stats-master
grep -c "Generate menu bar icon" Stats.xcodeproj/project.pbxproj
time xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Release -derivedDataPath /tmp/statsdd CODE_SIGNING_ALLOWED=NO build > /tmp/stats.log 2>&1
echo "STATS rc=$?"; grep -a -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*" /tmp/stats.log | tail -1; grep -a "error:" /tmp/stats.log | head -5
grep -a "Generate menu bar icon\|ictool" /tmp/stats.log | head -3 | cut -c1-200
ls -la /tmp/statsdd/Build/Products/Release/Stats.app/Contents/Resources/*.png 2>/dev/null | head -5
