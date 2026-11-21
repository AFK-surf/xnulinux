export GIT_PAGER=cat PAGER=cat
cd /var/root/src/Firewalk && git fetch -q --tags --unshallow 2>/dev/null || git fetch -q --tags
git tag --sort=-creatordate | head -8
for t in $(git tag --sort=-creatordate | head -6); do printf "%s: " $t; git grep -c "payloads" $t -- Sources 2>/dev/null | head -1 || echo none; echo; done
grep -rn "firewalk" /var/root/src/Alamofire-5.10.2/.github 2>/dev/null | head -5
