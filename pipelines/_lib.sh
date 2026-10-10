#!/usr/bin/env bash
# videobed — shared pipeline helpers.
#
# Sourced by every pipeline. Provides: platform guards, a bit-exact ffmpeg
# wrapper, content-addressed run IDs, and manifest emission.

set -euo pipefail

VB_SCHEMA=1

vb_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
vb_log() { [ -n "${VB_QUIET:-}" ] || printf '  %s\n' "$*" >&2; }

vb_root() {
  # $VIDEOBED_ROOT is exported by the devshell; fall back to the script's parent.
  printf '%s' "${VIDEOBED_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
}

# ---------------------------------------------------------------------------
# Platform guards
#
# Some tools are genuinely unavailable on aarch64-darwin (glslviewer, csound and
# supercollider are all broken or linux-only in nixpkgs). Refuse loudly with the
# reason rather than emitting a confusing "command not found" three steps in.
# ---------------------------------------------------------------------------
vb_require_cmd() {
  local cmd=$1 why=${2:-}
  command -v "$cmd" >/dev/null 2>&1 && return 0
  if [ -n "$why" ]; then
    vb_die "'$cmd' is not available on ${VIDEOBED_PLATFORM:-this platform}: $why"
  fi
  vb_die "'$cmd' not found — are you inside \`nix develop\`?"
}

vb_require_linux() {
  case "${VIDEOBED_PLATFORM:-$(uname -s)}" in
    *linux*|Linux) : ;;
    *) vb_die "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Bit-exact ffmpeg
#
# Usage:  vb_ffmpeg <input args...> -- <output args...> <outfile>
#
# The determinism flags MUST land after the input, as output options. Placed
# before -i they bind to the input AVFormatContext, are silently accepted, and
# do nothing — two runs then differ (Matroska writes a random SegmentUID and a
# DateUTC). Verified: 43 differing bytes before the fix, 0 after. Routing every
# call through here is what stops that from being a per-call-site footgun.
# ---------------------------------------------------------------------------
vb_ffmpeg() {
  local -a in=() out=(); local seen=0 a
  for a in "$@"; do
    if [ "$a" = "--" ] && [ $seen -eq 0 ]; then seen=1; continue; fi
    if [ $seen -eq 0 ]; then in+=("$a"); else out+=("$a"); fi
  done
  [ $seen -eq 1 ] || vb_die "vb_ffmpeg: missing '--' separating input from output args"
  ffmpeg -hide_banner -nostdin -loglevel "${VB_LOGLEVEL:-error}" \
    "${in[@]}" \
    -fflags +bitexact -flags:v +bitexact -map_metadata -1 -map_chapters -1 \
    "${out[@]}"
}

# ---------------------------------------------------------------------------
# Hashing / provenance
# ---------------------------------------------------------------------------
vb_sha256() { sha256sum "$1" | cut -d' ' -f1; }

vb_tool_version() {
  # Best-effort single-line version string for a tool, or "absent".
  command -v "$1" >/dev/null 2>&1 || { printf 'absent'; return; }
  case "$1" in
    ffmpeg|ffgac|ffedit|fflive) "$1" -version 2>&1 | head -1 ;;
    sox)                       sox --version 2>&1 | head -1 ;;
    ntsc-rs-cli)               ntsc-rs-cli --version 2>&1 | head -1 ;;
    glslViewer)                glslViewer --version 2>&1 | head -1 ;;
    *)                         "$1" --version 2>&1 | head -1 ;;
  esac
}

# Locked input revisions, read straight out of flake.lock. No `nix` invocation,
# no network — this stays correct and offline even years later.
vb_flake_locks() {
  local lock; lock="$(vb_root)/flake.lock"
  [ -f "$lock" ] || { printf '{}'; return; }
  jq -c '[.nodes | to_entries[]
          | select(.value.locked != null)
          | {key: .key, value: (.value.locked.rev // .value.locked.narHash)}]
         | from_entries' "$lock"
}

# ---------------------------------------------------------------------------
# Run identity
#
# The run ID is a content hash of everything that can affect the bytes: the
# pipeline, the input's digest, the fully-resolved parameters (defaults
# included, so an implicit default and an explicit one collide correctly), the
# tool versions, and the locked flake inputs. Same inputs => same directory =>
# re-running is idempotent and the artifact is regenerable from the manifest.
#
# The timestamp is deliberately NOT part of this.
# ---------------------------------------------------------------------------
vb_begin() {
  VB_PIPELINE=$1; VB_INPUT=$2; VB_PARAMS=$3; VB_TOOLS=$4

  [ -f "$VB_INPUT" ] || vb_die "input not found: $VB_INPUT"
  VB_INPUT_SHA=$(vb_sha256 "$VB_INPUT")
  VB_LOCKS=$(vb_flake_locks)

  VB_IDENTITY=$(jq -cS -n \
    --arg schema "$VB_SCHEMA" \
    --arg pipeline "$VB_PIPELINE" \
    --arg input_sha256 "$VB_INPUT_SHA" \
    --argjson params "$VB_PARAMS" \
    --argjson tools "$VB_TOOLS" \
    --argjson locks "$VB_LOCKS" \
    '{schema:$schema,pipeline:$pipeline,input_sha256:$input_sha256,params:$params,tools:$tools,locks:$locks}')

  VB_RUN_ID=$(printf '%s' "$VB_IDENTITY" | sha256sum | cut -c1-12)
  VB_RUN_DIR="${VB_OUT_DIR:-$(vb_root)/out}/${VB_PIPELINE}-${VB_RUN_ID}"
  mkdir -p "$VB_RUN_DIR"
  vb_log "run ${VB_PIPELINE}-${VB_RUN_ID} -> ${VB_RUN_DIR#$(vb_root)/}"
}

vb_finish() {
  local output=$1
  [ -f "$output" ] || vb_die "expected output missing: $output"
  jq -S -n \
    --argjson identity "$VB_IDENTITY" \
    --arg input "$(basename "$VB_INPUT")" \
    --arg output "$(basename "$output")" \
    --arg output_sha256 "$(vb_sha256 "$output")" \
    --arg run_id "$VB_RUN_ID" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$identity + {run_id:$run_id, input:$input, output:$output,
                  output_sha256:$output_sha256, generated_at:$generated_at}' \
    > "$VB_RUN_DIR/manifest.json"
  vb_log "manifest ${VB_RUN_DIR#$(vb_root)/}/manifest.json"
  printf '%s\n' "$output"
}
