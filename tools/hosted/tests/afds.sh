cd /tmp
grep -a "error: -\[" afall.log | grep -a "DataStreamTests\|DataStreamConcurrency" | sed "s/.*error: -\[Alamofire_macOS_Tests\.//" | cut -c1-230 | head -16
grep -a "firewalk\|Firewalk" /tmp/firewalk.log | tail -3; tail -5 /tmp/firewalk.log
