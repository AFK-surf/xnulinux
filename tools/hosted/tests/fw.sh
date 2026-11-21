# Build and start Alamofire's local test server Firewalk (Vapor, SwiftPM dependencies fetched over the network)
# Firewalk 0.12.3: the last release whose /payloads/:count and chunked /stream match Alamofire 5.10.2 tests (0.13 added :delay)
cd /var/root/src
[ -d Firewalk ] || git clone https://github.com/Alamofire/Firewalk.git > /tmp/fw-clone.log 2>&1
cd Firewalk && git checkout -q 0.12.3 && echo "clone rc=$? $(git log --oneline -1 2>/dev/null)"
( time swift build -c release ) > /tmp/fw-build.log 2>&1
echo "FWBUILD rc=$?" >> /tmp/fw-build.log
