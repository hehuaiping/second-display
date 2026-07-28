# Second Display 验收矩阵

## 1. 当前设备基线与门槛

默认发行路径为系统协商分辨率、H.264 硬编、60 FPS。当前主要验证设备为 Mate 60 Pro，
但脚本不把设备序列号写死；更换设备时必须在报告中记录型号、系统版本和物理刷新率。

### 120 秒真机非回归门禁

以下指标依据当前已验证基线和
`docs/HARMONYOS_NATIVE_LIKE_FLUIDITY_FINAL_REPORT.md`。前两个 10 秒主机指标样本作为固定
预热窗口，之后所有样本都参与计算。

| 指标 | 强制门槛 | 原因 |
|---|---:|---|
| RenderService 实际显示 FPS | ≥ 58.5 | 60 FPS 发行门槛 |
| RenderService 帧间隔 P95 | ≤ 25 ms | 防止平均 FPS 掩盖节奏抖动 |
| RenderService 帧间隔 P99 | ≤ 33.3 ms | 不允许持续两帧以上卡顿 |
| 主机 source FPS 中位数 | ≥ 58.0 | 确认压力源没有先失速 |
| ScreenCaptureKit FPS 中位数 | ≥ 57.0 | 允许短暂系统调度波动 |
| 编码发送 FPS 中位数 | ≥ 57.0 | 防止编码队列持续掉帧 |
| 接收有效呈现 FPS 中位数 | ≥ 58.5 | 使用接收提交与显示回调的较小值 |
| XComponent 显示回调 FPS 中位数 | ≥ 58.5 | 证明显示调度保持 60 Hz |
| VideoToolbox P95 最大稳定样本 | ≤ 9.5 ms | 当前 2720×1260 基线保护 |
| 解码输出 P95 最大稳定样本 | ≤ 25 ms | 防止解码/Surface 尾延迟恶化 |
| 发送 P95 最大稳定样本 | ≤ 1 ms | 局域网发送队列不应成为瓶颈 |
| 总主机丢帧率 | < 0.5% | 捕获、编码、发送累计值 |
| 发送丢帧 | 0 | 正常 LAN 不允许发送背压丢帧 |
| 连接 | 无不可恢复错误 | 结束后可再次连接 |

VideoToolbox 的“接近原生”目标仍为 ≤8 ms，click-to-photon P95 目标仍为 ≤60 ms。
当前脚本把 9.5 ms 作为已实现版本的硬性非回归线，并把 8 ms 作为未达到时必须报告的
目标差距。click-to-photon 必须用 240 FPS 以上高速摄像机或后续专用 probe 验收，不能
拿 RenderService pair delta 冒充。

### 90/120 FPS 试验门槛

| 指标 | 90 FPS | 120 FPS |
|---|---:|---:|
| 实际显示 FPS | ≥87 | ≥116 |
| 帧间隔 P95 | ≤17 ms | ≤12.5 ms |
| 帧间隔 P99 | ≤22 ms | ≤16.7 ms |
| 编码 P95 | ≤6 ms | ≤4 ms |
| click-to-photon P95 | ≤45 ms | ≤35 ms |
| 总丢帧率 | <1% | <1% |

除非设备 `activeMode` 已切到对应刷新率且所有门槛均满足，否则不得把 90/120 FPS 设为
默认能力。全分辨率 90 FPS 已被真机数据证明为负收益；首轮只能在 0.8 分辨率试验。

## 2. 每次运行的真机用例

### D0：120 秒全屏动态门禁

适用于每个会影响可执行产物的改动。

1. 构建并安装当前 signed debug HAP，不复用未知旧包。
2. 启动 `P3PoCHost` 的 100% dirty 动画，使用系统协商分辨率和 60 FPS。
3. 完成发现、配对、连接，连续运行至少 120 秒。
4. 采集主机阶段指标、RenderService FPS、Surface、screen、top 和应用包信息。
5. 自动分析必须通过上表全部强制门槛。
6. Host 正常结束后再次启动服务，App 必须能回到可连接状态并重新连接。

### D1：180 秒交互门禁

适用于媒体体验、输入、手势、光标、窗口或页面生命周期改动。使用
`--scenario interaction`，在真实桌面内容上依次执行：

- [ ] 快速鼠标水平/垂直往返 30 秒，光标和画面无明显渐进滞后；
- [ ] 连续拖动窗口 30 秒，无周期性冻结、撕裂恶化或旧画面积压；
- [ ] 连续键盘输入与文本滚动 30 秒，无按键丢失、重复或画面长暂停；
- [ ] 单指指针、点击、双击、长按、双指滚动/缩放符合映射；
- [ ] 三/四/五指上下、左右及收放手势各执行两次，无错误串扰；
- [ ] 横屏转竖屏再转横屏，控制界面可用且不会永久停在“连接中”；
- [ ] 后台 10 秒再前台，连接恢复或明确回到可重连状态；
- [ ] 停止并重启 Host，App 能发现并重新连接。

任何一项未实际执行或结果含糊，交互门禁状态都是 `INCOMPLETE`。

### D2：5 分钟长稳门禁

适用于捕获、编码、传输、解码、显示、输入、生命周期、恢复和发布候选。

- 运行 300 秒全屏动态负载；
- 每 30 秒保留设备 CPU/RES 和显示数据；
- 预热后 FPS/延迟门槛持续通过；
- RSS 不持续单调增长，不发生 OOM、解码器不可恢复错误或 Surface 缓冲继续增长；
- 不出现渐进式延迟；
- 中途执行一次横竖屏切换、一次后台/前台和一次 Wi-Fi 断开/恢复；
- 最后停止并重启 Host，验证下一 generation 能重新连接，旧回调不能复活。

## 3. 自动化命令

基础门禁：

```sh
.agents/skills/second-display-validation/scripts/run_automated_checks.sh
```

它等价于按顺序执行：

```sh
python3 tools/validate_shared_vectors.py
python3 -m unittest discover \
  -s .agents/skills/second-display-validation/tests -p 'test_*.py'
swift test -c debug
swift build -c release --product P3PoCHost
cmake -S harmony/entry/src/main/cpp -B .build/harmony-host \
  -DBUILD_PROTOCOL_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build .build/harmony-host --parallel
ctest --test-dir .build/harmony-host --output-on-failure
cd harmony
hvigorw assembleHap --mode module \
  -p product=default -p module=entry@default -p buildMode=debug --no-daemon
git diff --check
```

发布候选还需：

```sh
.agents/skills/second-display-validation/scripts/run_automated_checks.sh --release
INSTALL_LOCAL_PAIRING_IDENTITY=0 tools/package_macos_dmg.sh
tools/verify_macos_distribution.sh <实际 DMG 路径>
```

## 4. 证据与结论

真机脚本将证据写入 `.build/validation/<UTC timestamp>/`，至少包含：

- `metadata.txt`
- `host.log`
- `render-service-fps.txt`
- `render-service-surface.txt`
- `screen.txt`
- `top.txt`
- `bundle-info.txt`
- `metrics.json`
- `summary.md`
- `operator-checklist.md`

验收汇报不得只写“真机通过”。必须引用证据目录并列出实际指标。脚本退出 0 仅代表可自动
判定的指标通过；D1/D2 的人工项目未勾选时仍不能完成验收。

## 5. HarmonyOS 命令依据

- [AA 工具：显式启动 UIAbility 与 force-stop](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/aa-tool)
- [BM 工具：覆盖安装 HAP](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/bm-tool)

当前本机 HDC 3.2.0d 的 `hdc help` 同时确认了 `-t connectkey`、`list targets` 和
`install -r <hap>` 客户端便捷命令。真机脚本使用这些命令，并把实际 HDC 版本写入证据，
以便工具升级后追溯行为差异。
