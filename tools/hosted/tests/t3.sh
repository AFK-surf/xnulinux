cd /tmp
xcrun clang -fobjc-arc b.m -framework Foundation -framework Metal -o b 2>&1 | tail -3
XNU_CPU_METAL_TRACE=1 ./b 2>&1 | tail -12
echo "--- discovery with os_log on stderr"
OS_ACTIVITY_DT_MODE=YES ./m 2>&1 | grep -v "^$" | cut -c1-250 | tail -25
