cd /tmp
grep -v "^metal2vulkan\|^XCM new\|^XCM render\|^XCM compute" /tmp/ic.log | head -24 | cut -c1-220
