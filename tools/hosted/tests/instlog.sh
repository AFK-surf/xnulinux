grep -a -i "script\|error\|fail\|refused" /var/log/install.log | tail -25 | cut -c1-230
ls /Library/Developer/Packages 2>/dev/null | head; pkgutil --pkgs 2>/dev/null | grep -i "xcode\|CoreTypes\|MobileDevice\|Developer" | head
