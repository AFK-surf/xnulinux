cd /var/root/src/Alamofire-5.10.2
launchctl asuser 0 xcodebuild -project Alamofire.xcodeproj -scheme "Alamofire macOS" -configuration Debug -destination "platform=macOS" -derivedDataPath /tmp/afdd7 CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 ENABLE_THREAD_SANITIZER=NO test > /tmp/afall2.log 2>&1
echo "AF2 rc=$?"; grep -a -E "Executed [0-9]+ tests" /tmp/afall2.log | tail -1
grep -a "error: -\[" /tmp/afall2.log | sed "s/.*error: -\[Alamofire_macOS_Tests\.//" | cut -d" " -f1 | sort | uniq -c | sort -nr
