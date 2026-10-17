# videobed — pipeline composition.
#
# Every recipe runs inside the devshell's PATH. Pipelines print their output
# path on stdout and log to stderr, so they compose with $(...).

set shell := ["bash", "-uc"]

OUT := justfile_directory() / "out"

# List available recipes.
default:
    @just --list --unsorted

# Capability report for the current platform.
doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    printf 'platform: %s\n\n' "${VIDEOBED_PLATFORM:-unknown}"
    for t in ffmpeg ffgac ffedit ntsc-rs-cli reactive-vcr bender sox magick pd faust \
             glslviewer-headless sclang csound vspipe; do
      if command -v "$t" >/dev/null 2>&1; then
        printf '  %-20s %s\n' "$t" "ok"
      else
        printf '  %-20s %s\n' "$t" "ABSENT"
      fi
    done
    printf '\npipelines available here:\n'
    for p in mv-mangle analog-pass reactive-vcr bend sonify shader-feedback; do
      if "{{justfile_directory()}}/pipelines/$p" --check >/dev/null 2>&1; then
        printf '  %-20s ok\n' "$p"
      else
        printf '  %-20s unavailable on this platform\n' "$p"
      fi
    done

# analog-pass only.
analog INPUT SEED="42" *ARGS:
    @"{{justfile_directory()}}/pipelines/analog-pass" --seed {{SEED}} {{ARGS}} "{{INPUT}}"

# mv-mangle only.
mangle INPUT SEED="42" *ARGS:
    @"{{justfile_directory()}}/pipelines/mv-mangle" --seed {{SEED}} {{ARGS}} "{{INPUT}}"

# sonify a BMP.
sonify INPUT *ARGS:
    @"{{justfile_directory()}}/pipelines/sonify" {{ARGS}} "{{INPUT}}"

# reactive-vcr only.
reactive INPUT AUDIO *ARGS:
    @"{{justfile_directory()}}/pipelines/reactive-vcr" --audio "{{AUDIO}}" {{ARGS}} "{{INPUT}}"

# bend only (circuit-bent hardware via bender-rs); ARGS e.g. --preset F --set sync.v_roll=0.3
bend INPUT SEED="42" *ARGS:
    @"{{justfile_directory()}}/pipelines/bend" --seed {{SEED}} {{ARGS}} "{{INPUT}}"

# shader-feedback (linux only).
shader *ARGS:
    @"{{justfile_directory()}}/pipelines/shader-feedback" {{ARGS}}

# Full chain: analog-pass -> mv-mangle -> final encode, with a chain manifest.
chain INPUT SEED="42":
    #!/usr/bin/env bash
    set -euo pipefail
    root="{{justfile_directory()}}"
    out="${VB_OUT_DIR:-{{OUT}}}"

    echo "[1/3] analog-pass" >&2
    a=$("$root/pipelines/analog-pass" --seed {{SEED}} "{{INPUT}}")

    echo "[2/3] mv-mangle" >&2
    b=$("$root/pipelines/mv-mangle" --seed {{SEED}} "$a")

    echo "[3/3] final encode" >&2
    # Chain identity is the composition of the two stage run_ids, so the chain
    # directory is itself content-addressed and re-running is idempotent.
    ida=$(jq -r .run_id "$(dirname "$a")/manifest.json")
    idb=$(jq -r .run_id "$(dirname "$b")/manifest.json")
    cid=$(printf '%s' "chain:$ida:$idb" | sha256sum | cut -c1-12)
    dir="$out/chain-$cid"
    mkdir -p "$dir"

    ffmpeg -hide_banner -nostdin -loglevel error -i "$b" \
      -fflags +bitexact -flags:v +bitexact -map_metadata -1 -map_chapters -1 \
      -c:v libx264 -preset veryslow -crf 18 -pix_fmt yuv420p \
      -y "$dir/out.mp4"

    jq -S -n \
      --arg chain_id "$cid" \
      --arg input "{{INPUT}}" \
      --arg input_sha256 "$(sha256sum "{{INPUT}}" | cut -d' ' -f1)" \
      --arg output_sha256 "$(sha256sum "$dir/out.mp4" | cut -d' ' -f1)" \
      --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson stages "[$(cat "$(dirname "$a")/manifest.json"),$(cat "$(dirname "$b")/manifest.json")]" \
      '{schema:"1",chain_id:$chain_id,input:$input,input_sha256:$input_sha256,
        output:"out.mp4",output_sha256:$output_sha256,
        generated_at:$generated_at,stages:$stages}' > "$dir/manifest.json"

    echo "  chain-$cid -> ${dir#$root/}" >&2
    echo "$dir/out.mp4"

# Run a chain twice into separate trees and assert byte-identical output.
verify-repro INPUT SEED="42":
    #!/usr/bin/env bash
    set -euo pipefail
    root="{{justfile_directory()}}"
    t1=$(mktemp -d); t2=$(mktemp -d)
    trap 'rm -rf "$t1" "$t2"' EXIT

    a=$(VB_OUT_DIR="$t1" VB_QUIET=1 just chain "{{INPUT}}" {{SEED}} 2>/dev/null)
    b=$(VB_OUT_DIR="$t2" VB_QUIET=1 just chain "{{INPUT}}" {{SEED}} 2>/dev/null)

    fail=0
    # Compare each stage as well as the final artifact, so a regression names
    # the stage that lost determinism instead of just saying "the chain broke".
    for stage in analog-pass mv-mangle chain; do
      f1=$(find "$t1" -path "*$stage-*" -name 'out.*' | head -1)
      f2=$(find "$t2" -path "*$stage-*" -name 'out.*' | head -1)
      if [ -z "$f1" ] || [ -z "$f2" ]; then
        printf '  %-14s MISSING\n' "$stage"; fail=1; continue
      fi
      h1=$(sha256sum "$f1" | cut -d' ' -f1); h2=$(sha256sum "$f2" | cut -d' ' -f1)
      if [ "$h1" = "$h2" ]; then
        printf '  %-14s reproducible  %s\n' "$stage" "${h1:0:16}"
      else
        printf '  %-14s NOT REPRODUCIBLE  %s != %s\n' "$stage" "${h1:0:16}" "${h2:0:16}"; fail=1
      fi
    done
    [ "$fail" -eq 0 ] && echo "  all stages byte-reproducible" || { echo "  FAILED"; exit 1; }

# Render/validate plugin chains headless (see studio/).
plug *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    pkg="{{justfile_directory()}}/studio/VideobedKit"
    # Strip nix's Apple-SDK vars so the system Swift toolchain works in the devshell.
    clean_env=(env -u SDKROOT -u DEVELOPER_DIR -u NIX_CFLAGS_COMPILE -u NIX_LDFLAGS)
    "${clean_env[@]}" swift build -q -c release --package-path "$pkg" --product vbplug >&2
    bin=$("${clean_env[@]}" swift build -c release --package-path "$pkg" --show-bin-path)
    exec "$bin/vbplug" {{ARGS}}

# Generate the Xcode project, build, and launch Videobed Studio.
studio:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}/studio"
    xcodegen generate --quiet
    # xcodebuild imports environment variables as build settings, so the
    # devshell's CC/LD/SDKROOT/MACOSX_DEPLOYMENT_TARGET would hijack the build
    # (nix ld gets clang-driver flags). Build with a minimal environment.
    env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      xcodebuild -project VideobedStudio.xcodeproj -scheme VideobedStudio \
      -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
      -derivedDataPath .build/xcode -quiet build
    # `open` only re-activates an already-running instance, which would keep the
    # old binary; quit it first (session state is saved continuously).
    if pgrep -qx VideobedStudio; then
      osascript -e 'tell application id "com.kylegrantlucas.videobed-studio" to quit'
      for _ in $(seq 50); do pgrep -qx VideobedStudio || break; sleep 0.2; done
      if pgrep -qx VideobedStudio; then echo "Videobed Studio did not quit; close it and rerun" >&2; exit 1; fi
    fi
    open .build/xcode/Build/Products/Debug/VideobedStudio.app

# Remove all build artifacts.
clean:
    rm -rf "{{OUT}}"
