# HarmonyOS 端接近原生扩展屏的流畅度最终分析报告

> 数据采集日期：2026-07-28
>
> 仓库基线：`b61fb7295a312b0d715290894641a36161627095`（V1.1.0）
>
> 测试工具：`P3PoCHost` 动画压力源、HDC、RenderService `hidumper`、设备 `top`、ICMP

## 1. 最终结论

当前链路已经具备良好的低延迟基础：macOS 使用硬件 H.264、VideoToolbox 低延迟码控，
发送队列基本为零，HarmonyOS 使用 AVCodec Surface 模式直接输出到 XComponent。
剩余体验与原生扩展屏的差距，主要不在 Annex B 打包或局域网吞吐，而在 **HarmonyOS
解码输出之后的显示排队和错误的反馈闭环**。

按实测收益排序，当前主要瓶颈是：

1. **P0：Surface/RenderService 排队。** 设备为 XComponent 分配了 21 个
   `2720×1260` 缓冲区，约 109 MB；实测 RenderService 两列时间戳差值 P95 在
   39.7～118.9 ms 之间波动，相当于约 2～7 个 60 Hz 帧周期。
2. **P0：反馈的“渲染 FPS”并非真实上屏 FPS。** 当前代码在
   `OH_VideoDecoder_RenderOutputBuffer` 返回成功时立即增加 `renderedFrames`，
   随后把它作为接收端 FPS 回传。该值只表示“提交给 Surface”，不表示 RenderService
   或面板已经显示。90 FPS 测试中发送端因此认为接收端正常，实际面板仍为 60 Hz，
   RenderService 只观测到约 45 FPS。
3. **P0：应用没有请求与码流匹配的物理刷新率。** Mate 60 Pro 支持
   60/90/120 Hz，但整个测试期间 `activeMode` 一直是 60 Hz，
   `expectedRefreshRate=-1`。当前源码没有调用
   `OH_NativeXComponent_SetExpectedFrameRateRange`，也没有注册真实可用的
   XComponent 帧回调。工作区中的 `LatencyWindow.hpp` 尚未接入编译和解码链路。
4. **P1：全分辨率 90 FPS 没有吞吐余量。** 2720×1260 H.264 的 VideoToolbox
   编码 P95 为 8.5～9.6 ms。它可以支持 60 FPS，但对 90 FPS 的 11.11 ms 总帧预算
   只剩约 1.5～2.6 ms 给采集、调度、发送、解码和呈现。90 FPS 压测最终只编码
   5616 帧并产生 4489 个主机侧丢帧，实际呈现约 45 FPS。
5. **P1：Wi-Fi RTT 和 TLS/TCP 队头阻塞仍会放大尾延迟。** 满负载时 RTT
   平均 18.37 ms、最大 74.62 ms。发送队列为零，说明带宽不是主瓶颈；但 TCP
   丢包重传和 ArkTS 回调批量交付会直接增加旧帧年龄。
6. **P2：接收输入仍有多次内存拷贝，但不是当前第一收益点。** 解码输出已经是
   Direct Surface Rendering；网络输入仍经过 ArkTS `ArrayBuffer`、C++ 解析缓冲、
   `VideoFrame.payload`，最后 `memcpy` 到 AVCodec 的 `OH_AVBuffer`。公开 API
   没有把任意 TLS 网络缓冲直接作为 AVCodec 输入缓冲的能力，因此不能实现严格意义上的
   “全链路零拷贝”。

在修复 P0 显示排队和真实反馈前，不应默认开启 90/120 FPS。当前最现实的近期目标是：

- 60 FPS 实际呈现达到 58.5 FPS 以上；
- Surface 排队 P95 控制在 25 ms 内；
- 交互到画面反馈 P95 控制在 50～60 ms；
- 鼠标快速移动、窗口拖动连续 30 分钟不发生渐进式延迟。

达到这些指标后，主观体验会明显接近有线原生扩展屏。90 FPS 应先结合 0.8 倍分辨率试验；
120 FPS 在编码 P95 降到 4 ms 左右以前没有实际收益。

## 2. 测试环境与方法

### 2.1 设备

| 项目 | 实测配置 |
|---|---|
| macOS 主机 | MacBook Pro `Mac17,8`，Apple M5 Pro 18 核，48 GB |
| macOS | 26.5.2，Build 25F84 |
| HarmonyOS 真机 | HUAWEI Mate 60 Pro，ALN-AL00 |
| HarmonyOS | 6.1.0.135 |
| HarmonyOS App | 1.1.0，`versionCode=1001000`，Debug Profile |
| 真机横屏分辨率 | 2720×1260 |
| 面板能力 | 60/90/120 Hz |
| 网络 | 5 GHz 802.11ac，20 MHz，协商速率约 173 Mbps |
| 视频 | H.264、硬件编码、VideoToolbox LL、100% dirty 动画 |

测试使用 `P3_POC_ANIMATED_TEST_PATTERN=1`，每帧改变背景、移动色条并更新帧号，属于比
鼠标移动和普通窗口拖动更严格的全屏变化压力场景。分别运行：

```bash
P3_POC_DURATION_SECONDS=150 P3_POC_MAX_FPS=60 \
P3_POC_ANIMATED_TEST_PATTERN=1 \
P3_POC_TLS_DIRECTORY=.build/p3-poc-tls .build/release/P3PoCHost

P3_POC_DURATION_SECONDS=120 P3_POC_MAX_FPS=90 \
P3_POC_ANIMATED_TEST_PATTERN=1 \
P3_POC_TLS_DIRECTORY=.build/p3-poc-tls .build/release/P3PoCHost
```

RenderService 数据来自：

```bash
hdc shell hidumper -s RenderService -a "secondDisplaySurfaceSurface fps"
hdc shell hidumper -s RenderService -a surface
hdc shell hidumper -s RenderService -a screen
hdc shell top -b -n 1
```

`fps` 输出的两列时间戳差值在本报告中称为 **RS pair delta**。它能反映 Surface
生产到 RenderService 处理之间的排队变化，但不是官方定义的 click-to-photon 指标，
因此只用于瓶颈定位，不能代替高速摄像机或带帧标记的端到端测量。

## 3. 真机压力测试结果

### 3.1 汇总

| 场景 | 主机编码/发送 | 真机实际显示 | 关键现象 |
|---|---|---|---|
| 60 FPS，稳态前段 | VT P95 8.3～9.2 ms；send P95 0 ms；发送丢帧 0 | 60.03 FPS；帧间隔 P95 25.97 ms、P99 35.24 ms | 平均帧率接近 60，但帧节奏不均，RS pair delta P50/P95 105.1/118.9 ms |
| 60 FPS，持续负载 | VT P95 9.1～9.6 ms；发送队列仍为 0 | 49.33 FPS；帧间隔 P95 36.41 ms、P99 44.46 ms | RS pair delta P50/P95 35.84/48.65 ms，出现明显掉帧 |
| 90 FPS，全分辨率 | VT P95 8.5～8.9 ms；编码 5616；主机丢帧 4489 | 44.99 FPS；面板仍为 60 Hz | 帧间隔 P95 37.68 ms；90 FPS 实际比稳定 60 FPS 更差 |

90 FPS 时，系统明确报告：

```text
activeMode: 1260x2720, refreshRate=60
expectedRefreshRate=-1
```

这说明码流帧率、XComponent 调度和物理面板刷新率没有形成闭环。

### 3.2 Surface 缓冲

三轮测试中 Surface 缓冲池保持：

```text
FIFO = 21
usedBufferListLen = 21
freeBufferListLen = 0
totalBuffersMemSize = 109368 KiB
```

缓冲数量没有继续增长，因此短时间内没有发现内存泄漏；但 21 帧容量远高于交互桌面所需，
它允许 AVCodec/Surface 在压力下保存大量旧画面。即使应用自己的
`DecoderFrameQueue` 只有两帧，解码后的画面仍能在不可见的 Surface 队列中积压。

### 3.3 CPU、内存和网络

60 FPS 满负载期间，单次采样范围如下：

| 进程 | CPU |
|---|---:|
| `cloud.cuihua.display` | 29.6%～51.8% |
| `av_codec_service` | 25.9%～48.1% |
| `render_service` | 29.6%～40.7% |

设备总计以 1200% 表示 12 核满载，因此上述 CPU 并未触顶。App RES 为
186～198 MB，其中 XComponent Surface 缓冲约占 109 MB。CPU 不是当前硬上限，
但减少缓冲和输入拷贝仍会改善功耗及长时间稳定性。

满负载 ICMP 数据：

```text
300 packets transmitted, 300 received, 0% loss
RTT min/avg/max/stddev = 9.286/18.373/74.618/4.968 ms
```

12 Mbps 左右视频流远低于 173 Mbps 链路能力，且主机 send P95 为 0 ms、发送队列为零。
因此“增加码率”不能解决跟手问题；当前网络风险主要是 RTT 尾部和 TCP 重传造成的旧帧阻塞。

### 3.4 压测附带发现

`P3PoCHost` 主动结束后，HarmonyOS App 多次停留在“正在连接 Mac”，不能自动进入下一次
服务连接，强制停止并重启 Ability 后恢复。该问题不影响本轮流畅度结论，但应作为长时间
运行和网络恢复测试的一部分修复。

## 4. 现有实现的关键问题

### 4.1 “已渲染”实际只是“已提交”

[`H264SurfaceDecoder.cpp`](../harmony/entry/src/main/cpp/decoder/H264SurfaceDecoder.cpp)
在输出回调中调用 `OH_VideoDecoder_RenderOutputBuffer`，成功后立即执行
`renderedFrames_ += 1`。随后
[`Index.ets`](../harmony/entry/src/main/ets/pages/Index.ets) 根据该计数计算
`realTimeFps` 并作为 `receiverFeedback.renderedFramesPerSecond` 发回主机。

这会产生以下错误闭环：

```text
AVCodec 输出 90 帧/秒
        ↓
应用报告“渲染 90 FPS”
        ↓
主机认为接收端健康，不降档
        ↓
物理面板仍为 60 Hz，Surface/RS 只能显示约 45～60 FPS
        ↓
旧画面继续排队，用户感知延迟增加
```

### 4.2 120 ms 过期阈值过宽

当前 `kMaximumOutputAgeUs = 120000`。在 60 Hz 下相当于 7.2 帧，在 90 Hz 下相当于
10.8 帧。只有输出超过 120 ms 且后方已有新帧时才释放，无法阻止 2～6 帧的常见排队。
交互桌面应按帧周期动态控制，而不是使用固定 120 ms 播放型阈值。

### 4.3 解码器和 Surface 缓冲数量未限制

当前只设置 `OH_MD_KEY_MAX_INPUT_SIZE`，没有设置 SDK 已公开的：

- `OH_MD_MAX_INPUT_BUFFER_COUNT`
- `OH_MD_MAX_OUTPUT_BUFFER_COUNT`

同时应用层允许最多 5 个 `submittedFrames_` 在解码器内飞行。应用入口队列虽为 2，
但“入口 2 + 解码器 in-flight 5 + Surface 21”仍能产生较深流水线。

### 4.4 ArkTS/TLS 输入存在多份数据

[`ReceiverWorker.ets`](../harmony/entry/src/main/ets/workers/ReceiverWorker.ets) 在
TLSSocket `message` 回调中同步进入 NAPI；[`FrameParser.cpp`](../harmony/entry/src/main/cpp/transport/FrameParser.cpp)
把网络分片追加到 `std::vector`，再为每帧执行 `payload.assign`；解码器最终还要
`memcpy` 到系统提供的 `OH_AVBuffer`。这些拷贝增加 CPU 和调度抖动，但实测显示它们的
收益优先级低于显示排队。

### 4.5 原始 macOS 光标受完整视频链路限制

当前为了保留原始光标外观，光标被合成进视频帧。鼠标移动到屏幕反馈必然经过：

```text
HarmonyOS 输入 → Wi-Fi/TLS 控制通道 → macOS 注入
→ 下一次屏幕采集 → 编码 → Wi-Fi/TLS 视频通道
→ 解码 → Surface → VSync
```

在不采用光标侧信道的前提下，即使其他步骤都优化完，光标仍至少承受一个采集周期和一个
显示周期。若最终目标要求与本机触控板同级的指针跟手感，需要重新设计“原始 macOS 光标
形状 + hotspot + 位置”的客户端硬件光标侧信道，而不是之前的替代样式光标。

## 5. 推荐优化路线

## 5.1 P0：先消除接收端显示排队

### P0-1：建立真实显示反馈

在 XComponent 创建时：

1. 调用 `OH_NativeXComponent_SetExpectedFrameRateRange`，将 `min/max/expected`
   设为当前协商帧率；
2. 注册 `OH_NativeXComponent_RegisterOnFrameCallback`，记录回调的
   `timestamp/targetTimestamp`、实际显示调度 FPS 和 P95 间隔；
3. Surface 销毁或 generation 变化时必须注销回调；
4. `receiverFeedback` 新增可选字段：
   `displayCallbackFps`、`displayIntervalP95Us`、`decodeOutputP95Us`；
5. 主机使用 `min(decoderSubmitFps, displayCallbackFps)` 参与升降档，不能继续把
   `RenderOutputBuffer` 调用次数视为上屏 FPS。

XComponent 帧回调仍不是逐视频帧 present 回执，但足以识别“码流 90、面板 60”的错误状态。
后续再用端到端帧标记校准真实显示时间。

### P0-2：限制 AVCodec 缓冲与 in-flight

第一组 A/B 参数建议：

```text
OH_MD_MAX_INPUT_BUFFER_COUNT  = 3
OH_MD_MAX_OUTPUT_BUFFER_COUNT = 3
kMaximumInFlightFrames        = 2
DecoderFrameQueue capacity    = 1 或 2
```

厂商解码器拒绝可选参数时，按现有低延迟能力回退模式重建，不得中断兼容路径。验收时通过
RenderService 确认 FIFO/dirty buffer 显著下降，并检查 30 分钟内没有 decoder starvation。

### P0-3：使用“最新帧优先”的 Surface 提交策略

官方 `OH_VideoDecoder_RenderOutputBufferAtTime` 说明：多个缓冲在同一 VSync 提交时，
Surface 会显示最后一个并丢弃其余缓冲。建议 A/B 测试：

- 对准备显示的最新输出，以当前单调时钟纳秒调用
  `OH_VideoDecoder_RenderOutputBufferAtTime`；
- 同一批输出中较旧的缓冲调用 `OH_VideoDecoder_FreeOutputBuffer`；
- 动态过期阈值改为 `1.25 × framePeriod`，即约 20.8 ms@60、13.9 ms@90；
- 只丢解码完成后的 Surface 输出，不跳过 H.264 参考帧解码，避免破坏参考链；
- 若定时呈现 API 返回不支持，立即回退现有 `RenderOutputBuffer`。

这一项预计是当前单项收益最高的优化，有机会直接减少 30～100 ms 显示排队。

### P0-4：高刷新率必须由实测能力门控

只有同时满足以下条件才从 60 升到 90：

- 物理/XComponent 实际回调 FPS ≥ 当前档位的 97%；
- 编码 P95 ≤ 下一档帧预算的 55%；
- 解码输出 P95 ≤ 下一档帧预算的 45%；
- Surface 排队 P95 ≤ 1.5 个下一档帧周期；
- 最近 10 秒无持续丢帧、无热限制、RTT P95 < 30 ms。

按当前编码 P95 8.5～9.6 ms，2720×1260 不满足 90 FPS 的建议门槛。90 FPS 首轮应使用
2176×1008 左右的 0.8 分辨率，仍由 XComponent 全屏缩放显示。

## 5.2 P1：降低网络尾延迟和输入拷贝

1. 控制通道继续使用 TLS/TCP，保持输入、心跳和恢复消息可靠；
2. 视频通道评估已存在的 QUIC Datagram 发送实现，补齐 HarmonyOS 接收端；
3. 视频分片必须带 frame/fragment sequence、deadline 和有限重传，过期帧不重传；
4. 丢失 P 帧后等待最新 IDR；Datagram 模式应恢复有限 GOP 或周期 IDR，不能依赖无限 GOP；
5. 若继续使用 TLS/TCP，限制接收缓冲并记录每次 `message` 批次大小、最老帧年龄和
   TCP RTT P95，防止把批量到达误判为解码背压；
6. 将 C++ FrameParser 改成固定环形缓冲，并在 AVCodec 输入缓冲可用时直接完成唯一一次
   payload copy，删除 `payload.assign` 中间副本。

这组改造预计主要改善 P95/P99 和弱 Wi-Fi 场景，平均延迟收益小于 P0。

## 5.3 P1：主机编码与分辨率策略

- 60 FPS 全分辨率继续使用 H.264；当前 HEVC 不应作为默认低延迟路径；
- 高动态场景按编码 P95 和真实显示 FPS，优先在 1.0/0.8/0.667 分辨率间调整；
- 90 FPS 先在 0.8 分辨率验证，编码 P95 目标 < 6 ms；
- 120 FPS 只有在编码 P95 < 4 ms、解码和显示都能稳定 120 Hz 时才试验；
- 将编码/采集指标改成最近 5～10 秒窗口，避免 4096 样本历史 P95 掩盖近期退化；
- 给 `P3AnimatedTestPattern` 增加实际产生/采集/编码 FPS 三个独立计数，避免仅凭目标 FPS
  推断采集吞吐。

## 5.4 P2：真正的输入到光子测量

现有指标无法直接回答“点击后多少毫秒看到结果”。建议增加专用 probe：

1. HarmonyOS 发送带 sequence 和单调时间戳的测试输入；
2. macOS 收到后立即改变 P3 测试图案中的高对比色块，并记录注入时间；
3. 视频帧携带 capture timestamp 和 probe sequence；
4. HarmonyOS 记录解码输出、Surface 提交和最近 XComponent frame callback；
5. 通过 heartbeat 多样本估算两端时钟偏移；
6. 最终输出 input→host、host→capture、encode、network、decode、surface→display 的
   P50/P95/P99。

正式验收仍应使用 240 FPS 以上高速摄像机，拍摄手指/鼠标动作和手机画面，校准软件估算。

## 6. 零拷贝可行性判断

| 链路 | 当前状态 | 是否可做到公开 API 零拷贝 |
|---|---|---|
| ScreenCaptureKit IOSurface → VideoToolbox | CVPixelBuffer/IOSurface 直送 | 是，当前基本达到 |
| VideoToolbox → Annex B/TLS | 仍有码流整理和网络栈拷贝 | 不能完全消除 |
| HarmonyOS TLSSocket → ArkTS/NAPI | ArrayBuffer 跨层 | 当前架构不能 |
| C++ parser → AVCodec input | `payload.assign` + `memcpy` | 可优化为一次 copy，不能归零 |
| AVCodec output → XComponent Surface | `SetSurface` + `RenderOutputBuffer` | 是，当前已经达到 |
| Surface → RenderService/面板 | 系统合成 | 应减少排队，应用不能绕过 |

因此，不建议把“全链路零拷贝”作为下一阶段 KPI。更准确的目标是：

> 保持捕获和解码输出零拷贝，把接收输入压缩为一次有界 copy，并确保任何时刻最多只有
> 1～2 帧等待显示。

这比继续追求无法通过公开 API 实现的绝对零拷贝更能改善实际体验。

## 7. 分阶段验收标准

| 指标 | 60 FPS 发行门槛 | 90 FPS 试验门槛 | 120 FPS 研究门槛 |
|---|---:|---:|---:|
| 实际显示 FPS | ≥ 58.5 | ≥ 87 | ≥ 116 |
| 帧间隔 P95 | ≤ 25 ms | ≤ 17 ms | ≤ 12.5 ms |
| 帧间隔 P99 | ≤ 33.3 ms | ≤ 22 ms | ≤ 16.7 ms |
| Surface 排队 P95 | ≤ 25 ms | ≤ 16.7 ms | ≤ 12.5 ms |
| 编码 P95 | ≤ 8 ms | ≤ 6 ms | ≤ 4 ms |
| click-to-photon P95 | ≤ 60 ms | ≤ 45 ms | ≤ 35 ms |
| 总丢帧率 | < 0.5% | < 1% | < 1% |
| 解码/Surface 缓冲 | ≤ 4 | ≤ 4 | ≤ 4 |
| 长时间运行 | 30 分钟无渐进延迟 | 15 分钟稳定 | 仅实验 |

验收场景必须至少包括：

- 全屏 100% dirty 动画；
- 高速鼠标往返和连续拖动窗口；
- 持续键盘输入与文本滚动；
- 20% 局部变化和长时间静止；
- Wi-Fi RTT 10/30/60 ms、短时抖动和一次断网恢复；
- 横竖屏切换、后台前台切换和重复连接。

## 8. 建议实施顺序

1. **真实显示 FPS + XComponent 刷新率请求**；
2. **AVCodec 输入/输出缓冲上限 + in-flight 降到 2**；
3. **`RenderOutputBufferAtTime(now)` 和按帧周期丢弃旧输出的 A/B 测试**；
4. **用真实显示指标重写 60/90/120 升降档门控**；
5. **补齐 click-to-photon probe，重新跑 60 FPS 30 分钟回归**；
6. **0.8 分辨率试验 90 FPS**；
7. **最后再做 C++ 单拷贝接收与 QUIC Datagram 视频通道**。

## 9. 官方能力依据

- [OH_VideoDecoder C API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/capi-native-avcodec-videodecoder-h)：
  Surface 输出、立即呈现和 `RenderOutputBufferAtTime` 行为。
- [Native XComponent C API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/capi-native-interface-xcomponent-h)：
  期望帧率范围与 frame callback。
- [HarmonyOS 调试命令](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/debugging-commands)：
  HDC、hidumper、hitrace、hiperf 等真机性能工具。
- 本机 HarmonyOS 6 SDK `native_avcodec_base.h`：
  `OH_MD_MAX_INPUT_BUFFER_COUNT`、`OH_MD_MAX_OUTPUT_BUFFER_COUNT`。

## 10. 2026-07-28 第一轮实施与真机 A/B 结果

### 10.1 已落地

- XComponent 注册帧回调并请求协商帧率，记录显示调度 FPS 和帧间隔 P95；
- HarmonyOS 解码器记录最近 256 个解码输出延迟并上报 P95；
- `receiverFeedback` 以可选字段新增显示 FPS、显示间隔 P95、解码输出 P95，旧客户端和
  旧主机仍可正常解码；
- macOS 使用 `min(解码提交 FPS, XComponent 回调 FPS)` 作为接收端有效呈现能力，
  升档同时检查显示间隔与解码尾延迟；
- 固定 120 ms 输出过期门改为按帧周期计算的 `1.25 × framePeriod`，但只有后方至少
  积压两帧时才释放旧输出，避免轻微延迟导致解码器饥饿；
- ScreenCaptureKit 回调队列年龄继续严格限制为两帧；系统 `displayTime` 到回调的交付
  年龄单独限制为三帧，避免将系统固定合成延迟误判为应用排队。

### 10.2 被真机数据否决的参数

以下两项虽然公开 API 返回成功，但在 Mate 60 Pro 上属于负收益，发行路径没有启用：

1. `MAX_INPUT/OUTPUT_BUFFER_COUNT=3` 配合 2～3 帧 in-flight：
   解码提交下降到约 30～40 FPS，RenderService Surface FIFO 仍为 21，并未真正缩小；
2. `RenderOutputBufferAtTime(now)`：
   RenderService 时间戳大量呈现约 33 ms 间隔，说明经常错过下一次 VSync，不能替代
   当前的立即 Surface 呈现。

因此最终保留硬件已验证的 5 帧 in-flight 和 `RenderOutputBuffer`，入口队列仍为两帧
 latest-wins。这里的取舍是用最小必要的硬件流水线深度维持吞吐，而不是把“参数设置成功”
当作缓冲确实缩小。

### 10.3 最终 60 FPS 压力结果

测试命令：

```bash
P3_POC_DURATION_SECONDS=90 P3_POC_MAX_FPS=60 \
P3_POC_ANIMATED_TEST_PATTERN=1 \
P3_POC_TLS_DIRECTORY=.build/p3-poc-tls .build/release/P3PoCHost
```

同一设备、同一 2720×1260 全屏 100% dirty 动画中：

| 指标 | 拆分捕获年龄门前 | 最终版本 |
|---|---:|---:|
| 末段主机 C/E/S 丢帧 | `5/1223/0` | `6/1/0` |
| 接收端提交 FPS | 约 26～35 | 约 53～60.4 |
| XComponent 回调 FPS | 60.4 | 60.4 |
| VideoToolbox P95 | 8.5～9.4 ms | 8.5～8.8 ms |
| 解码输出 P95 | 13.2～26.5 ms | 14.2～23.4 ms |
| 发送 P95 | 0 ms | 0 ms |

结果说明本轮最大的稳定性收益来自正确区分 ScreenCaptureKit 系统交付延迟与应用内部
排队：此前运行一段时间后会把约一半输入误判为过期；修正后 90 秒内没有出现渐进式掉帧。

仍未解决的系统边界：

- RenderService 仍报告 `FIFO=21`，公开的 AVCodec buffer-count 参数在该设备上无法将其缩小；
- `SetExpectedFrameRateRange` 返回成功，但 `hidumper screen` 仍显示
  `expectedRefreshRate=-1`、物理活动模式 60 Hz；
- 全分辨率编码 P95 仍高于 90 FPS 门槛 6 ms，因而没有强制进行 90 FPS 回归。90 FPS
  应在 0.8 分辨率、物理显示确实切到 90 Hz 且上述门槛全部满足后再开启。

## 11. 2026-07-28 P1 主机媒体压力与近期窗口优化

### 11.1 实现内容

- 延迟直方图默认容量由 4096 改为 600 个样本，对应 60 FPS 下约 10 秒、120 FPS 下
  约 5 秒；总编码帧数独立累计，不再被滑动窗口容量截断；
- `P3AnimatedTestPattern`、采集管线和发送计数器分别输出实际
  `src/cap/enc FPS`，不再用目标帧率推测瓶颈位置；
- 网络自适应样本新增主机丢帧增量、发送 FPS、编码 P95 和内容活跃度；
- 活动内容连续出现主机媒体压力时，沿 `1.0 → 0.8 → 0.667` 降分辨率；
- 码率恢复维持 8 个健康采样，分辨率恢复延长到 20 个健康采样，并要求码率已经恢复，
  防止频繁重建和画质档位振荡；
- 静止桌面、ScreenCaptureKit idle 不会触发媒体降级；
- 接收端主动 latest-wins 释放旧 Surface 输出时，如果有效呈现 FPS 达标且两端队列为空，
  不再将该计数误判为网络丢包并降低画质；
- 新 generation 启动时以当前累计丢帧数作为基线，旧会话统计不会触发新会话降级。

### 11.2 最终真机结果

55 秒、2720×1260、60 FPS、100% dirty 动画最终回归：

| 指标 | 实测 |
|---|---:|
| 源图案 FPS | 59.3～60.4 |
| ScreenCaptureKit FPS | 56.0～60.3，随后恢复 60 |
| 编码发送 FPS | 56.0～60.4，随后恢复 60 |
| HarmonyOS 有效呈现 FPS | 54.8～59.9 |
| XComponent 回调 FPS | 59.9～60.4 |
| 主机 C/E/S 丢帧 | `6/3/0` |
| VideoToolbox P95 | 8.4～8.8 ms |
| 解码输出 P95 | 13.8～22.9 ms |
| 发送 P95 | 0 ms |

稳定全分辨率场景没有误触发分辨率重建。码率起始保持 12 Mbps；接收端实际呈现短时下降到
约 55 FPS 后才按滞回降到 9.6 Mbps，没有再因单纯的 stale-output 计数直接降至 8 Mbps。

媒体压力降到 0.8、静止内容不降级、20 秒后恢复分辨率均已通过确定性测试。由于本轮真实
压力源保持稳定，真机没有人为制造编码器故障来强制触发重建；该保护路径将在真实持续
掉帧时生效，高刷仍保持关闭。

## 12. 2026-07-28 原生分辨率优先策略

### 12.1 策略调整

对 2720×1260 接收端，原有 `0.8` 和 `0.667` 档位都会受到短边至少 1200 的 HiDPI
下限约束，实际都得到 2592×1200。像素量只减少约 9.2%，但非原生缩放会明显降低文字和
细线清晰度，而且分辨率变化需要重建流。因此发行路径现改为：

- `P3HostConfiguration.allowsAdaptiveResolution` 默认关闭；
- 默认会话固定从 `resolutionScale = 1.0` 开始，并清除同一进程中实验模式留下的档位；
- 网络和主机压力仍可调整码率，但不能触发分辨率流重建；
- 原有阶梯和测试保留，只有显式设置
  `P3_POC_ADAPTIVE_RESOLUTION=1` 时，P3PoCHost 才允许分辨率自适应实验；
- 新增持续严重压力下仍保持原生分辨率、且不返回流重建决策的确定性测试。

### 12.2 五分钟真机结果

设备为 Mate 60 Pro（ALN-AL00），OpenHarmony 6.1.1.120。当前 debug HAP 覆盖安装后，
使用 2720×1260、60 FPS、100% dirty 动画运行 300 秒，全程没有分辨率变化或 generation
重启。证据位于 `.build/validation/20260728T081831Z/`。

| 指标 | 实测 | 门槛 | 结果 |
|---|---:|---:|---|
| RenderService 实际 FPS | 60.07 | ≥58.5 | 通过 |
| 源/采集/编码 FPS 中位数 | 59.9/59.8/59.8 | ≥58/57/57 | 通过 |
| 接收有效呈现 FPS 中位数 | 59.8 | ≥58.5 | 通过 |
| 显示回调 FPS 中位数 | 60.4 | ≥58.5 | 通过 |
| VideoToolbox P95 最大稳定样本 | 9.4 ms | ≤9.5 ms | 通过 |
| 发送 P95/发送丢帧 | 0 ms/0 | ≤1 ms/0 | 通过 |
| 主机总丢帧率 | 0.045% | <0.5% | 通过 |
| RenderService 帧间隔 P95/P99 | 29.1/41.0 ms | ≤25/33.3 ms | 未通过 |
| 解码输出 P95 最大稳定样本 | 29.2 ms | ≤25 ms | 未通过 |

该结果说明锁定原生分辨率没有造成持续采集、编码或发送背压，能够避免画质降级和重建；
但当前版本仍不能通过完整流畅度门禁。剩余问题集中在 HarmonyOS 解码输出与 RenderService
尾部节奏，下一轮应针对 25～30 ms 的偶发尾延迟做有门控的输出策略 A/B，并继续推进接收
输入单拷贝和真实 input-to-photon probe，不应以恢复默认降分辨率来掩盖该问题。

## 13. 2026-07-28 HarmonyOS 接收端一次有界拷贝

### 13.1 实现

原接收热路径会先把 `FrameParser` 中的完整 H.264 payload 复制到每帧独立
`std::vector<uint8_t>`，随后再复制到 AVCodec 的 `OH_AVBuffer`，每帧至少发生两次
payload 拷贝。本轮改为：

- `FrameParser` 使用 `shared_ptr<vector<uint8_t>>` 作为有 16 MiB 单帧硬上限的接收存储；
- 完整帧只持有该存储的只读切片，不再执行 `payload.assign`；
- 解析器继续接收后续数据前，如果旧存储仍被已提交帧引用，只复制尚未形成完整帧的尾部，
  不修改旧存储，避免帧切片悬空或被重分配失效；
- 解码器检查 `OH_AVBuffer` 地址、容量和 `int32_t` 长度上限后，通过一次 `memcpy`
  将切片写入 AVCodec 输入缓冲；容量不足返回现有项目错误码，不强制解包或崩溃；
- 解码器入口队列仍为两帧 latest-wins，解析器单帧上限仍为 16 MiB，因而不会为减少拷贝
  引入无界队列；
- 新增粘包帧共享存储、切片内容复制、解析器继续复用后旧帧仍有效等确定性测试，保留原有
  5000 轮模糊测试。

曾试验在持有解析器互斥锁时逐帧提交解码器，真机约 20 秒后退化到约 30 FPS。该方案改变了
原有锁持有时间和批量提交时序，已被真机数据否决并完全移除。最终路径保持“锁内解析、
锁外提交”的原有顺序，仅改变 payload 的所有权和拷贝方式。

### 13.2 五分钟真机 A/B

自动化检查通过后，在 Mate 60 Pro（ALN-AL00）、OpenHarmony 6.1.1.120 上覆盖安装当前
debug HAP，使用 2720×1260、60 FPS、100% dirty 动画连续运行 300 秒。证据位于
`.build/validation/20260728T085046Z/`。

| 指标 | 上一轮原生分辨率基线 | 一次有界拷贝 | 门槛 | 结果 |
|---|---:|---:|---:|---|
| RenderService 实际 FPS | 60.07 | 59.04 | ≥58.5 | 通过 |
| RenderService 帧间隔 P95 | 29.1 ms | 25.49 ms | ≤25 ms | 未通过 |
| RenderService 帧间隔 P99 | 41.0 ms | 33.91 ms | ≤33.3 ms | 未通过 |
| 源/采集/编码 FPS 中位数 | 59.9/59.8/59.8 | 60.3/59.8/59.7 | ≥58/57/57 | 通过 |
| 接收有效呈现 FPS 中位数 | 59.8 | 58.9 | ≥58.5 | 通过 |
| 显示回调 FPS 中位数 | 60.4 | 60.4 | ≥58.5 | 通过 |
| VideoToolbox P95 最大稳定样本 | 9.4 ms | 8.7 ms | ≤9.5 ms | 通过 |
| 解码输出 P95 最大稳定样本 | 29.2 ms | 24.9 ms | ≤25 ms | 通过 |
| 发送 P95/发送丢帧 | 0 ms/0 | 0.1 ms/0 | ≤1 ms/0 | 通过 |
| 主机总丢帧率 | 0.045% | 0.051% | <0.5% | 通过 |

300 秒内编码 17687 帧，没有断流、分辨率重建、发送丢帧或持续降到 30 FPS。一次有界拷贝
使解码输出尾延迟回到硬门槛内，并显著改善 RenderService 尾部节奏；但完整自动门禁仍为
`FAIL`，因为 P95/P99 分别超出 0.49/0.61 ms，不能将本轮标记为最终流畅度验收通过。
人工交互、旋转、前后台、断网恢复清单也仍需独立执行。

下一轮不应恢复默认降分辨率或继续改变解析锁时序。优先补齐真实 input-to-photon probe，
并针对 RenderService 偶发跨 VSync 做小范围、可回退的呈现节奏 A/B；只有 P95/P99 连续
通过 5 分钟门禁后，才应继续 90/120 FPS 实验。
