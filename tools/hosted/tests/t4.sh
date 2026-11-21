cd /tmp
OS_ACTIVITY_DT_MODE=YES ./m 2>&1 | grep -v "^$\|Server root port\|bootstrap: unknown" | cut -c1-260 | head -40
echo "--- swift: MTLCopyAllDevices first"
printf '%s\n' 'import Metal' 'print("all:", MTLCopyAllDevices().map { $0.name })' > a.swift
xcrun swiftc a.swift -o a 2>&1 | tail -2
OS_ACTIVITY_DT_MODE=YES ./a 2>&1 | grep -v "^$\|Server root port\|bootstrap: unknown" | cut -c1-260 | head -30
