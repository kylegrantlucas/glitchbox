# glitchbox — app build and pipeline composition.
#
# Pipeline recipes run inside the toolchain environment of build/Glitchbox.app
# (build it once with `just app`). Pipelines print their output path on stdout
# and log to stderr, so they compose with $(...).

set shell := ["bash", "-uc"]

root := justfile_directory()
OUT := root / "out"
contents := root / "build/Glitchbox.app/Contents"
gb := contents / "Helpers/glitchbox"
# Prefix that loads the toolchain environment (hermetic PATH, GStreamer, frei0r, ...).
tc := 'eval "$(' + quote(gb) + ' env --root ' + quote(root) + ' --toolchain ' + quote(contents) + ')" &&'

# List available recipes.
default:
    @just --list --unsorted

# Build build/Glitchbox.app (tools + app) and the DMG. Stages are cached under build/.
app *ARGS:
    "{{root}}/packaging/build.sh" {{ARGS}}

# Open a shell inside the toolchain environment. The toolchain's PATH comes
# first; your own PATH follows it so git, just, and editors keep working.
shell: _toolchain
    @old_path="$PATH"; {{tc}} PATH="$PATH:$old_path" exec "${SHELL:-/bin/zsh}"

# Tool and pipeline report for the built toolchain.
doctor: _toolchain
    #!/usr/bin/env bash
    set -euo pipefail
    {{tc}} true
    printf 'toolchain: %s\n\n' "$GLITCHBOX_TOOLCHAIN"
    jq -r '.tools | to_entries[] | "  \(.key)\t\(.value)"' "$GLITCHBOX_TOOLCHAIN/Resources/toolchain.json" | column -t
    printf '\npipelines:\n'
    for p in mv-mangle analog-pass reactive-vcr bend sonify; do
      if "{{root}}/pipelines/$p" --check >/dev/null 2>&1; then
        printf '  %-14s ok\n' "$p"
      else
        printf '  %-14s MISSING TOOLS\n' "$p"
      fi
    done

# analog-pass only.
analog INPUT SEED="42" *ARGS: _toolchain
    @{{tc}} analog-pass --seed {{SEED}} {{ARGS}} "{{INPUT}}"

# mv-mangle only.
mangle INPUT SEED="42" *ARGS: _toolchain
    @{{tc}} mv-mangle --seed {{SEED}} {{ARGS}} "{{INPUT}}"

# sonify a BMP.
sonify INPUT *ARGS: _toolchain
    @{{tc}} sonify {{ARGS}} "{{INPUT}}"

# reactive-vcr only.
reactive INPUT AUDIO *ARGS: _toolchain
    @{{tc}} "{{root}}/pipelines/reactive-vcr" --audio "{{AUDIO}}" {{ARGS}} "{{INPUT}}"

# bend only (circuit-bent hardware via bender-rs); ARGS e.g. --preset F --set sync.v_roll=0.3
bend INPUT SEED="42" *ARGS: _toolchain
    @{{tc}} bend --seed {{SEED}} {{ARGS}} "{{INPUT}}"

# Full chain: analog-pass -> mv-mangle -> final encode, with a chain manifest.
chain INPUT SEED="42": _toolchain
    #!/usr/bin/env bash
    set -euo pipefail
    {{tc}} true
    out="${GB_OUT_DIR:-{{OUT}}}"

    echo "[1/3] analog-pass" >&2
    a=$(analog-pass --seed {{SEED}} "{{INPUT}}")

    echo "[2/3] mv-mangle" >&2
    b=$(mv-mangle --seed {{SEED}} "$a")

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

    echo "  chain-$cid -> ${dir#{{root}}/}" >&2
    echo "$dir/out.mp4"

# Run a chain twice into separate trees and assert byte-identical output.
verify-repro INPUT SEED="42": _toolchain
    #!/usr/bin/env bash
    set -euo pipefail
    t1=$(mktemp -d); t2=$(mktemp -d)
    trap 'rm -rf "$t1" "$t2"' EXIT

    a=$(GB_OUT_DIR="$t1" GB_QUIET=1 just chain "{{INPUT}}" {{SEED}} 2>/dev/null)
    b=$(GB_OUT_DIR="$t2" GB_QUIET=1 just chain "{{INPUT}}" {{SEED}} 2>/dev/null)

    fail=0
    # Compare each stage as well as the final artifact, so a regression names
    # the stage that lost determinism instead of just saying "the chain broke".
    for stage in analog-pass mv-mangle chain; do
      f1=$(find "$t1" -path "*$stage-*" -name 'out.*' | head -1)
      f2=$(find "$t2" -path "*$stage-*" -name 'out.*' | head -1)
      if [ -z "$f1" ] || [ -z "$f2" ]; then
        printf '  %-14s MISSING\n' "$stage"; fail=1; continue
      fi
      h1=$(shasum -a 256 "$f1" | cut -d' ' -f1); h2=$(shasum -a 256 "$f2" | cut -d' ' -f1)
      if [ "$h1" = "$h2" ]; then
        printf '  %-14s reproducible  %s\n' "$stage" "${h1:0:16}"
      else
        printf '  %-14s NOT REPRODUCIBLE  %s != %s\n' "$stage" "${h1:0:16}" "${h2:0:16}"; fail=1
      fi
    done
    [ "$fail" -eq 0 ] && echo "  all stages byte-reproducible" || { echo "  FAILED"; exit 1; }

# Render/validate plugin chains headless with the CLI built from source (see app/).
plug *ARGS: _toolchain
    #!/usr/bin/env bash
    set -euo pipefail
    pkg="{{root}}/app/GlitchboxKit"
    swift build -q -c release --package-path "$pkg" --product glitchbox >&2
    bin=$(swift build -c release --package-path "$pkg" --show-bin-path)
    exec "$bin/glitchbox" --root "{{root}}" --toolchain "{{contents}}" {{ARGS}}

# Build and launch the Debug app against this checkout's library and build/ toolchain.
dev: _toolchain
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}/app"
    xcodegen generate --quiet
    # xcodebuild imports environment variables as build settings, so a stray
    # CC/LD/SDKROOT from the calling shell would hijack the build. Build with a
    # minimal environment.
    env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      xcodebuild -project Glitchbox.xcodeproj -scheme Glitchbox \
      -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
      -derivedDataPath .build/xcode -quiet build
    # `open` only re-activates an already-running instance, which would keep the
    # old binary; quit it first (session state is saved continuously).
    if pgrep -qx Glitchbox; then
      osascript -e 'tell application id "com.kylegrantlucas.glitchbox" to quit'
      for _ in $(seq 50); do pgrep -qx Glitchbox || break; sleep 0.2; done
      if pgrep -qx Glitchbox; then echo "Glitchbox did not quit; close it and rerun" >&2; exit 1; fi
    fi
    open .build/xcode/Build/Products/Debug/Glitchbox.app

# Remove pipeline outputs (out/). The toolchain under build/ is kept.
clean:
    rm -rf "{{OUT}}"

[private]
_toolchain:
    @[ -x "{{gb}}" ] || { echo "no toolchain at build/Glitchbox.app; run \`just app\` first" >&2; exit 1; }
