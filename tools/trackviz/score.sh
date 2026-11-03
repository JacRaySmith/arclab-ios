#!/bin/bash
# Score every variant cache under <run-dir>/cache with ShotBench (autoFoundNoPool geometry, shipping acceptance),
# writing <run-dir>/scores/<variant>.json|.md. Run from the repo root so the labels resolve.
#   tools/trackviz/score.sh <run-dir> <path-to-ShotBench>
set -u
RUN=$1; B=$2
mkdir -p "$RUN/scores"
for dir in "$RUN"/cache/*/; do
  name=$(basename "$dir")
  "$B" run "$dir" --variant autoFoundNoPool --json "$RUN/scores/$name.json" --markdown "$RUN/scores/$name.md" > "$RUN/scores/$name.log" 2>&1 \
    || echo "ShotBench failed on $name"
done
echo scored
