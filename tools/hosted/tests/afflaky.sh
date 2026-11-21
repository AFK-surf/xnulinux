cd /var/root/src/Alamofire-5.10.2
for i in 1 2 3; do
launchctl asuser 0 xcodebuild -project Alamofire.xcodeproj -scheme "Alamofire macOS" -configuration Debug -destination "platform=macOS" -derivedDataPath /tmp/afdd7 CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 ENABLE_THREAD_SANITIZER=NO -only-testing:"Alamofire macOS Tests/DownloadResponseTests/testCancelledDownloadRequest" -only-testing:"Alamofire macOS Tests/AuthenticationInterceptorTestCase/testThatInterceptorTriggersRefreshWithMultipleParallelRequestsReturning401Responses" test-without-building > /tmp/afflaky$i.log 2>&1
printf "run $i: "; grep -a -E "Executed [0-9]+ tests" /tmp/afflaky$i.log | tail -1
done
