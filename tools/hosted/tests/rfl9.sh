# xcodebuild -runFirstLaunch from a clean system disk, timed; the packages' receipts and the install log after it
pkgutil --pkgs | grep -c "XcodeSystemResources\|MobileDevice\|CoreTypes"
S0=$(date +%s); xcodebuild -runFirstLaunch > /tmp/rfl9.log 2>&1; echo "RFL rc=$? in $(( $(date +%s) - S0 ))s"
grep -v "^$" /tmp/rfl9.log | grep -v "Package Authoring\|com.apple.xpc\|powerd" | tail -6 | cut -c1-200
pkgutil --pkgs | grep "XcodeSystemResources\|MobileDevice\|CoreTypes"
grep -a "Install Succeeded\|Install Failed\|Writing system content receipt\|Removing client" /var/log/install.log | tail -4 | cut -c1-180
S0=$(date +%s); xcodebuild -runFirstLaunch > /dev/null 2>&1; echo "RFL again rc=$? in $(( $(date +%s) - S0 ))s"
