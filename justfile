# Mapo native dev loop (ENGINEERING §3). `just --list` is the source of truth.
# The justfile never reads MAPO_INSTANCE: a Mapo tab sets it, and honoring it would let
# `just dev` inside a tab target that tab's instance.

set shell := ["zsh", "-euo", "pipefail", "-c"]
set positional-arguments

instance := env_var_or_default("MAPO_DEV_INSTANCE", "dev-" + file_name(justfile_directory()))
profile := env_var_or_default("MAPO_DEV_PROFILE", "debug")
jobs := env_var_or_default("MAPO_JOBS", num_cpus())
task := "snap"

config := if profile == "release" { "Release" } else { "Debug" }
cargo_profile_flag := if profile == "release" { "--release" } else { "" }
bin := justfile_directory() / "target" / profile / "mapo"
app_bundle := justfile_directory() / ".build/xcode/Build/Products" / config / "Mapo.app"
kit := justfile_directory() / "app/Packages/MapoKit"

# List the recipes.
default:
    @just --list

[private]
guard:
    @if [[ "{{instance}}" == main ]]; then echo "refusing instance=main: dev work never touches main (ENGINEERING §2.8)" >&2; exit 1; fi

# Check the toolchain, fetch GhosttyKit, generate code and create evidence/.
setup: guard
    #!/bin/zsh
    set -uo pipefail
    missing=()
    ver() { "$@" 2>/dev/null | head -n 1; }
    check() { # name, install hint, version command...
        local name=$1 hint=$2; shift 2
        if command -v "$name" >/dev/null; then printf '  %-10s %s\n' "$name" "$(ver "$@")"; else missing+=("$name: $hint"); fi
    }
    echo "required:"
    check xcodebuild "install Xcode 27" xcodebuild -version
    check cargo "install rustup (https://rustup.rs)" cargo --version
    check xcodegen "brew install xcodegen" xcodegen --version
    check just "brew install just" just --version
    check mprocs "brew install mprocs" mprocs --version
    check jq "brew install jq" jq --version
    echo "optional:"
    for opt in zig sccache; do
        if command -v $opt >/dev/null; then printf '  %-10s %s\n' $opt "$(ver $opt version)"; else printf '  %-10s not installed (optional)\n' $opt; fi
    done
    if (( ${#missing} )); then
        echo "missing tools:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        exit 1
    fi
    if [[ -f third_party/ghostty.lock ]]; then just instance={{instance}} ghostty; else echo "ghostty: no third_party/ghostty.lock yet (PLAN T0.8a)"; fi
    just instance={{instance}} gen
    mkdir -p evidence

# Fetch and verify the pinned GhosttyKit, then link it into .build/ghostty.
ghostty: guard
    @if [[ -x scripts/ghostty.sh ]]; then exec scripts/ghostty.sh; else echo "not yet: PLAN T0.8a" >&2; exit 1; fi

# Generate Swift protocol types and the Xcode project.
gen: guard
    #!/bin/zsh
    set -euo pipefail
    if [[ -x scripts/gen-swift.sh ]]; then scripts/gen-swift.sh; fi
    mkdir -p .build
    xcodegen generate --quiet --spec app/project.yml --use-cache --cache-path .build/xcodegen.cache

# Build the Rust binary and the app.
build: guard
    #!/bin/zsh
    set -euo pipefail
    cargo build -p mapo -j {{jobs}} {{cargo_profile_flag}}
    just instance={{instance}} profile={{profile}} gen
    mkdir -p .build/logs
    identity="${MAPO_SIGN_IDENTITY:--}"
    if ! xcodebuild -project app/Mapo.xcodeproj -scheme Mapo -configuration {{config}} \
        -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' -jobs {{jobs}} \
        MAPO_PROFILE={{profile}} CODE_SIGN_IDENTITY="$identity" build > .build/logs/xcodebuild.log 2>&1; then
        grep -E '(error|warning):' .build/logs/xcodebuild.log | sort -u | head -n 60 >&2 || true
        echo "xcodebuild failed; full log in .build/logs/xcodebuild.log" >&2
        exit 1
    fi
    grep -E ':[0-9]+:[0-9]+: warning:' .build/logs/xcodebuild.log | sort -u | head -n 30 || true
    echo "{{app_bundle}}"

# Run the daemon in the foreground.
daemon: guard
    #!/bin/zsh
    set -euo pipefail
    if ! {{bin}} daemon --help >/dev/null 2>&1; then echo "not yet: PLAN T0.3" >&2; exit 1; fi
    cargo build -p mapo -j {{jobs}} {{cargo_profile_flag}}
    exec {{bin}} daemon --instance {{instance}} --foreground

# Build, stop this instance's previous app, then run the app in the foreground.
app *ARGS: guard
    @echo "not yet: PLAN T0.7" >&2; exit 1

# Run the daemon and the app under mprocs.
dev: guard
    #!/bin/zsh
    set -euo pipefail
    just instance={{instance}} profile={{profile}} build
    export MAPO_DEV_INSTANCE={{instance}} MAPO_DEV_PROFILE={{profile}}
    exec mprocs --config mprocs.yaml

# Run the CLI against this instance, as the operator.
mapo *ARGS: guard
    #!/bin/zsh
    set -euo pipefail
    if [[ ! -x {{bin}} ]]; then echo "{{bin}} is missing: run just build" >&2; exit 1; fi
    unset MAPO_TOKEN MAPO_HOOK_TOKEN
    exec {{bin}} --instance {{instance}} "$@"

# Build, then run drives/NAME.sh.
drive NAME *ARGS:
    #!/bin/zsh
    set -euo pipefail
    if [[ ! -f "drives/$1.sh" ]]; then echo "no drive drives/$1.sh" >&2; exit 1; fi
    just profile={{profile}} build
    export MAPO_ROOT={{justfile_directory()}} MAPO_PROFILE={{profile}}
    exec zsh "drives/$1.sh" "${@:2}"

# Save a snapshot and a screenshot of this instance's window into evidence/.
snap STEP="manual": guard
    @echo "not yet: PLAN T0.9" >&2; exit 1

# Stop this instance's app and daemon.
kill: guard
    @echo "not yet: PLAN T0.2" >&2; exit 1

# Stop an instance and delete its data.
clean-instance NAME="": guard
    @echo "not yet: PLAN T0.2" >&2; exit 1

# Format Rust and Swift sources.
fmt:
    #!/bin/zsh
    set -euo pipefail
    cargo fmt --all
    files=(${(f)"$(find app -name '*.swift' -not -path '*/Generated/*' -not -path '*/.build/*')"})
    if xcrun --find swift-format >/dev/null 2>&1; then xcrun swift-format format --in-place "${files[@]}"; fi

# Check formatting, clippy, Swift lint and drive syntax.
lint:
    #!/bin/zsh
    set -euo pipefail
    cargo fmt --all --check
    cargo clippy --workspace --all-targets -j {{jobs}} -- -D warnings
    files=(${(f)"$(find app -name '*.swift' -not -path '*/Generated/*' -not -path '*/.build/*')"})
    if xcrun --find swift-format >/dev/null 2>&1; then
        xcrun swift-format lint --strict "${files[@]}"
    else
        echo "swift-format not found: skipping Swift lint"
    fi
    drives=(drives/*.sh(N))
    for d in "${drives[@]}"; do zsh -n "$d"; done

# Run the pure-logic unit tests.
test:
    cargo test --workspace -j {{jobs}}
    swift test --package-path {{kit}} --scratch-path .build/swiftpm
