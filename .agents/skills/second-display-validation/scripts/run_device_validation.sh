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
CONNECTION_TIMEOUT_SECONDS="${SD_CONNECTION_TIMEOUT_SECONDS:-90}"
UI_AUTOMATION_ENABLED="${SD_UI_AUTOMATION:-1}"
HOST_PID=""

usage() {
    print "用法：$PROGRAM_NAME [--scenario animated|interaction] [--duration 秒数] [--long]"
    print "       [--device id] [--no-install] [--manual-ui]"
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
        --manual-ui)
            UI_AUTOMATION_ENABLED=0
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
if [[ "$CONNECTION_TIMEOUT_SECONDS" != <-> || "$CONNECTION_TIMEOUT_SECONDS" -lt 15 ]]; then
    print -u2 "NET_PROTOCOL_MISMATCH: SD_CONNECTION_TIMEOUT_SECONDS 必须是大于等于 15 的整数秒"
    exit 2
fi
if [[ "$UI_AUTOMATION_ENABLED" != "0" && "$UI_AUTOMATION_ENABLED" != "1" ]]; then
    print -u2 "NET_PROTOCOL_MISMATCH: SD_UI_AUTOMATION 必须是 0 或 1"
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
    print "ui_automation_enabled=$UI_AUTOMATION_ENABLED"
    print "connection_timeout_seconds=$CONNECTION_TIMEOUT_SECONDS"
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
HOST_RUNTIME_SECONDS=$((DURATION_SECONDS + CONNECTION_TIMEOUT_SECONDS + 30))
print "[device] 启动 P3PoCHost 和 HarmonyOS Ability"
P3_POC_DURATION_SECONDS=$HOST_RUNTIME_SECONDS \
P3_POC_MAX_FPS=60 \
P3_POC_ANIMATED_TEST_PATTERN=$ANIMATED_TEST_PATTERN \
P3_POC_TLS_DIRECTORY="$WORKSPACE_DIRECTORY/.build/p3-poc-tls" \
    "$P3_BINARY" > "$HOST_LOG" 2>&1 &
HOST_PID=$!

"${HDC_COMMAND[@]}" shell aa start \
    -a "$ABILITY_NAME" -b "$BUNDLE_NAME" -m entry \
    > "$EVIDENCE_DIRECTORY/ability-start.txt" 2>&1

REMOTE_UI_LAYOUT="/data/local/tmp/second-display-validation-layout.json"
LOCAL_UI_LAYOUT="$EVIDENCE_DIRECTORY/device-ui-layout.json"
UI_ACTION_LOG="$EVIDENCE_DIRECTORY/ui-actions.log"
UI_DUMP_LOG="$EVIDENCE_DIRECTORY/ui-dump.log"

dump_device_ui() {
    "${HDC_COMMAND[@]}" shell uitest dumpLayout \
        -b "$BUNDLE_NAME" -p "$REMOTE_UI_LAYOUT" >> "$UI_DUMP_LOG" 2>&1 \
        || return 1
    "${HDC_COMMAND[@]}" file recv "$REMOTE_UI_LAYOUT" "$LOCAL_UI_LAYOUT" \
        >> "$UI_DUMP_LOG" 2>&1
}

stream_has_real_frames() {
    rg -q \
        'P3 PoC streaming:.*recv [1-9][0-9]*\.[0-9]+/display .*encoded=[1-9][0-9]*' \
        "$HOST_LOG"
}

if [[ "$UI_AUTOMATION_ENABLED" == "1" ]]; then
    print "[device] 自动查找已配对的 Mac，并在真实流就绪后开始采样"
else
    print "[device] 已禁用界面自动化，请在设备上选择已配对的 Mac"
fi
CONNECTED=0
SECONDS_WAITED=0
SCAN_CLICKED=0
PAIRING_REQUIRED_SEEN=0
CONNECT_CLICK_COUNT=0
LAST_CONNECT_CLICK_SECOND=-30
NEXT_UI_INSPECTION_SECOND=0
while (( SECONDS_WAITED < CONNECTION_TIMEOUT_SECONDS )); do
    if stream_has_real_frames; then
        CONNECTED=1
        break
    fi
    if ! kill -0 "$HOST_PID" >/dev/null 2>&1; then
        break
    fi

    if [[ "$UI_AUTOMATION_ENABLED" == "1" \
        && "$SECONDS_WAITED" -ge "$NEXT_UI_INSPECTION_SECOND" ]]; then
        NEXT_UI_INSPECTION_SECOND=$((SECONDS_WAITED + 2))
        UI_DECISION="INVALID_LAYOUT 0 0"
        if dump_device_ui; then
            UI_DECISION=$(python3 "$SCRIPT_DIRECTORY/resolve_device_ui_action.py" \
                --layout "$LOCAL_UI_LAYOUT" 2>> "$UI_ACTION_LOG") \
                || UI_DECISION="INVALID_LAYOUT 0 0"
        fi
        read -r UI_ACTION UI_X UI_Y <<< "$UI_DECISION"
        print "$(date -u '+%Y-%m-%dT%H:%M:%SZ') action=$UI_ACTION x=$UI_X y=$UI_Y" \
            >> "$UI_ACTION_LOG"
        case "$UI_ACTION" in
            ACCEPT_PRIVACY)
                "${HDC_COMMAND[@]}" shell uitest uiInput click "$UI_X" "$UI_Y" \
                    >> "$UI_ACTION_LOG" 2>&1 || true
                ;;
            SCAN)
                if [[ "$SCAN_CLICKED" == "0" ]]; then
                    "${HDC_COMMAND[@]}" shell uitest uiInput click "$UI_X" "$UI_Y" \
                        >> "$UI_ACTION_LOG" 2>&1 || true
                    SCAN_CLICKED=1
                fi
                ;;
            CONNECT)
                if (( CONNECT_CLICK_COUNT < 2 \
                    && SECONDS_WAITED - LAST_CONNECT_CLICK_SECOND >= 10 )); then
                    "${HDC_COMMAND[@]}" shell uitest uiInput click "$UI_X" "$UI_Y" \
                        >> "$UI_ACTION_LOG" 2>&1 || true
                    CONNECT_CLICK_COUNT=$((CONNECT_CLICK_COUNT + 1))
                    LAST_CONNECT_CLICK_SECOND=$SECONDS_WAITED
                fi
                ;;
            PAIRING_REQUIRED)
                PAIRING_REQUIRED_SEEN=1
                ;;
        esac
    fi
    sleep 1
    SECONDS_WAITED=$((SECONDS_WAITED + 1))
done
{
    print "connection_ready=$CONNECTED"
    print "connection_wait_seconds=$SECONDS_WAITED"
    print "ui_scan_clicked=$SCAN_CLICKED"
    print "ui_connect_click_count=$CONNECT_CLICK_COUNT"
    print "pairing_required_seen=$PAIRING_REQUIRED_SEEN"
} >> "$EVIDENCE_DIRECTORY/metadata.txt"
if [[ "$CONNECTED" != "1" ]]; then
    {
        print "connected_measurement_seconds=0"
        print "measurement_completed=0"
    } >> "$EVIDENCE_DIRECTORY/metadata.txt"
    # 即使没有进入采样阶段也生成机器可读的 INCOMPLETE 证据，不能把连接失败误认为性能失败。
    python3 "$SCRIPT_DIRECTORY/analyze_device_metrics.py" \
        --host-log "$HOST_LOG" \
        --render-service "$RENDER_SERVICE_LOG" \
        --metadata "$EVIDENCE_DIRECTORY/metadata.txt" \
        --json-output "$EVIDENCE_DIRECTORY/metrics.json" \
        --summary-output "$EVIDENCE_DIRECTORY/summary.md" \
        >/dev/null 2>&1 || true
    if [[ "$PAIRING_REQUIRED_SEEN" == "1" ]]; then
        print -u2 "NET_PAIRING_REQUIRED: 设备发现了未配对的 Mac；请先人工完成一次安全配对"
    else
        print -u2 \
            "NET_HANDSHAKE_TIMEOUT: 自动界面操作后仍未在 $CONNECTION_TIMEOUT_SECONDS 秒内收到真实视频帧"
    fi
    print -u2 "[device] 连接诊断：$UI_ACTION_LOG"
    exit 1
fi
print "[device] 已确认非零编码帧和接收 FPS，正式开始 $DURATION_SECONDS 秒采样"

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
MEASURED_SECONDS=0
MEASUREMENT_COMPLETED=1
while (( MEASURED_SECONDS < DURATION_SECONDS )); do
    if ! kill -0 "$HOST_PID" >/dev/null 2>&1; then
        MEASUREMENT_COMPLETED=0
        break
    fi
    SAMPLE_INTERVAL=10
    REMAINING_SECONDS=$((DURATION_SECONDS - MEASURED_SECONDS))
    if (( REMAINING_SECONDS < SAMPLE_INTERVAL )); then
        SAMPLE_INTERVAL=$REMAINING_SECONDS
    fi
    sleep "$SAMPLE_INTERVAL"
    MEASURED_SECONDS=$((MEASURED_SECONDS + SAMPLE_INTERVAL))
    SAMPLE_INDEX=$((SAMPLE_INDEX + 1))
    if (( SAMPLE_INDEX % 3 == 0 )); then
        {
            print "sample=$SAMPLE_INDEX"
            "${HDC_COMMAND[@]}" shell top -b -n 1
        } >> "$EVIDENCE_DIRECTORY/top.txt" 2>&1 || true
    fi
done

if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" >/dev/null 2>&1; then
    kill -TERM "$HOST_PID" >/dev/null 2>&1 || true
fi
set +e
wait "$HOST_PID"
HOST_STATUS=$?
set -e
HOST_PID=""
{
    print "connected_measurement_seconds=$MEASURED_SECONDS"
    print "measurement_completed=$MEASUREMENT_COMPLETED"
    print "host_exit_status=$HOST_STATUS"
} >> "$EVIDENCE_DIRECTORY/metadata.txt"

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
    --metadata "$EVIDENCE_DIRECTORY/metadata.txt" \
    --json-output "$EVIDENCE_DIRECTORY/metrics.json" \
    --summary-output "$EVIDENCE_DIRECTORY/summary.md"
ANALYZER_STATUS=$?
set -e

print "[device] 证据目录：$EVIDENCE_DIRECTORY"
if [[ "$INSTALL_CURRENT_HAP" != "1" ]]; then
    print -u2 "DEVICE_VALIDATION_INCOMPLETE: --no-install 结果不能用于源码改动验收"
    exit 2
fi
if [[ "$MEASUREMENT_COMPLETED" != "1" ]]; then
    print -u2 "NET_CONNECTION_LOST: 主机在完成连接后的采样时长前退出"
    exit 1
fi
exit "$ANALYZER_STATUS"
