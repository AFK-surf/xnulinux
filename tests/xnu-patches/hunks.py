#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Every hunk of a patch is as long as its header says.

    hunks.py PATCH...

`git apply` takes a hunk whose header counts too few lines without a word and drops the lines after it (the last line
of a new file, say), and a patch edited by hand gets exactly that wrong. This counts: after `@@ -a,b +c,d @@` there
must be b old lines (' ' and '-') and d new ones (' ' and '+'), and between one hunk's end and the next header no line
that looks like part of a diff.
"""
import re
import sys

HEADERS = ('diff --git ', '--- a/', '--- /dev/null', '+++ b/', 'index ', 'new file mode ', 'deleted file mode ')


def check(path):
    old = new = 0
    started = False
    bad = []
    for i, line in enumerate(open(path, errors='replace').read().split('\n'), 1):
        m = re.match(r'@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@', line)
        if m or line.startswith(HEADERS):
            if old or new:
                bad.append(f'line {i}: the hunk before it is {old} old and {new} new lines short of its header')
            old, new = (int(m.group(1) or 1), int(m.group(2) or 1)) if m else (0, 0)
            started = started or bool(m)
        elif old or new:
            if line[:1] in (' ', ''):
                old -= 1
                new -= 1
            elif line[:1] == '-':
                old -= 1
            elif line[:1] == '+':
                new -= 1
            elif line[:1] != '\\':   # "\ No newline at end of file"
                bad.append(f'line {i}: not a line of a hunk: {line[:40]!r}')
            if old < 0 or new < 0:
                bad.append(f'line {i}: the hunk is longer than its header says')
                old = new = 0
        elif started and line[:1] in ('+', '-', ' ') and line != '-- ':
            bad.append(f'line {i}: after the end of a hunk, a line no header counts (git apply drops it): {line[:40]!r}')
    if old or new:
        bad.append(f'the last hunk is {old} old and {new} new lines short of its header')
    return bad


status = 0
for path in sys.argv[1:]:
    for problem in check(path)[:5]:
        print(f'{path.rsplit("/", 1)[-1]}: {problem}')
        status = 1
sys.exit(status)
