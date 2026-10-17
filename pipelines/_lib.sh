#!/usr/bin/env bash
# glitchbox — shared pipeline helpers.
#
# Sourced by every pipeline. Provides: a tool guard, a bit-exact ffmpeg
# wrapper, content-addressed run IDs, and manifest emission.

set -euo pipefail

GB_SCHEMA=2

gb_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
gb_log() { [ -n "${GB_QUIET:-}" ] || printf '  %s\n' "$*" >&2; }

gb_root() {
  # $GLITCHBOX_ROOT comes from the toolchain environment; fall back to the script's parent.
  printf '%s' "${GLITCHBOX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
}

# ---------------------------------------------------------------------------
# Tool guard
#
# Every tool comes from the Glitchbox toolchain (build/Glitchbox.app, or the
# installed app). Refuse loudly rather than emitting a confusing "command not
# found" three steps in.
# ---------------------------------------------------------------------------
gb_require_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  gb_die "'$1' not found — run inside the Glitchbox toolchain (\`just shell\`, after \`just app\`)"
}

# ---------------------------------------------------------------------------
# Bit-exact ffmpeg
#
# Usage:  gb_ffmpeg <input args...> -- <output args...> <outfile>
#
# The determinism flags MUST land after the input, as output options. Placed
# before -i they bind to the input AVFormatContext, are silently accepted, and
# do nothing — two runs then differ (Matroska writes a random SegmentUID and a
# DateUTC). Verified: 43 differing bytes before the fix, 0 after. Routing every
# call through here is what stops that from being a per-call-site footgun.
# ---------------------------------------------------------------------------
gb_ffmpeg() {
  local -a in=() out=(); local seen=0 a
  for a in "$@"; do
    if [ "$a" = "--" ] && [ $seen -eq 0 ]; then seen=1; continue; fi
    if [ $seen -eq 0 ]; then in+=("$a"); else out+=("$a"); fi
  done
  [ $seen -eq 1 ] || gb_die "gb_ffmpeg: missing '--' separating input from output args"
  ffmpeg -hide_banner -nostdin -loglevel "${GB_LOGLEVEL:-error}" \
    "${in[@]}" \
    -fflags +bitexact -flags:v +bitexact -map_metadata -1 -map_chapters -1 \
    "${out[@]}"
}

# ---------------------------------------------------------------------------
# Hashing / provenance
# ---------------------------------------------------------------------------
gb_sha256() { sha256sum "$1" | cut -d' ' -f1; }

gb_tool_version() {
  # Best-effort single-line version string for a tool, or "absent".
  command -v "$1" >/dev/null 2>&1 || { printf 'absent'; return; }
  case "$1" in
    ffmpeg|ffgac|ffedit|fflive) "$1" -version 2>&1 | head -1 ;;
    sox)                       sox --version 2>&1 | head -1 ;;
    ntsc-rs-cli)               ntsc-rs-cli --version 2>&1 | head -1 ;;
    *)                         "$1" --version 2>&1 | head -1 ;;
  esac
}

# The toolchain's identity: a digest over every pinned source and the build
# script (Resources/toolchain.json, written by packaging/build.sh). Offline and
# stable for as long as the toolchain is.
gb_toolchain() {
  local tc="${GLITCHBOX_TOOLCHAIN:-}/Resources/toolchain.json"
  [ -f "$tc" ] || { printf '{}'; return; }
  jq -cS '{digest, tools}' "$tc"
}

# ---------------------------------------------------------------------------
# Run identity
#
# The run ID is a content hash of everything that can affect the bytes: the
# pipeline, the input's digest, the fully-resolved parameters (defaults
# included, so an implicit default and an explicit one collide correctly), the
# tool versions, and the toolchain digest. Same inputs => same directory =>
# re-running is idempotent and the artifact is regenerable from the manifest.
#
# The timestamp is deliberately NOT part of this.
# ---------------------------------------------------------------------------
gb_begin() {
  GB_PIPELINE=$1; GB_INPUT=$2; GB_PARAMS=$3; GB_TOOLS=$4

  [ -f "$GB_INPUT" ] || gb_die "input not found: $GB_INPUT"
  GB_INPUT_SHA=$(gb_sha256 "$GB_INPUT")
  GB_TOOLCHAIN=$(gb_toolchain)

  GB_IDENTITY=$(jq -cS -n \
    --arg schema "$GB_SCHEMA" \
    --arg pipeline "$GB_PIPELINE" \
    --arg input_sha256 "$GB_INPUT_SHA" \
    --argjson params "$GB_PARAMS" \
    --argjson tools "$GB_TOOLS" \
    --argjson toolchain "$GB_TOOLCHAIN" \
    '{schema:$schema,pipeline:$pipeline,input_sha256:$input_sha256,params:$params,tools:$tools,toolchain:$toolchain}')

  GB_RUN_ID=$(printf '%s' "$GB_IDENTITY" | sha256sum | cut -c1-12)
  GB_RUN_DIR="${GB_OUT_DIR:-$(gb_root)/out}/${GB_PIPELINE}-${GB_RUN_ID}"
  mkdir -p "$GB_RUN_DIR"
  gb_log "run ${GB_PIPELINE}-${GB_RUN_ID} -> ${GB_RUN_DIR#$(gb_root)/}"
}

gb_finish() {
  local output=$1
  [ -f "$output" ] || gb_die "expected output missing: $output"
  jq -S -n \
    --argjson identity "$GB_IDENTITY" \
    --arg input "$(basename "$GB_INPUT")" \
    --arg output "$(basename "$output")" \
    --arg output_sha256 "$(gb_sha256 "$output")" \
    --arg run_id "$GB_RUN_ID" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$identity + {run_id:$run_id, input:$input, output:$output,
                  output_sha256:$output_sha256, generated_at:$generated_at}' \
    > "$GB_RUN_DIR/manifest.json"
  gb_log "manifest ${GB_RUN_DIR#$(gb_root)/}/manifest.json"
  printf '%s\n' "$output"
}
