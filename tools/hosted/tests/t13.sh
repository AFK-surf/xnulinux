cd /tmp
pgrep -lx trustd; pgrep -lx securityd
xcrun swiftc trust.swift -o trust 2>&1 | tail -2; ./trust 2>&1 | tail -3
security verify-cert -c /var/root/src/Alamofire-5.10.2/Tests/Resources/Certificates/alamofire.org/alamofire-root-ca.cer 2>&1 | tail -2
log show --last 2m --style compact --predicate 'process == "trustd" OR subsystem == "com.apple.securityd"' 2>/dev/null | tail -8 | cut -c1-220
