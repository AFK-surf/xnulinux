cd /tmp
grep -a "error: -\[" afall.log | sed "s/.*error: -\[Alamofire_macOS_Tests\.//" | cut -d" " -f1 | sort | uniq -c | sort -nr
grep -a "error: -\[" afall.log | grep -a DataStreamTests | head -3 | cut -c1-300
grep -a "error: -\[" afall.log | grep -a "TLSEvaluation" | head -2 | cut -c1-300
grep -a "error: -\[" afall.log | grep -av "TLSEvaluation\|DataStream" | sed "s/.*error: -\[Alamofire_macOS_Tests\.//" | cut -c1-200 | head -12
