#!/bin/zsh
# Debug: snap.sh <outdir> <seconds> <args...> — runs the debug build and keeps its window snapshots.
out=$1; secs=$2; shift 2
rm -rf "$out"; mkdir -p "$out"
.build/debug/Fala "$@" --snap "$out" >/dev/null 2>&1 &
pid=$!
sleep "$secs"; kill $pid 2>/dev/null
