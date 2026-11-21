# Why xcodebuild -runFirstLaunch fails in the hosted macOS
launchctl asuser 0 xcodebuild -runFirstLaunch > /tmp/rfl.log 2>&1; echo "RFL rc=$?"
grep -v "^$" /tmp/rfl.log | tail -12 | cut -c1-220
log show --last 2m --style compact 2>/dev/null | grep -i "installer\|pkg\|PackageKit\|system_installd\|installd\|refused\|signature" | grep -v "AMFI: \[non-fatal\]" | tail -15 | cut -c1-240
