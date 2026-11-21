grep -a "error: -\[" /tmp/afall2.log | grep -a "AuthenticationInterceptor\|DownloadResponseTests" | sed "s/.*error: -\[Alamofire_macOS_Tests\.//" | cut -c1-220 | head -10
