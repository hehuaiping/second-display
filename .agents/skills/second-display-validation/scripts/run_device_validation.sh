#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
SKILL_DIRECTORY=${SCRIPT_DIRECTORY:h}
WORKSPACE_DIRECTORY=${SKILL_DIRECTORY:h:h:h}
PROGRAM_NAME=${0:t}
BUNDLE_NAME="cloud.cuihua.display"
ABILITY_NAME="EntryAbility"
SCENARIO="animated"
DURATION_SECONDS=120
INSTALL_CURRENT_HAP=1
REQUESTED_DEVICE_ID="${SD_DEVICE_ID:-}"
CONNECTION_TIMEOUT_SECONDS=90
HOST_PID=""

usage() {
    print "用法：$PROGRAM_NAME [--scenario animated|interaction] [--duration 秒数] [--long]"
    print "       [--device id] [--no-install]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            SCENARIO=$2
            shift 2
            ;;
        --duration)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            DURATION_SECONDS=$2
            shift 2
            ;;
        --long)
            DURATION_SECONDS=300
            shift
            ;;
        --device)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            REQUESTED_DEVICE_ID=$2
            shift 2
            ;;
        --no-install)
            INSTALL_CURRENT_HAP=0
            shift
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
done

if [[ "$SCENARIO" != "animated" && "$SCENARIO" != "interaction" ]]; then
    print -u2 "NET_PROTOCOL_MISMATCH: scenario 必须是 animated 或 interaction"
    exit 2
fi
if [[ "$DURATION_SECONDS" != <-> || "$DURATION_SECONDS" -lt 90 ]]; then
    print -u2 "NET_PROTOCOL_MISMATCH: 真机测试时长必须是大于等于 90 的整数秒"
    exit 2
fi

resolve_hdc() {
    if [[ -n "${SD_HDC:-}" && -x "${SD_HDC}" ]]; then
        print -r -- "${SD_HDC}"
        return
    fi
    if command -v hdc >/dev/null 2>&1; then
        command -v hdc
        return
    fi
    local deveco_candidate="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
    if [[ -x "$deveco_candidate" ]]; then
        print -r -- "$deveco_candidate"
        return
    fi
    print -u2 "BUILD_TOOL_UNAVAILABLE: 请将 SD_HDC 设置为 hdc 可执行文件路径"
    return 1
}

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

cleanup() {
    if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" >/dev/null 2>&1; then
        kill -TERM "$HOST_PID" >/dev/null 2>&1 || true
        wait "$HOST_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

cd "$WORKSPACE_DIRECTORY"
HDC_PATH=$(resolve_hdc)
HVIGORW_PATH=$(resolve_hvigorw)

typeset -a AVAILABLE_DEVICES
AVAILABLE_DEVICES=("${(@f)$("$HDC_PATH" list targets | sed '/^[[:space:]]*$/d; /\\[Empty\\]/d')}")
if [[ -n "$REQUESTED_DEVICE_ID" ]]; then
    if (( ${AVAILABLE_DEVICES[(Ie)$REQUESTED_DEVICE_ID]} == 0 )); then
        print -u2 "NET_CONNECTION_LOST: 指定设备 $REQUESTED_DEVICE_ID 未连接"
        exit 1
    fi
    DEVICE_ID=$REQUESTED_DEVICE_ID
elif [[ ${#AVAILABLE_DEVICES} -eq 1 ]]; then
    DEVICE_ID=$AVAILABLE_DEVICES[1]
elif [[ ${#AVAILABLE_DEVICES} -eq 0 ]]; then
    print -u2 "NET_CONNECTION_LOST: 没有已连接并授权的 HarmonyOS 设备"
    exit 1
else
    print -u2 "NET_PROTOCOL_MISMATCH: 检测到多台设备，请设置 SD_DEVICE_ID 或 --device"
    exit 1
fi
typeset -a HDC_COMMAND
HDC_COMMAND=("$HDC_PATH" -t "$DEVICE_ID")

if pgrep -x 'SecondDisplayMacApp' >/dev/null 2>&1; then
    print -u2 "NET_BIND_FAILED: 运行 P3PoCHost 验证前请关闭正常运行的 Second Display Mac 应用"
    exit 1
fi

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
EVIDENCE_DIRECTORY="$WORKSPACE_DIRECTORY/.build/validation/$TIMESTAMP"
mkdir -p "$EVIDENCE_DIRECTORY"
HOST_LOG="$EVIDENCE_DIRECTORY/host.log"
RENDER_SERVICE_LOG="$EVIDENCE_DIRECTORY/render-service-fps.txt"

{
    print "timestamp_utc=$TIMESTAMP"
    print "git_commit=$(git rev-parse HEAD)"
    print "git_status_begin"
    git status --short
    print "git_status_end"
    print "device_id=$DEVICE_ID"
    print "hdc_version=$("$HDC_PATH" -v 2>&1 | tr '\\n' ' ')"
    print "scenario=$SCENARIO"
    print "duration_seconds=$DURATION_SECONDS"
    print "installed_current_hap=$INSTALL_CURRENT_HAP"
} > "$EVIDENCE_DIRECTORY/metadata.txt"

print "[device] 构建 release 版 P3PoCHost"
swift build -c release --product P3PoCHost
"$WORKSPACE_DIRECTORY/tools/provision_p3_tls.sh"

if [[ "$INSTALL_CURRENT_HAP" == "1" ]]; then
    print "[device] 构建已签名的 debug HAP"
    (
        cd harmony
        "$HVIGORW_PATH" assembleHap --mode module \
            -p product=default \
            -p module=entry@default \
            -p buildMode=debug \
            --no-daemon
    )
    HAP_PATH="$WORKSPACE_DIRECTORY/harmony/entry/build/default/outputs/default/entry-default-signed.hap"
    if [[ ! -f "$HAP_PATH" ]]; then
        print -u2 "BUILD_OUTPUT_MISSING: 未生成已签名的 debug HAP"
        exit 1
    fi
    print "[device] 在 $DEVICE_ID 上安装当前 HAP"
    "${HDC_COMMAND[@]}" shell aa force-stop "$BUNDLE_NAME" >/dev/null 2>&1 || true
    "${HDC_COMMAND[@]}" install -r "$HAP_PATH"
else
    HAP_PATH="not-installed-by-script"
fi
print "hap_path=$HAP_PATH" >> "$EVIDENCE_DIRECTORY/metadata.txt"

"${HDC_COMMAND[@]}" shell bm dump -n "$BUNDLE_NAME" \
    > "$EVIDENCE_DIRECTORY/bundle-info.txt" 2>&1
"${HDC_COMMAND[@]}" shell param get const.product.model \
    > "$EVIDENCE_DIRECTORY/device-model.txt" 2>&1 || true
"${HDC_COMMAND[@]}" shell param get const.ohos.fullname \
    > "$EVIDENCE_DIRECTORY/device-os.txt" 2>&1 || true

if [[ "$SCENARIO" == "animated" ]]; then
    ANIMATED_TEST_PATTERN=1
else
    ANIMATED_TEST_PATTERN=0
fi

P3_BINARY="$WORKSPACE_DIRECTORY/.build/release/P3PoCHost"
print "[device] 启动 P3PoCHost 和 HarmonyOS Ability"
P3_POC_DURATION_SECONDS=$DURATION_SECONDS \
P3_POC_MAX_FPS=60 \
P3_POC_ANIMATED_TEST_PATTERN=$ANIMATED_TEST_PATTERN \
P3_POC_TLS_DIRECTORY="$WORKSPACE_DIRECTORY/.build/p3-poc-tls" \
    "$P3_BINARY" > "$HOST_LOG" 2>&1 &
HOST_PID=$!

"${HDC_COMMAND[@]}" shell aa start \
    -a "$ABILITY_NAME" -b "$BUNDLE_NAME" -m entry \
    > "$EVIDENCE_DIRECTORY/ability-start.txt" 2>&1

print "[device] 如设备出现提示，请选择已发现的 Mac 并完成配对"
CONNECTED=0
SECONDS_WAITED=0
while (( SECONDS_WAITED < CONNECTION_TIMEOUT_SECONDS )); do
    if rg -q 'P3 PoC streaming:' "$HOST_LOG"; then
        CONNECTED=1
        break
    fi
    if ! kill -0 "$HOST_PID" >/dev/null 2>&1; then
        break
    fi
    sleep 1
    SECONDS_WAITED=$((SECONDS_WAITED + 1))
done
if [[ "$CONNECTED" != "1" ]]; then
    print -u2 "NET_HANDSHAKE_TIMEOUT: 设备未在 $CONNECTION_TIMEOUT_SECONDS 秒内进入串流状态"
    exit 1
fi

cat > "$EVIDENCE_DIRECTORY/operator-checklist.md" <<EOF
# 真机人工检查清单

- 场景：$SCENARIO
- 时长：$DURATION_SECONDS 秒
- 设备：$DEVICE_ID

## 每次运行

- [ ] 画面在整个运行期间无黑屏、永久冻结或渐进式延迟
- [ ] Host 结束后页面能离开“连接中”，再次启动服务可以重新连接

## interaction / lifecycle / long-run 额外项目

- [ ] 快速鼠标水平和垂直往返 30 秒
- [ ] 连续拖动窗口 30 秒
- [ ] 连续键盘输入和文本滚动 30 秒
- [ ] 单/双指基础操作及三/四/五指映射
- [ ] 横屏→竖屏→横屏，页面可用且能恢复
- [ ] 后台 10 秒后回前台
- [ ] 停止并重启 Host 后重新连接
- [ ] Wi-Fi 断开再恢复一次（5 分钟门禁）

未实际执行的项目保持未勾选；自动指标 PASS 不能替代本清单。
EOF

if [[ "$SCENARIO" == "interaction" ]]; then
    print "[device] 现在执行鼠标、拖窗、键盘、手势、旋转和恢复检查清单"
else
    print "[device] 全屏动态测试正在运行，请观察冻结或渐进式延迟"
fi

SAMPLE_INDEX=0
while kill -0 "$HOST_PID" >/dev/null 2>&1; do
    sleep 10
    SAMPLE_INDEX=$((SAMPLE_INDEX + 1))
    if (( SAMPLE_INDEX % 3 == 0 )); then
        {
            print "sample=$SAMPLE_INDEX"
            "${HDC_COMMAND[@]}" shell top -b -n 1
        } >> "$EVIDENCE_DIRECTORY/top.txt" 2>&1 || true
    fi
done
set +e
wait "$HOST_PID"
HOST_STATUS=$?
set -e
HOST_PID=""
print "host_exit_status=$HOST_STATUS" >> "$EVIDENCE_DIRECTORY/metadata.txt"

print "[device] 采集 RenderService 和屏幕证据"
"${HDC_COMMAND[@]}" shell hidumper -s RenderService \
    -a "secondDisplaySurfaceSurface fps" > "$RENDER_SERVICE_LOG" 2>&1
"${HDC_COMMAND[@]}" shell hidumper -s RenderService \
    -a surface > "$EVIDENCE_DIRECTORY/render-service-surface.txt" 2>&1
"${HDC_COMMAND[@]}" shell hidumper -s RenderService \
    -a screen > "$EVIDENCE_DIRECTORY/screen.txt" 2>&1

set +e
python3 "$SCRIPT_DIRECTORY/analyze_device_metrics.py" \
    --host-log "$HOST_LOG" \
    --render-service "$RENDER_SERVICE_LOG" \
    --json-output "$EVIDENCE_DIRECTORY/metrics.json" \
    --summary-output "$EVIDENCE_DIRECTORY/summary.md"
ANALYZER_STATUS=$?
set -e

print "[device] 证据目录：$EVIDENCE_DIRECTORY"
if [[ "$INSTALL_CURRENT_HAP" != "1" ]]; then
    print -u2 "DEVICE_VALIDATION_INCOMPLETE: --no-install 结果不能用于源码改动验收"
    exit 2
fi
exit "$ANALYZER_STATUS"
