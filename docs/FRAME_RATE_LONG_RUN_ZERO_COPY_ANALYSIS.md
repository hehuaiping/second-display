# 帧率、长时间流畅度与零拷贝优化分析

> 分析基线：`V1.0.1`（`b5483f8`）
> 分析日期：2026-07-25
> 范围：macOS 采集/编码/发送、HarmonyOS 接收/解码/显示，以及持续运行稳定性。协议仍保持 v1；第 9 节记录本轮 P0 优化实现与验证结果。

## 1. 结论摘要

当前版本仍有明确的优化空间，但重点已经不再是“把硬件编码/解码打开”，因为这些关键能力已经实现：

- macOS 已将 ScreenCaptureKit 返回的 `CVPixelBuffer` 直接提交给 VideoToolbox，业务代码没有锁定并读写像素基址，也没有执行 CPU 色彩转换。
- HarmonyOS 已使用硬件 AVCodec、低延迟能力探测和 Surface 输出，解码后的 YUV 不会回读到 CPU 再绘制。
- 采集、编码、发送和解码队列均有限长，并具备 generation 隔离、过期帧处理、IDR 恢复及动态码率/分辨率能力。

仍需处理的主要瓶颈是：

1. 压缩码流在 macOS 打包和 HarmonyOS 解析阶段存在多次整帧复制及高频内存分配。
2. macOS 指标统计每秒复制并排序多组样本，样本淘汰又使用数组头部删除，可能形成周期性 CPU/内存抖动。
3. 当前拥塞控制会调整码率和分辨率，但不会根据解码负载、温度或持续掉帧调整帧率。
4. 设计文档要求的编码器“无输出 watchdog”尚未在实际编码等待路径中落地；底层回调永久不返回时，编码任务可能一直等待。
5. 发行版 DMG 服务仍以 60 FPS 默认值启动。HarmonyOS 虽能上报 90/120 FPS 能力，现有发行应用不会自动启用高刷。
6. 设计目标包含 8 小时长稳测试，但现有状态记录不能证明发行组合已经持续满足该目标。

**全链路物理零拷贝不能直接实现，也不应作为对外承诺。** 当前可以实现的合理目标是：

- 保持两段“像素零拷贝岛”：`ScreenCaptureKit → VideoToolbox`、`AVCodec → Surface`；
- 将压缩码流热路径收敛为：macOS 最多一次业务层复制、HarmonyOS 在写入解码器输入缓冲前最多一次业务层复制；
- 接受 TLS 加密、系统网络栈和 AVCodec 输入缓冲所有权造成的系统级复制。

综合收益与风险，建议先做“低拷贝码流路径 + 指标环形缓冲 + watchdog”，再做动态帧率/温控治理；不建议立即强制 120 FPS 或重写整个传输协议。

## 2. 当前实现审计

### 2.1 macOS 采集与编码

相关实现：

- [`ScreenCaptureService.swift`](../macos/CapturePipeline/ScreenCaptureService.swift)
- [`H264EncoderService.swift`](../macos/CapturePipeline/H264EncoderService.swift)
- [`CaptureEncoderPipeline.swift`](../macos/CapturePipeline/CaptureEncoderPipeline.swift)

已实现的有效优化：

- ScreenCaptureKit 输出格式是 NV12。
- 捕获回调通过 `CMSampleBufferGetImageBuffer` 取得原始 `CVPixelBuffer`，并将同一个对象交给编码器。
- 没有生产路径上的 `CVPixelBufferLockBaseAddress`、CPU 像素遍历或中间 YUV/RGB 转换。
- VideoToolbox 要求或优先使用硬件编码，开启实时模式、禁止 B 帧重排、设置最大帧延迟为 0，并探测低延迟码率控制。
- 捕获流和编码入口采用 latest-frame 语义；旧 generation、过期帧和不连续帧均有保护。
- ScreenCaptureKit 报告 `.idle` 时不会继续编码，因此“真正静止画面跳帧”已经存在。`dirtyRects` 目前用于活动分类和动态码率。

因此，继续在这一段增加 CPU 色彩转换或重新创建像素缓冲池，反而可能破坏现有的低拷贝路径。

### 2.2 macOS 压缩码流打包

相关实现：

- [`H264EncoderService.swift`](../macos/CapturePipeline/H264EncoderService.swift)
- [`VideoFrame.swift`](../macos/SharedProtocol/VideoFrame.swift)
- [`TransportChannels.swift`](../macos/TransportCore/TransportChannels.swift)

当前每个编码访问单元至少发生以下业务层复制：

1. VideoToolbox 的 AVCC/HVCC `CMBlockBuffer` 被转换为 Annex B `Data`。这是一次完整 NAL 数据复制。
2. `VideoFrameCodec.encode` 新建协议帧 `Data`，写入 32 字节头后再 `append(frame.payload)`。这是第二次完整 payload 复制。
3. `NWConnection.send` 之后是否再次复制由 Network.framework、TLS 和系统网络栈决定，业务代码无法作零拷贝保证。

现有 Annex B 转换已经避免了“先生成多个 NAL `Data` 再合并”的额外复制，但“Annex B payload”和“最终网络帧”仍是两个独立的整帧分配。

### 2.3 HarmonyOS 接收、解析与解码

相关实现：

- [`ReceiverWorker.ets`](../harmony/entry/src/main/ets/workers/ReceiverWorker.ets)
- [`napi_init.cpp`](../harmony/entry/src/main/cpp/napi_init.cpp)
- [`FrameParser.cpp`](../harmony/entry/src/main/cpp/transport/FrameParser.cpp)
- [`VideoFrame.cpp`](../harmony/entry/src/main/cpp/protocol/VideoFrame.cpp)
- [`H264SurfaceDecoder.cpp`](../harmony/entry/src/main/cpp/decoder/H264SurfaceDecoder.cpp)

ArkTS 的 `new Uint8Array(info.message)` 是对收到的 `ArrayBuffer` 建立视图，N-API 也直接取得该 TypedArray 的地址；这两步本身没有明确的整帧复制。复制主要发生在 C++ 之后：

1. `FrameParser::Feed` 将 socket 分片插入 `buffer_`。
2. 完整帧到达后，再构造一个包含“头 + payload”的 `encoded` 向量。
3. `DecodeVideoFrame` 又把 payload 复制到 `VideoFrame::payload`。
4. `buffer_.erase(buffer_.begin(), ...)` 可能移动尚未解析的尾部数据。
5. 解码器需要输入时，`DrainLocked` 把 payload `memcpy` 到 `OH_AVBuffer_GetAddr` 返回的缓冲区。

也就是说，单帧在进入硬解前通常经历四次完整或近完整的业务层复制；TCP 一次回调中聚合多帧时，数组头部删除还会增加移动成本。

解码输出路径则已经正确：

- 先调用 `OH_VideoDecoder_SetSurface` 绑定 `OHNativeWindow`；
- 输出回调使用 `OH_VideoDecoder_RenderOutputBuffer` 直接呈现；
- 没有将解码后 YUV 拷回 ArkTS 或 CPU 绘制。

华为当前公开 API 要求应用填充由 `OH_AVCodecOnNeedInputBuffer` 提供的 `OH_AVBuffer`，再调用 `OH_VideoDecoder_PushInputBuffer`。现有 SDK 没有把任意网络缓冲区直接导入为解码输入的公开接口。参考：

- [OH_VideoDecoder C API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/capi-native-avcodec-videodecoder-h)
- 本机 SDK `native_avbuffer.h` 与 `native_avcodec_videodecoder.h`

### 2.4 队列、丢帧与长稳基础

已经具备的保护：

- 捕获流只保留最新 1 帧。
- 编码和发送入口有明确容量和字节上限。
- HarmonyOS 解析缓冲最大为“32 字节帧头 + 16 MiB payload”。
- 解码等待队列默认最多 2 帧，解码器内在途帧最多 5 帧。
- 超时或队列断裂后等待新 IDR，避免从错误参考帧继续解码。
- 连接、Surface、编码器和解码器回调都使用 generation 防止旧会话复活。

没有发现明显的无界视频帧队列。长时间运行风险主要来自周期性分配/移动、温控降频、底层回调停滞和恢复策略，而不是简单的队列无限增长。

## 3. “全链路零拷贝”可行性判断

| 链路段 | 当前状态 | 能否做到业务层零拷贝 | 说明 |
|---|---|---:|---|
| ScreenCaptureKit → `CVPixelBuffer` | 系统提供 | 是 | 缓冲区所有权由系统管理 |
| `CVPixelBuffer` → VideoToolbox | 直接提交 | 是 | 当前代码不读写像素基址 |
| VideoToolbox → Annex B | 整帧复制 | 否 | 需要把长度前缀改为 start code，并拼接参数集 |
| Annex B → 协议帧 | 再次整帧复制 | 可优化 | 可在一个最终缓冲中同时写协议头和 Annex B |
| 协议帧 → TLS/TCP | 系统管理 | 无法保证 | TLS 加密及内核网络栈不受业务代码控制 |
| ArkTS socket → N-API 地址 | 视图/借用 | 基本是 | 生命周期只覆盖同步调用 |
| N-API → C++ 帧对象 | 多次复制 | 可显著优化 | 可改为环形缓冲、偏移解析和移动所有权 |
| C++ payload → `OH_AVBuffer` | `memcpy` | 否 | 当前公开 AVCodec 输入模型要求填充其缓冲 |
| AVCodec → Surface/XComponent | 直接呈现 | 是 | 当前实现已经达到目标 |

因此：

- **不能直接实现真正的端到端零拷贝。**
- 即使改用 QUIC/UDP，也不能消除 TLS/加密、内核收发及 AVCodec 输入缓冲复制。
- 更改为 AVCC/HVCC 线格式只能消除 Mac 侧格式转换；HarmonyOS 硬解是否接受该输入格式仍需逐设备验证，而且不会消除向 `OH_AVBuffer` 的最终复制。
- 尝试原地修改 VideoToolbox 所有的 `CMBlockBuffer` 风险很高，其可写性和回调后的生命周期都不应由业务层假定。

建议把工程目标命名为“像素零拷贝 + 压缩码流低拷贝”，并用实际复制字节数、分配次数和 P95 时延验收。

## 4. 推荐优化项

### P0-1：重写 HarmonyOS 增量解析热路径

目标：从“分片复制 → 整帧复制 → payload 复制 → 数组前移”收敛为“分片写入固定/可增长环形缓冲 → 原位解析 → payload 移动或一次复制到 AVCodec”。

建议：

- 使用带读写游标的环形缓冲，禁止每帧 `erase(begin, ...)`。
- 帧头读取函数接收 `span`/指针与长度，不再创建完整 `encoded` 向量。
- `VideoFrame` 使用可移动的 payload 存储；解析完成时只构造一次 payload。
- 更进一步时，在解码器输入缓冲已经可用的情况下，可从环形缓冲直接复制到 `OH_AVBuffer`，不再先创建 `VideoFrame::payload`。
- 保留现有 16 MiB 上限、协议校验、session/generation 校验及模糊测试。

预期收益：减少接收端内存带宽、分配次数和 TCP 聚合场景下的尾部移动，主要改善高帧率或高码率下的 P95/P99 卡顿，而不只是平均帧率。

### P0-2：macOS 一次分配完成 Annex B 转换和协议打包

目标：消除 `VideoFrameCodec.encode` 对已经转换好的 Annex B payload 的第二次整帧复制。

建议：

- 预先计算 `32 字节协议头 + 参数集/start code + NAL` 的最终长度。
- 一次创建最终网络 `Data`，先写协议头，再从参数集和 `CMBlockBuffer` 直接写入 Annex B 内容。
- 发送队列持有最终 framed buffer，而不是再次持有 payload 后打包。
- 保持协议 v1 字节格式不变，因此无需同时升级 HarmonyOS。

这项改动比立刻设计协议 v2 风险低，也能直接减少每帧一个大对象和一次 payload 复制。

### P0-3：将性能统计改为固定环形缓冲或直方图

[`MediaModels.swift`](../macos/CapturePipeline/MediaModels.swift) 当前每类指标最多保存 4096 个样本：

- 达到上限时通过 `removeFirst(1024)` 淘汰旧数据；
- 每秒生成快照时，对多组数组执行 `sorted()`。

这些操作虽然有界，但会周期性移动内存并分配排序副本。建议：

- 使用固定容量环形缓冲，覆盖最旧样本；
- 或使用固定桶直方图/滑动窗口分位数估计；
- 指标快照移到低优先级队列，并记录快照自身耗时；
- 诊断关闭时降低采样率，例如每 4 或 8 帧采样一次，但累计 drop 计数仍逐帧更新。

这项优化不会改变媒体协议，适合作为长稳版本的首批改动。

### P0-4：增加媒体停滞 watchdog

编码器当前等待 VideoToolbox 回调时支持任务取消，但没有独立超时。如果底层不回调，等待可能永久持续。建议：

- 以当前帧周期为基础设置编码回调超时，例如 `max(250 ms, 8 个帧周期)`；
- 超时后使当前 generation 失败，失效并重建编码器，下一帧强制 IDR；
- HarmonyOS 增加“持续收到网络字节但无解码输出”和“解码输出存在但无呈现增长”两类 watchdog；
- watchdog 只能推进 generation 并走现有项目错误码/恢复路径，不能 `fatalError` 或直接跨线程销毁仍在回调的对象。

### P1-1：增加动态帧率和温控治理

当前网络自适应只调节码率和分辨率。建议新增独立的帧率档位控制：

- 档位固定为 120 → 90 → 60，不做任意小数帧率。
- 只有设备屏幕、HarmonyOS 硬解、Mac 虚拟显示和硬编全部支持时，才能进入高档位。
- 连续健康一段时间后才升档；发生持续掉帧、解码队列增长、温度升高或编码 P95 超预算时快速降档。
- 升降帧率需建立新 generation，首帧必须是 IDR，并沿用现有安全重建流程。
- 长时间运行优先保持稳定 60/90 FPS，不以“始终 120 FPS”为目标。

发行版 DMG 当前没有向 `P3HostConfiguration` 传入高于 60 的值。建议未来在界面提供：

- 自动（推荐）：根据能力、网络和温度选择 60/90/120；
- 稳定 60；
- 高刷优先（仍允许自动降级）。

此前 2720×1260 / 120 FPS 的设备验证说明能力链路可以工作，但不能替代发行应用自动模式的长稳验证。

### P1-2：收紧交互场景的延迟预算

当前 HarmonyOS 输入等待队列和输出过期阈值为 120 ms。该值适合防止频繁重置，但对于交互桌面已经可感知。

建议：

- 根据帧周期生成预算，而不是固定 120 ms；
- 参考起点为 2～3 个帧周期，并设置合理上下限；
- 解码完成后如有更新输出，继续丢弃过期 Surface 呈现，但不能任意丢弃依赖链中的 P 帧；
- 只有在确定参考链断裂时请求 IDR，避免“为了追帧频繁重建解码器”造成更长冻结。

该项必须以真机拖动窗口、快速鼠标移动和连续键盘输入的 P95/P99 数据调参。

### P1-3：长时间运行资源治理

建议持续采集但限制为固定窗口：

- Mac/HarmonyOS 进程常驻内存、每秒分配字节数和线程数；
- VideoToolbox/AVCodec 重建次数；
- 捕获、编码、发送、解码、呈现的 P50/P95/P99；
- sender/decoder queue 深度与 IDR 请求次数；
- Wi-Fi RTT、网络类型、设备温度或系统可提供的热状态；
- 实际呈现 FPS、连续无新画面的最长时间。

内存不应只验收“没有 OOM”，还应验证预热后 RSS 不持续单调增长。

### P2：协议 v2 与原生网络路径试验

只有在 P0/P1 数据证明码流复制仍是主要瓶颈时再考虑：

- 协议 v2 支持 AVCC/HVCC 或分段 payload；
- macOS 使用可分段发送对象，避免合并协议头和 payload；
- HarmonyOS 将视频 socket、TLS 和解析全部下沉到 Native 层，绕过 ArkTS 视频回调；
- QUIC 运行时具备后启用视频 datagram，并保留可靠控制通道。

这些方案会扩大兼容、证书、协议和回退测试范围，不适合作为第一轮优化。

## 5. 长稳验收方案

### 5.1 建议测试矩阵

| 场景 | 持续时间 | 主要观察项 |
|---|---:|---|
| 2560×1600 / 60 FPS 动态桌面 | 8 小时 | P95/P99、RSS 趋势、断流、恢复次数 |
| 设备原生分辨率 / 自动高刷 | 2 小时起，稳定后扩到 8 小时 | 温控降档、实际 FPS、掉帧率 |
| 静止文档与偶发滚动 | 2 小时 | 静止编码负载、唤醒首帧时延 |
| 快速鼠标、键盘、窗口拖动 | 每轮 10 分钟，重复 20 轮 | 交互时延、P99、画面割裂 |
| Wi-Fi 弱信号与接口切换 | 100 次 | generation、IDR、恢复时间 |
| 横竖屏切换与 Surface 重建 | 100 次 | 旧回调复活、黑屏、资源泄漏 |
| 睡眠/唤醒、锁屏/解锁 | 50 次 | 虚拟屏残留、编码/解码重建 |

### 5.2 建议通过门槛

- 60 FPS 良好网络下实际呈现帧率不低于现有设计门槛 58 FPS。
- 8 小时内无不可恢复断流，无旧 generation 恢复，无持续 RSS 增长。
- 队列深度不随运行时间单调增长。
- 高刷模式不能使 P95 端到端时延、掉帧率或温控降档频率劣于稳定 60 FPS 基线。
- watchdog 故障注入后能在限定时间内恢复，并且恢复首帧为 IDR。
- 每项低拷贝改动均记录“每帧复制次数、复制字节数、分配次数”前后对比。

## 6. 推荐实施顺序

1. 补充复制字节数、分配次数、P99、RSS 和 watchdog 诊断指标，建立 60 FPS 基线。
2. 将 macOS 性能样本改为环形缓冲/直方图，消除周期性排序与头删抖动。
3. 重写 HarmonyOS 环形解析器，优先把解码前四次复制压到一次必要的 `OH_AVBuffer` 写入。
4. 将 macOS Annex B 转换与协议帧构造合并为一次最终分配。
5. 增加编码、解码和呈现停滞 watchdog，完成故障注入。
6. 在上述优化通过 8 小时 60 FPS 长稳后，引入 60/90/120 动态档位与温控降级。
7. 最后再根据数据决定是否需要协议 v2、Native TLS/QUIC 或 AVCC/HVCC 线格式。

## 7. 不建议采用的做法

- 不增加捕获、发送或解码队列深度来“减少掉帧”；这通常只会增加交互延迟。
- 不在 CPU 上读取或转换 `CVPixelBuffer`，也不把 Surface 输出回读到 ArkTS。
- 不默认强制 120 FPS；当任一阶段超过 8.33 ms 时，高刷会加剧排队和温控降频。
- 不在没有更新画面时重复编码相同帧；当前 ScreenCaptureKit `.idle` 处理应保留。
- 不随意丢弃 P 帧后继续解码后续 P 帧；参考链断裂必须等待或请求 IDR。
- 不为追求“零拷贝”借用超过回调生命周期的 TypedArray、`CMBlockBuffer` 或 `OH_AVBuffer` 指针。
- 不把 ad-hoc 测试中的 120 FPS 成功等同于发行版本 8 小时稳定。

## 8. 最终判断

项目还有优化空间，而且最可靠的收益来自减少压缩码流复制和周期性内存抖动，而不是再次改动已经正确的像素采集/显示路径。

可实现的近期目标是：

- 保持现有两段像素零拷贝；
- macOS 压缩码流一次分配成最终协议帧；
- HarmonyOS 原位解析后只保留一次写入 AVCodec 的必要复制；
- 通过环形指标、watchdog、动态帧率与温控策略保证 8 小时长稳。

真正的“网络到屏幕全链路零拷贝”受 TLS、系统网络栈和 HarmonyOS AVCodec 输入缓冲模型限制，当前公开 API 下不可直接实现。工程上应追求可测量的低拷贝和低尾延迟，而不是无法验证的零拷贝标签。

## 9. P0 优化实现与验证（2026-07-25）

本轮实现了报告中风险最低、且不改变线上媒体协议的四项 P0 优化。

| 项目 | 实现 | 验证结论 |
|---|---|---|
| P0-1 HarmonyOS 解析热路径 | FrameParser 改为读写游标和延迟压缩，不再为每个完整帧创建“头 + payload”中间向量，也不再逐帧 erase(begin, ...) | 分片、粘包、乱序、超长帧和 5000 轮模糊测试仍通过；payload 只在形成 VideoFrame 时复制一次，随后才写入 OH_AVBuffer |
| P0-2 macOS 一次大块码流打包 | Annex B 输出预留并填充协议 v1 的 32 字节头；发送端复用已校验的 preframedData，不再由 VideoFrameCodec 对完整 payload 再次 append | H.264 真硬编 IDR、SPS/PPS、协议编码/解码和预封装一致性测试通过；仍需用 Instruments 在真机 8 小时场景确认 Foundation Data 子切片的实际分配行为 |
| P0-3 指标窗口 | 4096 样本改为固定环形存储 + 滑动直方图；延迟采用 100 µs 桶，dirty area 使用 1 permille 桶 | 去除了 removeFirst(1024) 与每秒多数组 sorted()；分位数和窗口覆盖行为均有单元测试 |
| P0-4 编码停滞 watchdog | Mac 编码回调超时为 `max(250 ms, 8 个帧周期)`，超时返回现有 `ENC_BACKPRESSURE` 项目错误并由既有会话恢复路径推进 generation | 超时和主动取消测试通过；本轮没有增加 HarmonyOS 解码 watchdog，避免在缺少真机停滞样本时误判静止桌面 |

本轮没有提前实现 P1 的自动 60/90/120 FPS 和温控治理。它需要先收集本轮低拷贝路径在真实设备、真实网络和持续负载下的 P95/P99、温度、RSS 与实际呈现 FPS 基线；在缺少这些数据时强制高刷会增加而非降低卡顿风险。

验证命令与结果：

    swift test
    swift test -c release
    cmake -S harmony/entry/src/main/cpp -B .build/harmony-host -DBUILD_PROTOCOL_TESTS=ON
    cmake --build .build/harmony-host
    ctest --test-dir .build/harmony-host --output-on-failure
    DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
      /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
      assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon

其中 macOS Debug 114 个测试通过、Release 115 个测试通过，各有 4 个需要真实系统能力的集成测试按既有条件跳过；HarmonyOS C++ 协议测试通过；HarmonyOS HAP 已完成原生 C++、ArkTS 与 debug 签名打包。剩余的 8 小时端到端长稳、温控和拖动窗口交互测试必须在真实设备上继续执行，不能由单元测试替代。

P1 的自动 60/90/120 FPS、温控治理和 HarmonyOS 解码/呈现 watchdog 尚未在本轮实现。应先采集本轮低拷贝路径的真机 P95/P99、RSS、温度和实际呈现 FPS，再决定对应阈值。

## 10. 真机基线与高频输入修复（2026-07-25）

### 10.1 已完成的真机基线

在 HarmonyOS 真机系统分辨率 2720×1260、设备能力上限 120 FPS、发行 Mac 应用实际
60 FPS 的组合下完成了短时采样。自动发现、既有配对和两条 TLS 通道均能正常建立。

连续 30 秒动态桌面基线的结果如下：

- 实时渲染多数为 55～60 FPS，观测范围为 45.9～60.8 FPS；
- 解码时延为 5.7～10.6 ms；
- 解码 in-flight 为 0～1，没有持续积压；
- 过期输出丢弃计数保持为 1，没有随运行时间增长；
- 控制 TCP 对端端口在该采样窗口内保持不变，没有发生会话重建。

向活动监视器搜索框注入一轮快速键盘输入时，实时渲染为 59.9 FPS、解码时延
6.0 ms、in-flight 为 1，过期输出丢弃没有增加。这说明在该短时样本中，键盘事件本身
不是主要瓶颈。

这些数据只能证明 60 FPS 短时链路已接近帧率目标，不能替代 8 小时 RSS、温度和尾延迟
验收，也不能证明 90/120 FPS 已具备发行条件。

### 10.2 高频指针事件暴露的控制通道风险

通过 HarmonyOS 视频区域连续注入高速单指滑动时，观测到控制与视频 TLS 会话发生重建。
代码审计发现接收端此前对 `TLSSocket.send` 的每次调用都立即启动独立 Promise：

- move/drag、scroll、heartbeat、receiver feedback、手势和 IDR 请求可能同时写入同一个
  TLS Socket；
- 任一 send Promise 失败都会上报 `NET_PROTOCOL_MISMATCH`；
- 页面收到该错误后按既有恢复逻辑推进 generation 并重新建立整条会话。

本机 HarmonyOS SDK 对 `TLSSocket.send(data): Promise<void>` 只定义异步完成和项目错误码，
没有承诺同一 Socket 支持多个并发写入。因此接收端控制通道已改为单写者队列：

- 同一时刻最多只有一个 `TLSSocket.send` 在途；
- move/drag、scroll、heartbeat 和 receiver feedback 只合并尚未发送且连续同类的最新项；
- leftDown/leftUp、手势和 IDR 请求仍保持严格顺序，合并不能跨越这些边界；
- 队列固定上限为 64，优先淘汰可合并项，无法安全腾出空间时返回项目错误码；
- 队列项、Socket 和 send 完成回调均绑定 generation，旧会话的成功或失败回调不能修改新
  会话状态；
- stop/reconnect 会先清空队列并使旧 generation 失效，不使用 `fatalError` 或强制解包。

该修改不改变协议 v1、公开接口、证书固定或配对数据格式。

### 10.3 验证状态与剩余复测

控制队列修改已经完成以下验证：

- ArkTS 严格编译、原生 C++、HAP 打包和 debug 签名成功；
- 最新 HAP 已覆盖安装到真机；
- macOS Debug 114 项通过、Release 115 项通过，各有 4 项真实系统集成测试按既有条件跳过；
- HarmonyOS C++ 协议测试通过。

当前源码重建的 ad-hoc Mac 应用曾无法出现在“录屏与系统录音”列表。根因是应用把
“曾请求录屏”永久写入 `UserDefaults`：二进制更新使旧 TCC 条目失效后，持久标记仍让按钮
跳过 `CGRequestScreenCaptureAccess()`，只打开没有当前应用条目的系统设置。现已改为：

- 录屏请求只在当前进程内去重，不再由跨版本持久标记阻止；
- 每次新应用首次显式点击都先调用系统请求 API 注册当前代码身份；
- 仍未授权时才打开系统设置，应用启动本身不会主动弹权限框。

修复版已验证出现在系统录屏列表，应用显示 Screen Recording/Touch control 均为 allowed，
服务能够进入 Streaming 并建立两条 TLS 通道。已授权的旧 Mac 应用构建时间早于本轮 P0
源码，因此其历史恢复次数仍不能用于判断新 watchdog 或低拷贝路径的表现。

后续仍需完成同一套可重复性能验收：

1. 建立连接后先记录稳定 30 秒的 TCP 对端端口和状态指标；
2. 重复 10 轮高速单指滑动、快速键盘输入和窗口拖动；
3. 验收控制端口不变、无 `NET_PROTOCOL_MISMATCH`、in-flight 不持续超过 1、过期丢弃不
   连续增长；
4. 再连续运行至少 30 分钟采集 Mac/HarmonyOS RSS、温度、恢复次数和 P95/P99，稳定后
   扩展到 8 小时。

在上述复测通过前，不应进入 90/120 FPS 自动升档，也不应继续收紧 HarmonyOS 过期帧阈值。

### 10.4 权限修复后的真机回归结果

使用当前源码 Mac 应用和最新 HarmonyOS HAP 完成了高速指针、快速键盘、窗口拖动及短时
持续负载回归。

启动时网络自适应从上次保存的 2592×1200 档位恢复到原生 2720×1260，按现有设计重建了
一次媒体 generation，因此控制端口从 48982 变为 48984、Mac Recoveries 从 0 变为 1。
模式恢复完成后的所有测试均以 48984 为稳定基线；此后没有再次发生端口变化或会话重建。

回归结果：

- 30 秒静止/低活动基线中，dirty/idle 策略将实际编码降到约 1～5 FPS；解码为
  6.5～9.6 ms、in-flight 为 0～1、过期丢弃为 0；
- 三轮高速远程指针往返覆盖 HarmonyOS 触控、控制通道、Mac 原始光标和视频回传，端口
  保持不变，未新增过期丢弃或 decoder recovery；
- 原生分辨率下两轮快速键盘输入分别达到 61.0 FPS 和 59.9 FPS，解码为 6.4～8.1 ms，
  in-flight 为 0～1；
- 三轮窗口大幅拖动达到 59.9～60.0 FPS，解码为 7.3～7.7 ms，没有会话重建；
- 约一分钟的 12 轮持续高速指针负载达到 56.8～60.9 FPS，解码为 5.9～12.1 ms，
  in-flight 始终为 0～1，过期丢弃始终为 0，IDR 请求计数保持为 3；
- 稳定负载期间 Mac RSS 约为 107 MiB（109.5 MB），采样范围没有单调增长；HarmonyOS 进程内存占比
  约为 1.2%～1.8%；
- 最终 Mac 端累计编码 31,836 帧，capture/encode/send 丢帧为 0/14/0，累计丢帧率约
  0.044%；VideoToolbox P95 为 9.4 ms、总编码 P95 为 9.7 ms、发送 P95 为 0.4 ms；
- 最终 RTT 为 10.4 ms、视频发送队列为 0、Recent error 为空，Recoveries 仍为模式恢复
  产生的 1。

本轮数据验证了 HarmonyOS 控制通道单写者与连续事件合并策略：此前高速输入导致的并发
TLS send 风险没有再次触发会话重建。60 FPS 原生分辨率链路已经达到短时稳定目标。

当前编码 P95 仍高于 120 FPS 的 8.33 ms 单帧预算，因此这些结果不支持直接启用 120 FPS。
下一阶段应先完成更长时间的温度/RSS 验收，或将 VideoToolbox P95 稳定压到 8 ms 以下，
再试验 90/120 FPS 自动档位。

## 11. P1 动态帧率健康门控第一阶段

P1 第一阶段没有把发行默认值从 60 FPS 改成 120 FPS，而是在 Mac 应用增加显式的
“Adaptive high refresh (experimental)”开关。关闭时完全保留原有稳定 60 FPS 行为；开启后
会话也先从 60 FPS 启动，再根据持续端到端数据决定是否逐级切换到 90/120 FPS。

升档同时要求：

- 当前为原生分辨率和活动画面，并已积累至少 5 秒编码样本；
- Mac 使用硬件编码且低延迟码率控制已生效；
- 发送队列为 0、接收端解码队列不超过 1、没有新增发送端或接收端丢帧；
- 接收端实际渲染帧率达到当前档位的 97%，RTT 小于 40 ms；
- VideoToolbox 与总编码 P95 均不超过下一档帧预算的 75%；
- 上述条件连续满足 30 个一秒样本。

因此从 60 升到 90 FPS 要求编码 P95 不高于约 8.33 ms；从 90 升到 120 FPS 要求不高于
约 6.25 ms。当前真机 9.7 ms P95 会被策略明确阻止升档，不会因为设备声明支持 120 Hz 就
盲目启用高刷。

以下条件连续出现两个一秒样本时快速降一级：

- Mac 进入 serious/critical thermal state；
- 发送队列积压、接收队列超过 1 或出现新增丢帧；
- 总编码 P95 超过当前帧预算的 95%；
- 活动画面实际渲染率低于当前档位的 90%；
- RTT 达到 70 ms。

静止内容不会因为 dirty/idle 跳帧造成的低实际 FPS 被误判为性能不足，也不会用静止样本
触发升档。档位变化通过现有可恢复会话路径推进 generation，旧回调仍被隔离，新流首帧
继续要求 IDR。虚拟显示器只有在实际刷新率与目标一致时才复用，避免保留 60 Hz 显示器却
错误宣称已经升到 90 Hz。

单元测试覆盖当前 9.7 ms P95 禁止升档、持续健康后升档、队列压力快速降档、温控降档、
静止画面不误升档，以及实验开关默认关闭。后续仍需在真机显式开启该开关，分别验证
60→90、90→60 和长期温控行为；在编码 P95 没有进一步下降前，预期策略会稳定保持 60 FPS。

第一轮真机试验已显式开启实验开关。会话按设计从原生 2720×1260 / 60 FPS 启动，没有
直接采用接收端声明的 120 FPS。高速指针维持活动画面后，VideoToolbox P95 为 10.6 ms、
总编码 P95 为 11.1 ms，视频发送队列为 0、Recoveries 为 0；控制器保持 60 FPS，没有
错误升档。该结果验证了健康门控逻辑，但也说明必须继续降低编码尾延迟，才能实际观察
60→90 的升档过程。

继续运行到约 5,000 个编码帧后，VideoToolbox P95 收敛到 9.1 ms、总编码 P95 收敛到
9.5 ms，队列和 Recoveries 仍为 0，档位继续保持 60 FPS，符合 8.33 ms 升档阈值。当前
P1 代码通过 macOS Debug 117 项和 Release 118 项测试，各有 4 项真实系统集成测试按既有
条件跳过；HarmonyOS Debug HAP 构建成功。

## 12. P1 编码尾延迟第二阶段

在动态帧率健康门控正确阻止不安全升档后，第二阶段继续处理 60 FPS 下
VideoToolbox 的尾延迟，不修改协议 v1、接收端公开接口或现有恢复语义。

本机 macOS SDK 对 `EnableLowLatencyRateControl` 的说明表明：低延迟码率控制使用无限
GOP，并与 `RealTime`、`ExpectedFrameRate`、`PrioritizeEncodingSpeedOverQuality` 组合
用于超低延迟编码。现有实现虽然已经启用这些属性，却仍设置了两秒最大关键帧间隔，并把
`DataRateLimits` 的一秒硬上限设为与平均码率完全相同。复杂桌面或周期 IDR 因此可能在
硬上限附近给后续帧带来码率控制压力。

本轮调整为：

- 低延迟码率控制实际生效时不再设置周期 IDR 间隔，首帧、generation 重建、丢帧恢复和
  接收端显式请求仍会强制生成 IDR；低延迟创建失败后的兼容会话继续保留原两秒间隔；
- `AverageBitRate` 继续控制长期平均值，`DataRateLimits` 仅为低延迟会话增加 25% 的一秒
  瞬时突发额度；非低延迟回退会话维持原硬上限；
- 硬件编码状态在 session 创建后缓存，不再在每帧回调完成后同步查询
  `UsingHardwareAcceleratedVideoEncoder`；
- Mac 端低延迟桌面流优先协商 H.264，具备双方硬件能力时仍保留 HEVC 回退；运行状态文案
  直接显示实际协商的编码格式，避免真机分析时猜测；
- 增加由 `RUN_ENCODER_BENCHMARK=1` 显式启用的 2720×1260 / 60 FPS 硬件编码基准，普通
  单元测试和 CI 不执行性能负载。

同一台 Mac、停止既有推流会话后，Release 基准各提交 180 帧，结果为：

| 编码 | 有输出帧 | P50 | P95 | P99 |
| --- | ---: | ---: | ---: | ---: |
| H.264 | 179 | 7.76 ms | 8.37 ms | 8.54 ms |
| HEVC | 179 | 8.40 ms | 9.01 ms | 9.56 ms |

因此在当前硬件和桌面交互目标下优先 H.264 有可测收益：P95 约降低 7%，P99 约降低
10.7%。该结果不代表所有 Mac 都有相同比例，所以没有删除 HEVC，也没有改变通用握手器
按服务端顺序协商的行为。

验证结果：

- macOS Debug 121 项通过，Release 122 项通过；两种配置各跳过 5 项需要显式环境开关的
  系统/性能测试；
- H.264 与 HEVC Annex B、参数集、IDR 和动态码率定向测试通过；
- HarmonyOS Debug HAP 构建成功，接收端本轮无代码变化；
- 新 ad-hoc Mac 应用和 DMG 已构建并通过 `codesign --verify`。

用户重新授权后完成了真机满帧测试。使用项目内置动态测试图持续产生原生
2720×1260 / 60 FPS 变化，实际协商为 H.264：

- 约 10 秒编码 597 帧，约 20 秒编码 1,201 帧，结束前累计 2,413 帧；
- VideoToolbox P95 稳定在 8.6～8.7 ms，总编码 P95 稳定在 8.7～8.8 ms；
- 启动阶段 capture/encode 分别累计 6/4 次丢帧，随后约 30 秒不再增长，send 丢帧为 0；
- 视频发送队列保持为 0，HW 与低延迟码率控制均为 on。

与上一阶段 HEVC 真机稳定值 VT 9.1 ms、总编码 9.5 ms 相比，H.264 真机结果分别降低约
5.5% 和 8.4%。但 8.6 ms 仍略高于 60→90 档位的 8.33 ms 健康门槛，所以实验控制器继续
保持 60 FPS 是正确行为；本轮仍不把 90/120 FPS 改成发行默认值。

## 13. 静止内容网络自适应误判修复

真机回归还暴露了一个与编码器无关的重建来源：ScreenCaptureKit 在静止桌面主动进入
idle 后，发送端只产生少量新帧；原网络自适应却始终用接收端实时 FPS 除以固定目标
60 FPS，连续把低 FPS 误判为严重拥塞。结果是码率逐级下降，随后将 2720×1260 降为
2592×1200 并重建 generation。该重建不是接收端跟不上，也不是网络队列积压。

修复后每秒同时采样发送端实际编码帧数：

- 发送端实际产帧率达到目标帧率 50% 以上时，接收渲染率以
  `min(目标帧率, 发送端实际帧率)` 为基准；
- 发送端低于目标 50% 时视为源端 idle，不使用接收渲染 FPS 判断拥塞；
- RTT、发送/接收队列和显式丢帧仍始终参与拥塞判断，因此不会掩盖真实网络问题；
- 新字段带默认值，现有公开初始化调用保持源码兼容，协议和 generation 隔离没有变化。

单元测试验证连续 30 个低产帧 idle 样本不会降码率或分辨率，同时发送端 60 FPS、接收端
仅 30 FPS 仍会在原有滞回次数后触发降码率。`P3PoCHost` 增加
`P3_POC_ANIMATED_TEST_PATTERN=0` 显式测试开关，默认值仍为 1，不改变原测试行为。

使用同一 P3HostCore 关闭动态测试图完成真机静止回归：

- 流始终保持原生 2720×1260 / H.264 / 60 FPS 配置；
- 前 10 秒仅编码约 40 帧，20 秒累计 269 帧，结束前累计 860 帧，覆盖明显低于目标
  50% 的源端 idle 阶段；
- 码率保持 12 Mbps，没有降到 9.6/8 Mbps，没有分辨率重建；
- capture/encode/send 启动阶段累计 6/1/0，随后不再增长；
- 最终 VideoToolbox P95 为 8.4 ms、总编码 P95 为 8.5 ms、发送 P95 为 0。

因此静止内容误判已通过单元测试和真机低产帧场景双重验证。修复版 DMG 已重新构建并安装；
由于每次 ad-hoc 重建都会改变代码身份，用户正常启动最终
`/Applications/Second Display.app` 前仍需对该最后一次构建重新授予录屏与辅助功能权限。

## 14. P0 显示刷新率与解码尾延迟闭环

前几轮数据已经证明发送队列和局域网不是当前主要瓶颈，但原有自适应控制仍缺少两个关键
观测量：HarmonyOS 解码尾延迟，以及 XComponent 实际获得的刷新节奏。因此控制器只能用
平均解码 FPS 推断接收端是否健康，既可能错过安全的 90 FPS 试运行，也可能在显示侧没有
跟上时继续升档。

本轮完成以下闭环：

- HarmonyOS 原生解码器使用固定 256 个样本的有界窗口统计输出回调延迟 P95，不引入长期
  增长的容器或每帧日志；
- XComponent 按协商值申请 60/90/120 Hz 的期望刷新范围，并注册帧回调采样实际调度频率；
  组件销毁时注销回调，回调同时校验组件和 generation，旧页面/旧会话不能复活；
- 解码 P95 和显示回调 FPS 作为可选字段加入 `receiverFeedback`。旧客户端缺少字段时仍可
  解码和继续 60 FPS 会话，但不会盲目自动升档；
- 60→90 FPS 的发送端编码 P95 门槛由下一档帧预算的 75% 调整为 82%，即约 9.11 ms；
  仍要求接收端解码 P95 不超过下一档预算的 95%，且显示刷新达到当前档位的 97%；
- 90→120 FPS 继续使用更严格的 75% 编码门槛和 80% 解码门槛。当前约 8.6～8.8 ms 的
  编码 P95 已超过 120 FPS 的 8.33 ms 总帧预算，因此没有强制开启 120 FPS；
- 接收端解码 P95 超过当前帧预算的 95%，或显示刷新低于当前档位的 90% 时，立即作为降档
  压力参与既有滞回控制，避免解码/显示队列累积成渐进式延迟。

这里采样到的是 XComponent 帧调度频率，用于确认系统是否提供了目标显示节奏；它不等同于
每一个解码帧都完成了物理面板扫描。后续若切换到解码器 Direct Surface Rendering，应再
补充提交到 Surface 与实际 present 的时间戳，形成更精确的端到端测量。

验证结果：

- macOS Debug 123 项、Release 124 项通过，各跳过 5 项需要显式系统环境的集成/性能测试；
- HarmonyOS 原生协议与 P95 窗口测试通过，Debug、Release HAP 均构建成功；
- 共享协议向量 12 个、媒体向量 2 个通过，私有 API 隔离和差异格式检查通过；
- Debug HAP 已生成，但设备拒绝当前本地签名，错误码 `9568322`（不受信任的应用来源）。
  为避免卸载现有发行身份应用并清除配对数据，本轮未强制替换设备应用。

下一步应使用与设备信任链一致的 Profile 安装该版本，采集高速鼠标、键盘输入、窗口拖动和
至少 30 分钟稳定运行数据。只有当 HarmonyOS 解码 P95、显示回调 FPS 和丢帧计数均满足
门槛时，才允许控制器实际试运行 90 FPS；在此之前不把 90/120 FPS 设为发行默认值。
