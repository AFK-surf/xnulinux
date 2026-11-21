grep -a -A8 "The following build commands failed" /tmp/stats.log | cut -c1-220
grep -a -i -B2 -A6 "error\b\|fatal\|failed with\|Command .* failed" /tmp/stats.log | grep -av "^--$" | tail -25 | cut -c1-220
