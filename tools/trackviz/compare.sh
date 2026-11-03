#!/bin/bash
# Paired comparisons: base vs base-gts (the time-scale check alone), then base-gts vs each lever.
#   tools/trackviz/compare.sh <run-dir> <path-to-ShotBench>
set -u
RUN=$1; B=$2
mkdir -p "$RUN/compare"
$B compare "$RUN/scores/base.json" "$RUN/scores/base-gts.json" --markdown "$RUN/compare/base_vs_base-gts.md" > "$RUN/compare/base_vs_base-gts.txt" 2>&1
for v in backLink backLinkBoxes boxSeeds extend gap aspect all allBoxes; do
  [ -f "$RUN/scores/$v-gts.json" ] || continue
  $B compare "$RUN/scores/base-gts.json" "$RUN/scores/$v-gts.json" --markdown "$RUN/compare/base-gts_vs_$v-gts.md" > "$RUN/compare/base-gts_vs_$v-gts.txt" 2>&1
done
for f in "$RUN"/compare/*.txt; do echo "== $(basename "$f" .txt)"; grep -E "Verdict|^b \(|^p =" "$f" | head -4; done
