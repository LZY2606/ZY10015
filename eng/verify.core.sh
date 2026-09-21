#!/bin/sh
# eng/verify.core.sh - single source of truth for the cross-platform verification pipeline.
# POSIX sh. Thin entry points (eng/verify.sh, eng/verify.ps1) invoke this script.
# It never edits version-controlled files; every generated artifact stays under artifacts/.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ARTIFACTS="$REPO_ROOT/artifacts"
SOLUTION="$REPO_ROOT/NCalc.slnx"
TEST_HOST="$ARTIFACTS/bin/NCalc.Tests/release/NCalc.Tests.dll"
SYNC_PROJECT="$REPO_ROOT/src/NCalc.Sync/NCalc.Sync.csproj"
PACK_DIR="$ARTIFACTS/package"
TOOLS_DIR="$ARTIFACTS/tools"
INSPECTOR="$SCRIPT_DIR/tools/PackageInspector.cs"
LOG_DIR="$ARTIFACTS/logs"
SG_DIR="$ARTIFACTS/sg"
MANIFEST="$ARTIFACTS/packages.sha256"
STAGE_LOG=""
STAGE_START=0
STAGE_NAME=""
STAGE_TOTAL=8
RESULTS=""
AOT="${NVERIFY_AOT:-false}"

if [ "$AOT" = "true" ]; then
    STAGE_TOTAL=10
fi

DOTNET="dotnet"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
# Fail fast instead of silently downloading missing SDK/runtime packs.
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=0

timestamp() {
    date +%s
}

format_duration() {
    secs=$1
    if [ "$secs" -lt 60 ]; then
        printf '%ds' "$secs"
    else
        printf '%dm%02ds' "$((secs / 60))" "$((secs % 60))"
    fi
}

begin_stage() {
    STAGE_NAME=$1
    STAGE_START=$(timestamp)
    STAGE_LOG="$LOG_DIR/$(printf '%02d' "$STAGE_INDEX")-$STAGE_NAME.log"
    mkdir -p "$LOG_DIR"
    printf '\n==> [%d/%d] %s\n' "$STAGE_INDEX" "$STAGE_TOTAL" "$STAGE_NAME"
}

finish_stage() {
    code=$1
    now=$(timestamp)
    elapsed=$((now - STAGE_START))
    dur=$(format_duration "$elapsed")
    if [ "$code" -eq 0 ]; then
        printf '<== [%d/%d] %s OK (%s)\n' "$STAGE_INDEX" "$STAGE_TOTAL" "$STAGE_NAME" "$dur"
        RESULTS="$RESULTS$(printf 'PASS  %-28s %6s\n' "$STAGE_NAME" "$dur")"
    else
        printf '<== [%d/%d] %s FAILED (%s) - raw exit code %d\n' "$STAGE_INDEX" "$STAGE_TOTAL" "$STAGE_NAME" "$dur" "$code"
        printf '\nStage log: %s\n' "$STAGE_LOG"
        exit "$code"
    fi
}

# Run a command, stream output to console and the stage log, preserve the raw exit code.
run() {
    "$@" >"$STAGE_LOG.out" 2>&1
    code=$?
    cat "$STAGE_LOG.out"
    cat "$STAGE_LOG.out" >> "$STAGE_LOG"
    return "$code"
}


# Recreate generated outputs so consecutive runs start from identical inputs.
mkdir -p "$ARTIFACTS"
for d in bin obj package sg logs tools; do
    if [ -d "$ARTIFACTS/$d" ]; then
        find "$ARTIFACTS/$d" -mindepth 1 -delete 2>/dev/null
    fi
done
rm -f "$ARTIFACTS/packages.sha256" 2>/dev/null
mkdir -p "$LOG_DIR" "$TOOLS_DIR"
printf '%s\n' "$(timestamp)" > "$ARTIFACTS/.start"

STAGE_INDEX=1

# Stage 1: SDK required by global.json must be usable - fast actionable diagnostic (<=3s).
begin_stage "sdk-preflight"
GLOBAL_JSON="$REPO_ROOT/global.json"
REQUIRED_VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GLOBAL_JSON" | head -1)
if [ -z "$REQUIRED_VERSION" ]; then
    printf 'ERROR: cannot read sdk:version from %s\n' "$GLOBAL_JSON"
    exit 2
fi
start_check=$(timestamp)
if ! command -v dotnet >/dev/null 2>&1; then
    cat <<EOF
ERROR: the 'dotnet' command was not found.
Required SDK: $REQUIRED_VERSION (pinned by global.json).
Install the .NET SDK, e.g. one of:
  winget install Microsoft.DotNet.SDK.${REQUIRED_VERSION%%.*}
  (or) https://dot.net/v1/dotnet-install.sh --channel ${REQUIRED_VERSION%.*}
Then rerun this script from the repository root.
EOF
    exit 127
fi
LISTED_SDKS=$(dotnet --list-sdks 2>/dev/null)
REQ_MAJOR_MINOR=$(printf '%s' "$REQUIRED_VERSION" | cut -d. -f1-2)
REQ_FEATURE=$(printf '%s' "$REQUIRED_VERSION" | cut -d. -f3)
REQ_FEATURE=${REQ_FEATURE%%[!0-9]*}
[ -z "$REQ_FEATURE" ] && REQ_FEATURE=0
SDK_OK=false
OLD_IFS=$IFS
IFS='
'
for line in $LISTED_SDKS; do
    inst=$(printf '%s' "$line" | awk '{print $1}')
    v=${inst%%-*}
    mm=$(printf '%s' "$v" | cut -d. -f1-2)
    feature=$(printf '%s' "$v" | cut -d. -f3)
    feature=${feature%%[!0-9]*}
    [ -z "$feature" ] && feature=0
    if [ "$mm" = "$REQ_MAJOR_MINOR" ] && [ "$feature" -ge "$REQ_FEATURE" ]; then
        SDK_OK=true
    fi
done
IFS=$OLD_IFS
if [ "$SDK_OK" != "true" ]; then
    cat <<EOF
ERROR: no installed .NET SDK satisfies global.json (checked in $(( $(timestamp) - start_check ))s).
Required: feature band >= $REQUIRED_VERSION on $REQ_MAJOR_MINOR.x (exact pin: $REQUIRED_VERSION; rollForward: latestFeature).
Installed SDKs:
$LISTED_SDKS
Install the required SDK, e.g. one of:
  winget install Microsoft.DotNet.SDK.${REQ_MAJOR_MINOR}
  curl -fsSL https://dot.net/v1/dotnet-install.sh | sh -s -- --channel $REQ_MAJOR_MINOR
Then rerun this script from the repository root.
EOF
    exit 2
fi
finish_stage 0
STAGE_INDEX=$((STAGE_INDEX + 1))

# Stage 2: locked restore against the global packages folder only (offline-safe).
begin_stage "restore-locked"
GLOBAL_PACKAGES=${NUGET_PACKAGES:-$HOME/.nuget/packages}
if [ ! -d "$GLOBAL_PACKAGES" ]; then
    printf 'ERROR: global NuGet package folder not found: %s\nRun the one-time preparation step first:\n  dotnet restore\n' "$GLOBAL_PACKAGES"
    exit 2
fi
run "$DOTNET" restore "$SOLUTION" --locked-mode --artifacts-path "$ARTIFACTS" \
    --source "$GLOBAL_PACKAGES" --source "https://api.nuget.org/v3/index.json"
finish_stage $?
STAGE_INDEX=$((STAGE_INDEX + 1))

# Stage 3: Release build of the whole solution (all TFMs incl. net462/netstandard2.0).
begin_stage "build-release"
run "$DOTNET" build "$SOLUTION" -c Release --no-restore --artifacts-path "$ARTIFACTS"
finish_stage $?
STAGE_INDEX=$((STAGE_INDEX + 1))

# Stage 4: full TUnit suite (Microsoft.Testing.Platform host, built in the previous stage).
begin_stage "test"
run "$DOTNET" "$TEST_HOST" --no-progress
finish_stage $?
STAGE_INDEX=$((STAGE_INDEX + 1))

# Optional CI matrix leg: Native AOT publish + execute (upstream matrix aot=true).
if [ "$AOT" = "true" ]; then
    begin_stage "test-aot"
    AOT_RID=$("$DOTNET" "$SCRIPT_DIR/tools/Rid.cs" 2>/dev/null | tail -1)
    if [ -z "$AOT_RID" ]; then AOT_RID=$(uname -m 2>/dev/null | tr '[:upper:]' '[:lower:]')-$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'); fi
    run "$DOTNET" publish "$REPO_ROOT/test/NCalc.Tests/NCalc.Tests.csproj" -c Release --no-restore \
        --artifacts-path "$ARTIFACTS" -r "$AOT_RID" --self-contained true
    finish_stage $?
    AOT_BIN="$ARTIFACTS/bin/NCalc.Tests/release/net10.0/$AOT_RID/publish/NCalc.Tests"
    STAGE_INDEX=$((STAGE_INDEX + 1))
    begin_stage "run-aot"
    run "$AOT_BIN" --no-progress
    finish_stage $?
    STAGE_INDEX=$((STAGE_INDEX + 1))
fi

# Stage 5: source generator determinism - regenerate and diff against the main build output.
begin_stage "source-generators"
CORE_PROJECT="$REPO_ROOT/src/NCalc.Core/NCalc.Core.csproj"
# Two fully isolated restores+builds under sg/ (never touching the shared
# artifacts/obj, which would make the later pack non-deterministic).
for n in 1 2; do
    probe="$SG_DIR/probe$n"
    run "$DOTNET" restore "$CORE_PROJECT" --locked-mode --artifacts-path "$probe/art" \
        --source "$GLOBAL_PACKAGES" --source "https://api.nuget.org/v3/index.json"
    if [ $? -ne 0 ]; then finish_stage 1; fi
    run "$DOTNET" build "$CORE_PROJECT" -c Release --no-restore --artifacts-path "$probe/art" \
        -p:EmitCompilerGeneratedFiles=true "-p:CompilerGeneratedFilesOutputPath=$probe/out"
    if [ $? -ne 0 ]; then finish_stage 1; fi
done
SG_RUN1="$SG_DIR/probe1/out"
SG_RUN2="$SG_DIR/probe2/out"
if [ -z "$(find "$SG_RUN1" -name '*.cs' -print -quit 2>/dev/null)" ]; then
    printf 'ERROR: no generated sources found under %s\n' "$SG_RUN1"
    finish_stage 1
fi
if [ ! -d "$SG_RUN2" ] || [ -z "$(find "$SG_RUN2" -name '*.cs' -print -quit 2>/dev/null)" ]; then
    printf 'ERROR: no generated sources found under %s\n' "$SG_RUN2"
    finish_stage 1
fi
DIFF_OUTPUT=$(diff -r "$SG_RUN1/NCalc.SourceGenerators" "$SG_RUN2/NCalc.SourceGenerators")
if [ -n "$DIFF_OUTPUT" ]; then
    printf '%s\n' "$DIFF_OUTPUT"
    printf 'ERROR: generated sources differ between builds\n'
    finish_stage 1
fi
GEN_COUNT=$(find "$SG_RUN1" -name '*.cs' | wc -l | tr -d ' ')
printf 'Generated source files verified identical across two builds: %s files\n' "$GEN_COUNT" | tee "$STAGE_LOG"
finish_stage 0
STAGE_INDEX=$((STAGE_INDEX + 1))

# Stage 6: NuGet pack - unsigned Release set plus strongly-signed NCalcSync.
begin_stage "pack"
mkdir -p "$PACK_DIR/release" "$PACK_DIR/signedrelease"
run "$DOTNET" pack "$SOLUTION" -c Release --no-build --artifacts-path "$ARTIFACTS" \
    --output "$PACK_DIR/release" -p:PublicRelease=true
finish_stage $?
STAGE_INDEX=$((STAGE_INDEX + 1))
# SignedRelease maps most projects to Debug; build NCalcSync itself cleanly so its
# strongly-signed PE comes from a deterministic compilation, then pack it.
begin_stage "build-signed"
run "$DOTNET" build "$SYNC_PROJECT" -c SignedRelease --no-restore --no-incremental --artifacts-path "$ARTIFACTS"
finish_stage $?
STAGE_INDEX=$((STAGE_INDEX + 1))
begin_stage "pack-signed"
run "$DOTNET" pack "$SYNC_PROJECT" -c SignedRelease --no-build --no-restore --artifacts-path "$ARTIFACTS" \
    --output "$PACK_DIR/signedrelease" -p:PublicRelease=true
finish_stage $?
STAGE_INDEX=$((STAGE_INDEX + 1))

# Stage 7: content audit + canonical package hashes; normalize to prove determinism.
begin_stage "package-audit"
mkdir -p "$TOOLS_DIR"
mkdir -p "$TOOLS_DIR/normalized"
DOTNET_AUDIT_DUMMY=1 run "$DOTNET" "$REPO_ROOT/eng/tools/PackageInspector.cs" -- audit "$PACK_DIR" "$TOOLS_DIR/normalized" "$REPO_ROOT"
finish_stage $?
STAGE_INDEX=$((STAGE_INDEX + 1))

# Success summary with stable per-stage timing and final package hashes.
TOTAL_ELAPSED=$(($(timestamp) - $(cat "$ARTIFACTS/.start")))
printf '\n================ verification summary ================\n'
printf '%s\n' "$RESULTS"
printf 'TOTAL %33s\n' "$(format_duration "$TOTAL_ELAPSED")"
printf '\nPackage                        SHA256 (normalized)\n'
while IFS=' ' read -r hash rel; do
    name=${rel##*/}
    printf '%-42s %s\n' "$name" "$hash"
done < "$MANIFEST"
printf '\nArtifacts: %s\n' "$ARTIFACTS"
