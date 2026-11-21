export GIT_PAGER=cat PAGER=cat
cd /var/root/src/Firewalk && git checkout -q 0.14.0 && git log -1 --format="%h %ad %s" --date=short
pkill -x firewalk 2>/dev/null; sleep 1
( time swift build -c release ) > /tmp/fw14-build.log 2>&1; echo "FW14 rc=$?"; tail -3 /tmp/fw14-build.log
(./.build/release/firewalk < /dev/null > /tmp/firewalk.log 2>&1 &); sleep 5
for p in /payloads/2 /stream/2; do curl -s -o /dev/null -w "$p -> %{http_code}\n" http://127.0.0.1:8080$p; done
cd /var/root/src/Alamofire-5.10.2
launchctl asuser 0 xcodebuild -project Alamofire.xcodeproj -scheme "Alamofire macOS" -configuration Debug -destination "platform=macOS" -derivedDataPath /tmp/afdd7 CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 ENABLE_THREAD_SANITIZER=NO -only-testing:"Alamofire macOS Tests/DataStreamTests" -only-testing:"Alamofire macOS Tests/DataStreamConcurrencyTests" -only-testing:"Alamofire macOS Tests/DataStreamIntegrationTests" test > /tmp/afds.log 2>&1
echo "AFDS rc=$?"; grep -a -E "Executed [0-9]+ tests" /tmp/afds.log | tail -1
grep -a "error: -\[" /tmp/afds.log | sed "s/.*error: -\[Alamofire_macOS_Tests\.//" | cut -c1-200 | head -8
