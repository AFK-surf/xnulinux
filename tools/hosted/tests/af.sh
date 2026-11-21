# Firewalk on :8080, then Alamofire's full xcodebuild test
cd /var/root/src/Firewalk
(./.build/release/firewalk < /dev/null > /tmp/firewalk.log 2>&1 &)
sleep 5; curl -sS -o /dev/null -w "firewalk: HTTP %{http_code}\n" http://127.0.0.1:8080/get
grep -n "static var host\|ProcessInfo\|environment\[" /var/root/src/Alamofire-5.10.2/Tests/TestHelpers.swift | head -5
cd /var/root/src/Alamofire-5.10.2
time launchctl asuser 0 xcodebuild -project Alamofire.xcodeproj -scheme "Alamofire macOS" -configuration Debug -destination "platform=macOS" -derivedDataPath /tmp/afdd7 CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 ENABLE_THREAD_SANITIZER=NO test > /tmp/afall.log 2>&1
echo "AFRC=$?"
grep -a -E "Executed [0-9]+ tests|\*\* .* (SUCCEEDED|FAILED) \*\*" /tmp/afall.log | tail -3
grep -a "error: -\[" /tmp/afall.log | sed "s/.*error: -\[//" | cut -d" " -f1-2 | sort | uniq -c | sort -nr | head -15
