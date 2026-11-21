cd /tmp
rm -f /tmp/msgSends-*
NSObjCMessageLoggingEnabled=YES ./a > /dev/null 2>&1
f=$(ls /tmp/msgSends-* | head -1); echo "log $f $(wc -l < $f) lines"
grep -n "XnuCpuMetal\|MTLIOAccel\|IOGPUMetalDevice\|_MTLDevice\|MTLDevice" $f | grep -v "NSString\|NSMutable" | cut -c1-200 | head -60
