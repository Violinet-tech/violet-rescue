#!/bin/bash
# Copies the built image to a USB stick and verifies every file, retrying files that fail.
# Run from Git Bash: build/sync-stick.sh /e   (the stick's drive letter). Only reads the source and writes to the stick; erases nothing.
SRC="$(cygpath -u "${TEMP:-$TMP}")/violet-rescue-build/media"
DST="${1:?give the stick, e.g. /e}"
fail=0
cd "$SRC" || exit 2
total=$(find . -type f | wc -l); n=0
while IFS= read -r f; do
  n=$((n+1))
  ok=0
  for try in 1 2 3 4 5 6; do
    if [ -f "$DST/$f" ] && cmp -s "$f" "$DST/$f"; then ok=1; break; fi
    mkdir -p "$(dirname "$DST/$f")" 2>/dev/null
    timeout 300 cp -f "$f" "$DST/$f" 2>/dev/null
    sync
    if cmp -s "$f" "$DST/$f"; then ok=1; break; fi
    sleep 8
  done
  if [ $ok -eq 0 ]; then echo "FAILED $f"; fail=$((fail+1)); fi
  if [ $((n % 25)) -eq 0 ]; then echo "progress $n/$total"; fi
done < <(find . -type f | sort -r)
echo "DONE files=$total failed=$fail"
