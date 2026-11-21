cd /tmp
xcrun swiftc -O d.swift -o d 2>&1 | tail -3
./d 2>&1 | tail -8
log show --last 3m --style compact 2>/dev/null | grep -v "Sandbox:\|amfid\|AMFI\|kernel.development" | grep -i "metal\|gpubundle\|XnuCpu\|IOGPU\|accelerat" | cut -c1-300 | tail -20
