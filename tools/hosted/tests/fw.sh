# Build and start Alamofire's local test server Firewalk (Vapor, SwiftPM dependencies fetched over the network)
cd /var/root/src
[ -d Firewalk ] || git clone --depth 1 https://github.com/Alamofire/Firewalk.git > /tmp/fw-clone.log 2>&1
cd Firewalk && echo "clone rc=$? $(git log --oneline -1 2>/dev/null)"
( time swift build -c release ) > /tmp/fw-build.log 2>&1
echo "FWBUILD rc=$?" >> /tmp/fw-build.log
