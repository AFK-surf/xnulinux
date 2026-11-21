cd /tmp
f=$(ls /tmp/msgSends-* | head -1)
sed -n '14530,14615p' $f | cut -c1-150
