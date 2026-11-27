#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# The xnu-patches series applies, in order, to the tree the build applies it to: macOS-DroidVM's k27 tree (Apple's xnu at
# the commit its lock pins, plus its own series), made the way scripts/vm-xnu-build.sh makes it (setup-env.py's
# kernel_tree(), which checks the tree against the lock), then `git apply` of every patch as scripts/vm-xnu-rebuild.sh
# does. Every hunk must be as long as its header says (hunks.py: git apply takes a short header without a word and drops
# the lines after it), and the patches must name the files they change the way the rebuild reads them (`+++ b/PATH`: it
# puts those files back before it applies the series again). Nothing is compiled: git and python3, a few seconds.
#   tests/xnu-patches/apply.sh [WORKDIR]     WORKDIR (default: a temporary directory, removed) keeps the clones for the next run
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); POC=$(cd "$HERE/../.." && pwd)
if [ $# -ge 1 ]; then mkdir -p "$1"; W=$(cd "$1" && pwd); else W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; fi
python3 "$HERE/hunks.py" "$POC"/xnu-patches/*.patch
cd "$W"
[ -d dvm/.git ] || git clone -q https://github.com/Droid-VM/macOS-DroidVM dvm
cd dvm
echo "macOS-DroidVM $(git rev-parse --short HEAD)"
python3 -c "import importlib.util as u; s = u.spec_from_file_location('setup_env', 'scripts/setup-env.py'); m = u.module_from_spec(s); s.loader.exec_module(m); m.kernel_tree()"
T=$W/apply; git -C out/x12377/xnu-m worktree remove --force "$T" 2>/dev/null || true
git -C out/x12377/xnu-m worktree add -q --detach "$T" k27
echo "k27 tree $(git -C "$T" rev-parse 'HEAD^{tree}')"
status=0; n=0
for p in "$POC"/xnu-patches/*.patch; do
  if ! git -C "$T" apply "$p"; then echo "FAILED $(basename "$p")"; status=1; break; fi
  n=$((n + 1)); echo "applied $(basename "$p")"
done
if [ $status = 0 ]; then
  grep -h '^+++ b/' "$POC"/xnu-patches/*.patch | sed 's|^+++ b/||' | sort -u > "$W/named"
  { git -C "$T" diff --name-only; git -C "$T" ls-files --others --exclude-standard; } | sort -u > "$W/changed"
  if cmp -s "$W/named" "$W/changed"; then
    echo "$n patches apply in order; they change the $(wc -l < "$W/changed" | tr -d ' ') files they name"
  else
    echo "the files the patches name (+++ b/) are not the files they change:"; diff "$W/named" "$W/changed" | sed 's/^/  /'; status=1
  fi
fi
git -C out/x12377/xnu-m worktree remove --force "$T"
exit $status
