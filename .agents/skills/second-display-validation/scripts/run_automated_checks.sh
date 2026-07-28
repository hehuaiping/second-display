#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
SKILL_DIRECTORY=${SCRIPT_DIRECTORY:h}
WORKSPACE_DIRECTORY=${SKILL_DIRECTORY:h:h:h}
PROGRAM_NAME=${0:t}
RUN_RELEASE_TESTS=0

usage() {
    print "用法：$PROGRAM_NAME [--release]"
}

if [[ $# -gt 1 ]]; then
    usage
    exit 2
fi
if [[ $# -eq 1 ]]; then
    case "$1" in
        --release)
            RUN_RELEASE_TESTS=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
fi

resolve_hvigorw() {
    if [[ -n "${SD_HVIGORW:-}" && -x "${SD_HVIGORW}" ]]; then
        print -r -- "${SD_HVIGORW}"
        return
    fi
    if command -v hvigorw >/dev/null 2>&1; then
        command -v hvigorw
        return
    fi
    local bundled_candidate="${HOME}/dev_soft/harmoney/command-line-tools/bin/hvigorw"
    if [[ -x "$bundled_candidate" ]]; then
        print -r -- "$bundled_candidate"
        return
    fi
    print -u2 "BUILD_TOOL_UNAVAILABLE: 请将 SD_HVIGORW 设置为 hvigorw 可执行文件路径"
    return 1
}

resolve_cmake_tool() {
    local environment_name=$1
    local command_name=$2
    local configured_path="${(P)environment_name:-}"
    if [[ -n "$configured_path" && -x "$configured_path" ]]; then
        print -r -- "$configured_path"
        return
    fi
    if command -v "$command_name" >/dev/null 2>&1; then
        command -v "$command_name"
        return
    fi
    local deveco_candidate="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/build-tools/cmake/bin/$command_name"
    if [[ -x "$deveco_candidate" ]]; then
        print -r -- "$deveco_candidate"
        return
    fi
    print -u2 "BUILD_TOOL_UNAVAILABLE: 请将 $environment_name 设置为 $command_name 可执行文件路径"
    return 1
}

run_step() {
    local title=$1
    shift
    print "[validate] $title"
    "$@"
}

cd "$WORKSPACE_DIRECTORY"
HVIGORW_PATH=$(resolve_hvigorw)
CMAKE_PATH=$(resolve_cmake_tool SD_CMAKE cmake)
CTEST_PATH=$(resolve_cmake_tool SD_CTEST ctest)

run_step "共享协议测试向量" python3 tools/validate_shared_vectors.py
run_step "验证技能指标分析器测试" \
    python3 -m unittest discover \
    -s .agents/skills/second-display-validation/tests -p 'test_*.py'
run_step "Swift debug 测试" swift test -c debug
if [[ "$RUN_RELEASE_TESTS" == "1" ]]; then
    run_step "Swift release 测试" swift test -c release
fi
run_step "release 版 P3PoCHost 构建" swift build -c release --product P3PoCHost
run_step "Harmony 原生测试配置" \
    "$CMAKE_PATH" -S harmony/entry/src/main/cpp -B .build/harmony-host \
    -DBUILD_PROTOCOL_TESTS=ON -DCMAKE_BUILD_TYPE=Release
run_step "Harmony 原生测试构建" "$CMAKE_PATH" --build .build/harmony-host --parallel
run_step "Harmony 原生测试" \
    "$CTEST_PATH" --test-dir .build/harmony-host --output-on-failure

print "[validate] HarmonyOS debug HAP 构建"
(
    cd harmony
    "$HVIGORW_PATH" assembleHap --mode module \
        -p product=default \
        -p module=entry@default \
        -p buildMode=debug \
        --no-daemon
)

print "[validate] PrivateAPIShim 私有类型隔离"
if rg -n '\bCGVirtualDisplay(Descriptor|Settings|Mode)?\b' \
    macos --glob '!macos/VirtualDisplayCore/PrivateAPIShim/**'
then
    print -u2 "VD_PRIVATE_API_UNAVAILABLE: CGVirtualDisplay 私有类型被 PrivateAPIShim 之外的代码引用"
    exit 1
fi

run_step "Git 空白字符检查" git diff --check
print "[validate] 自动化检查全部通过"
