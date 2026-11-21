cd /var/root/src/Alamofire-5.10.2/Tests
grep -n "case stream\|case payloads\|\"/stream\|\"/payloads\|static func stream\|static func payloads\|path: \"/" TestHelpers.swift | head -12
for p in /stream/2 /payloads/2 /bytes/10 /get; do curl -s -o /dev/null -w "$p -> %{http_code}\n" http://127.0.0.1:8080$p; done
cd /var/root/src/Firewalk && git log -1 --format="%h %ad %s" --date=short && grep -rn "\"stream\"\|\"payloads\"" Sources | head -5
