#!/usr/bin/env bash
# Self-pivot (ask-back) precision run. PAID unless --dry-run: one OpenAI Responses request per gate candidate
# (about 15 short requests, store false), with the key read from OPENAI_API_KEY in the environment only (never
# an argument, never printed or written). CI never runs it; run it only after an explicit go-ahead.
#
#   OPENAI_API_KEY=... LISTEN_MORE_PAID_RUN=1 swift/scripts/self-pivot-precision.sh [--out DIR]
#   swift/scripts/self-pivot-precision.sh --dry-run [--stub-answer none|self_pivot] [--out DIR]
#
# Writes pivot-eval.md and pivot-eval.json (numbers and labels only). Exit 0 when the bar holds: no false
# self_pivot cue on a negative, store:false on every request, no case text in any output or log line.
set -euo pipefail
cd "$(dirname "$0")/../Packages/ListenMoreHarness"
for a in "$@"; do
  case "$a" in
    sk-*|*OPENAI_API_KEY*) echo "refusing an argument that looks like a key; set OPENAI_API_KEY in the environment" >&2; exit 2 ;;
  esac
done
dry=0
for a in "$@"; do [[ "$a" == "--dry-run" ]] && dry=1; done
if [[ $dry -eq 0 ]]; then
  [[ "${LISTEN_MORE_PAID_RUN:-}" == "1" ]] || { echo "paid run: set LISTEN_MORE_PAID_RUN=1 to confirm, or pass --dry-run" >&2; exit 2; }
  [[ -n "${OPENAI_API_KEY:-}" ]] || { echo "paid run: OPENAI_API_KEY is not set" >&2; exit 2; }
fi
swift run -q lm-pivot-eval "$@"
