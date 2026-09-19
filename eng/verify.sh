#!/bin/sh
# eng/verify.sh — NCalc 跨平台验证入口（核心实现，唯一维护点）。
# Windows 请使用薄入口 eng/verify.ps1，它会转发到本脚本。
#
# 阶段顺序: sdk-check -> restore -> build -> test -> sourcegen-consistency -> pack -> package-check
# 成功时打印各阶段耗时与最终包哈希；失败时保留原始退出码。
# 用法:
#   sh eng/verify.sh                 完整验证（含锁定依赖恢复）
#   sh eng/verify.sh --skip-restore  跳过恢复阶段（离线重放后续阶段）
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT" || exit 1

SOLUTION="NCalc.slnx"
TEST_PROJ="test/NCalc.Tests/NCalc.Tests.csproj"
CORE_PROJ="src/NCalc.Core/NCalc.Core.csproj"
CONFIG="Release"
ARTIFACTS="$REPO_ROOT/artifacts"
LOG_DIR="$ARTIFACTS/logs"
PKG_DIR="$ARTIFACTS/nuget"
SG_DIR="$ARTIFACTS/sourcegen"
PKG_UTILS="$REPO_ROOT/eng/tools/package-utils.cs"

SKIP_RESTORE=0
for arg in "$@"; do
    case "$arg" in
        --skip-restore) SKIP_RESTORE=1 ;;
        -h|--help)
            echo "usage: sh eng/verify.sh [--skip-restore]"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

mkdir -p "$LOG_DIR" "$PKG_DIR"
SUMMARY_FILE="$ARTIFACTS/stages.txt"
: > "$SUMMARY_FILE"
TOTAL_START=$(date +%s)

say() { printf '%s\n' "$*"; }

run_stage() {
    name=$1
    shift
    say "==> stage: $name"
    start=$(date +%s)
    log="$LOG_DIR/$name.log"
    "$@" >"$log" 2>&1
    code=$?
    end=$(date +%s)
    dur=$((end - start))
    if [ "$code" -ne 0 ]; then
        say "ERROR: stage '$name' failed with exit code $code (full log: artifacts/logs/$name.log)" >&2
        tail -n 40 "$log" >&2
        exit "$code"
    fi
    printf '%s|%ss\n' "$name" "$dur" >> "$SUMMARY_FILE"
    say "    [$name] ok (${dur}s)"
}

# --- stage: sdk-check -------------------------------------------------------
# 只读取 global.json 与 `dotnet --list-sdks`，数秒内给出可执行诊断。
stage_sdk_check() {
    req_version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' global.json | head -n 1)
    roll_forward=$(sed -n 's/.*"rollForward"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' global.json | head -n 1)
    [ -n "$req_version" ] || { echo "cannot parse sdk.version from global.json" >&2; return 1; }
    [ -n "$roll_forward" ] || roll_forward="latestPatch"

    if ! command -v dotnet >/dev/null 2>&1; then
        echo "ERROR: 未找到 dotnet。需要 .NET SDK $req_version (rollForward: $roll_forward)。" >&2
        echo "修复: 从 https://dotnet.microsoft.com/download 安装，或运行 dotnet-install 脚本 (--version $req_version)。" >&2
        return 1
    fi

    req_major=${req_version%%.*}
    rest=${req_version#*.}
    req_minor=${rest%%.*}
    req_patch=${rest#*.}
    req_patch=${req_patch%%-*}
    req_band=$((req_patch / 100))

    installed=$(dotnet --list-sdks 2>/dev/null | awk '{print $1}')
    match=""
    for v in $installed; do
        case "$v" in
            "$req_major.$req_minor."*) : ;;
            *) continue ;;
        esac
        p=${v##*.}
        p=${p%%-*}
        band=$((p / 100))
        case "$roll_forward" in
            latestFeature|latestMinor|latestMajor)
                [ "$band" -ge "$req_band" ] || continue ;;
            *)
                { [ "$band" -eq "$req_band" ] && [ "$p" -ge "$req_patch" ]; } || continue ;;
        esac
        match=$v
    done

    if [ -z "$match" ]; then
        echo "ERROR: global.json 需要 .NET SDK $req_version (rollForward: $roll_forward)，但未找到兼容版本。" >&2
        echo "已安装的 SDK:" >&2
        dotnet --list-sdks >&2
        echo "修复（任选其一）:" >&2
        echo "  1. 从 https://dotnet.microsoft.com/download 安装 .NET SDK $req_version" >&2
        echo "  2. 使用 dotnet-install: ./dotnet-install.sh --version $req_version (Windows: dotnet-install.ps1 -Version $req_version)" >&2
        return 1
    fi

    echo "sdk-check: required $req_version (rollForward: $roll_forward), using $match"
}

# --- stage: restore ---------------------------------------------------------
# 锁定模式恢复：严格按 packages.lock.json 校验，不升级、不联网补齐缺失输入。
stage_restore() {
    dotnet restore "$SOLUTION" --locked-mode
}

# --- stage: build -----------------------------------------------------------
stage_build() {
    dotnet build "$SOLUTION" -c "$CONFIG" --no-restore
}

# --- stage: test ------------------------------------------------------------
stage_test() {
    dotnet test --project "$TEST_PROJ" -c "$CONFIG" --no-restore
}

# --- stage: sourcegen-consistency -------------------------------------------
# 每个目标框架各构建两次并对比 source generator 产物，保证生成一致性。
stage_sourcegen_consistency() {
    rm -rf "$SG_DIR"
    for run in 1 2; do
        for tfm in net462 netstandard2.0 net8.0 net10.0; do
            dotnet build "$CORE_PROJ" -c "$CONFIG" -f "$tfm" --no-restore \
                -p:EmitCompilerGeneratedFiles=true \
                -p:CompilerGeneratedFilesOutputPath="$SG_DIR/run$run/$tfm" || return $?
        done
    done
    diff -r "$SG_DIR/run1" "$SG_DIR/run2" && echo "sourcegen-consistency: generated files identical across two runs"
}

# --- stage: pack ------------------------------------------------------------
# 打包后规范化 nupkg/snupkg（固定时间戳、确定性 psmdcp 命名），保证两次运行哈希一致。
stage_pack() {
    rm -rf "$PKG_DIR"
    mkdir -p "$PKG_DIR"
    dotnet pack "$SOLUTION" -c "$CONFIG" --no-build -o "$PKG_DIR" || return $?
    dotnet run "$PKG_UTILS" -- normalize "$PKG_DIR"
}

# --- stage: package-check ---------------------------------------------------
# 校验包内无 test/example/临时日志/绝对路径，并输出 sha256 清单。
stage_package_check() {
    dotnet run "$PKG_UTILS" -- check "$PKG_DIR" "$REPO_ROOT"
}

run_stage sdk-check stage_sdk_check
if [ "$SKIP_RESTORE" -eq 1 ]; then
    say "==> stage: restore (skipped via --skip-restore)"
else
    run_stage restore stage_restore
fi
run_stage build stage_build
run_stage test stage_test
run_stage sourcegen-consistency stage_sourcegen_consistency
run_stage pack stage_pack
run_stage package-check stage_package_check

TOTAL_END=$(date +%s)
say ""
say "================ verify summary ================"
while IFS='|' read -r stage_name stage_dur; do
    printf '%-26s %8s\n' "$stage_name" "$stage_dur"
done < "$SUMMARY_FILE"
printf '%-26s %8s\n' "TOTAL" "$((TOTAL_END - TOTAL_START))s"
say ""
say "packages (artifacts/nuget, sha256):"
cat "$PKG_DIR/SHA256SUMS.txt"
say "manifest-sha256: $(cat "$PKG_DIR/SHA256SUMS.txt.sha256")"
say ""
say "VERIFY OK"
