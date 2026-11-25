#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -f "$out/bench"; rmdir "$out"' EXIT
core=Sources/AuraMotionCore
swiftc -O scripts/compare_live.swift "$core"/Capture/*.swift "$core"/Vision/*.swift \
    "$core"/Domain/{HandSample,HandJoint,EstimatedHandedness}.swift -o "$out/bench"
"$out/bench" "$@"
