---
title: "CGVirtualDisplay 扩展桌面技术设计"
subtitle: "macOS 虚拟显示器 + HarmonyOS 副屏客户端"
author: "技术设计基线"
date: "2026-07-21"
lang: zh-CN
---

# 目录

0\. 文档控制  
1\. 目标与范围  
2\. 关键技术结论  
3\. 总体架构  
4\. 私有 API 隔离与兼容层  
5\. 虚拟显示器规格与身份  
6\. 生命周期与状态机  
7\. 显示器创建与枚举  
8\. HiDPI、扩展模式和排列位置  
9\. ScreenCaptureKit 采集设计  
10\. VideoToolbox 编码设计  
11\. 传输协议  
12\. HarmonyOS 客户端  
13\. 输入回传  
14\. 并发与背压  
15\. 故障恢复  
16\. 错误模型  
17\. 安全与权限  
18\. 可观测性  
19\. 测试策略  
20\. 发布与兼容性策略  
21\. 架构决策记录  
22\. 参考资料

# 0. 文档控制

| 项目 | 内容 |
|---|---|
| 文档状态 | 可进入 PoC 实施 |
| 目标模式 | 只实现真正的扩展桌面，不实现镜像模式 |
| macOS 基线 | Apple Silicon；macOS 14 及以上，首轮重点验证 macOS 14/15/26 |
| HarmonyOS 基线 | HarmonyOS NEXT 原生应用；以目标平板真机能力为准 |
| 首版显示规模 | 单台 HarmonyOS 设备、单块虚拟屏、60 Hz、SDR |
| 分发假设 | macOS 端采用 Developer ID 独立分发，不以 Mac App Store 为目标 |
| 设计版本 | v1.0 |

> **强制风险声明**：`CGVirtualDisplay` 是 CoreGraphics 私有 API，没有 Apple 官方兼容承诺。设计必须把私有 API 隔离在独立模块，并在运行时执行类、选择器和行为探测。任何系统版本不满足能力探测时，必须安全失败，不得影响用户已有显示器。

# 1. 目标与范围

## 1.1 产品目标

开发一套由 macOS 伴侣端和 HarmonyOS 客户端组成的扩展桌面系统。连接建立后，macOS 应出现一块独立显示器，用户可以在“系统设置 → 显示器”中排列该显示器，并将普通应用窗口拖入该桌面。虚拟显示器内容经低延迟编码和传输，在 HarmonyOS 平板上解码显示；触控、鼠标和键盘输入可反向控制该虚拟桌面。

## 1.2 MVP 功能范围

- 创建和销毁一块 `CGVirtualDisplay` 虚拟显示器。
- 默认以 2× HiDPI、60 Hz 运行；能力协商支持 90/120 Hz 实验档。
- 使用稳定的显示器身份保留 macOS 排列位置。
- 使用 ScreenCaptureKit 采集虚拟显示器。
- 使用 VideoToolbox 对画面进行 H.264 低延迟硬编码。
- 使用局域网 TCP 双通道完成首版视频和控制传输。
- HarmonyOS 使用 AVCodec Surface 模式解码，并通过 NativeWindow/XComponent 显示。
- 支持鼠标移动、左键、拖拽和双向滚动事件回传。
- 支持权限检查、断线恢复、睡眠唤醒后的会话重建和基础指标采集。

## 1.3 非目标

- 首版不支持镜像现有屏幕。
- 首版不支持 HDR、10-bit 和音频；90/120 Hz 仅作为显式实验档，不改变 60 Hz 稳定默认值。
- 首版不支持多块虚拟屏或多台接收设备同时连接。
- 首版不支持公网远程桌面、云中继和账号体系。
- 首版不承诺 Mac App Store 上架。
- 首版不依赖 AirPlay、Sidecar、DisplayLink 或内核扩展。

# 2. 关键技术结论

1. `CGVirtualDisplay` 负责让 WindowServer 注册一块独立显示器；只要对象被强引用持有，显示器保持存在，释放对象后显示器通常被移除。
2. `CGVirtualDisplayDescriptor` 中的 vendor、product、serial 共同影响系统对显示器身份和历史配置的识别。serial 必须在并发显示器间唯一，并且对同一设备保持稳定。
3. `applySettings` 返回成功不代表 ScreenCaptureKit 已经能够枚举到该显示器。必须处理 WindowServer 与 `SCShareableContent` 之间的异步可见性窗口。
4. macOS 可能异步恢复该显示器以前保存的低分辨率、镜像或排列状态。因此 HiDPI、扩展模式和位置恢复不能只执行一次。
5. 私有 API 变更、显示器创建失败和枚举超时必须是可恢复错误，不能通过强制解包、进程崩溃或永久修改用户显示设置处理。

# 3. 总体架构

![总体架构](report_assets/cgvd_architecture.png)

系统由六个核心域组成：虚拟显示、屏幕采集、视频编码、传输会话、HarmonyOS 解码渲染和输入回传。`SessionCoordinator` 是唯一允许跨域编排生命周期的组件，各子域之间只通过协议接口和不可变数据对象交互。

## 3.1 推荐仓库结构

```text
second-display/
├── docs/
│   ├── CGVirtualDisplay_Technical_Design.md
│   ├── AI_CODING_TASKS.md
│   └── protocol/
├── macos/
│   ├── SecondDisplayMacApp/
│   │   ├── App/
│   │   ├── Session/
│   │   ├── Capture/
│   │   ├── Codec/
│   │   ├── Transport/
│   │   ├── Input/
│   │   ├── Permissions/
│   │   └── Diagnostics/
│   ├── VirtualDisplayCore/
│   │   ├── Public/
│   │   ├── PrivateAPIShim/
│   │   └── Tests/
│   └── SecondDisplayMacTests/
├── harmony/
│   ├── entry/src/main/ets/
│   ├── entry/src/main/cpp/
│   │   ├── decoder/
│   │   ├── transport/
│   │   ├── renderer/
│   │   └── metrics/
│   └── entry/src/ohosTest/
├── shared/
│   ├── protocol/
│   ├── test-vectors/
│   └── schemas/
└── tools/
    ├── latency-probe/
    └── compatibility-probe/
```

## 3.2 模块职责

| 模块 | 核心职责 | 禁止承担的职责 |
|---|---|---|
| `PrivateAPIShim` | 私有类声明、运行时探测、创建和释放底层对象 | 不包含业务状态机、网络和 UI |
| `VirtualDisplayCore` | 身份生成、规格校验、模式维护、排列恢复 | 不直接编码或发送视频 |
| `CaptureService` | 找到目标 `SCDisplay`、建立和管理 `SCStream` | 不创建虚拟显示器 |
| `EncoderService` | H.264 编码、关键帧、码率与队列控制 | 不直接操作 Socket |
| `TransportService` | 握手、帧封装、连接与重连 | 不理解 CoreGraphics 对象 |
| `InputService` | 坐标映射和 CGEvent 注入 | 未授权时不得发送事件 |
| `HarmonyDecoder` | 解码器配置、NAL 输入和 Surface 输出 | 不在 ArkTS 主线程解析高频视频包 |
| `SessionCoordinator` | 串联完整状态、取消、恢复与错误收敛 | 不实现底层媒体算法 |

# 4. 私有 API 隔离设计

## 4.1 隔离原则

- 所有 `CGVirtualDisplay*` 声明只能出现在 `PrivateAPIShim` Target。
- App、Capture、Codec 和 Transport Target 不得引用私有类型。
- 对外只暴露 `VirtualDisplayHandle`、`CGDirectDisplayID` 和本项目自定义错误。
- 构建阶段增加静态检查，禁止私有类名出现在其他模块。
- 运行时先完成能力探测，再允许进入创建流程。
- 私有 API 调用必须在主线程或专用串行执行器中完成，MVP 统一使用 `@MainActor`。

## 4.2 运行时能力探测

能力探测至少验证：

```text
Class: CGVirtualDisplay
Class: CGVirtualDisplayDescriptor
Class: CGVirtualDisplaySettings
Class: CGVirtualDisplayMode
Selector: initWithDescriptor:
Selector: applySettings:
Selector: displayID
Selector: initWithWidth:height:refreshRate:
```

探测结果使用结构化模型返回：

```swift
struct VirtualDisplayCapabilityReport: Sendable {
    let supported: Bool
    let osVersion: OperatingSystemVersion
    let architecture: String
    let missingClasses: [String]
    let missingSelectors: [String]
    let probeVersion: Int
}
```

能力探测只证明符号存在，不能证明行为可用。因此安装后首次启动还需提供“创建测试显示器”诊断动作：创建最小显示器、等待系统枚举、验证模式、立即销毁，并输出脱敏诊断报告。

## 4.3 公共接口

```swift
protocol VirtualDisplayProviding: AnyObject, Sendable {
    func capabilityReport() -> VirtualDisplayCapabilityReport

    @MainActor
    func create(spec: VirtualDisplaySpec) throws -> VirtualDisplayHandle

    @MainActor
    func destroy(_ handle: VirtualDisplayHandle) async
}

struct VirtualDisplayHandle: Sendable {
    let displayID: CGDirectDisplayID
    let identity: DisplayIdentity
    let logicalSize: CGSize
    let framebufferSize: CGSize
}
```

`VirtualDisplayHandle` 不得直接持有或泄漏私有对象。具体实现内部通过 token 映射到强引用对象；只有 provider 可以销毁。

# 5. 显示器规格与身份

## 5.1 数据模型

```swift
struct VirtualDisplaySpec: Sendable, Equatable {
    let name: String
    let deviceId: UUID
    let orientation: DisplayOrientation
    let framebufferWidth: Int
    let framebufferHeight: Int
    let scaleFactor: Int       // MVP 固定为 2
    let refreshRate: Double    // 60/90/120；默认 60
    let physicalWidthMM: Double
    let physicalHeightMM: Double
}

struct DisplayIdentity: Sendable, Equatable {
    let vendorId: UInt32
    let productId: UInt32
    let serialNumber: UInt32
}
```

## 5.2 默认参数

| 参数 | MVP 默认值 | 说明 |
|---|---:|---|
| framebuffer | 2560 × 1600 | 与常见 16:10 平板匹配，可由握手覆盖 |
| logical size | 1280 × 800 | 2× HiDPI 下的桌面逻辑尺寸 |
| refresh rate | 60 Hz | 稳定默认值；协商后可显式试验 90/120 Hz |
| capture cap | 1920 × 1200 | 可缩放采集，不改变桌面布局 |
| pixel format | NV12 Video Range | 尽量减少编码前颜色转换 |
| vendorId | `0x4857` | 项目固定内部标识，发布前确认命名 |
| productId | `0x5344` | 项目固定内部标识，发布前确认命名 |

## 5.3 serial 生成规则

- 以接收端持久化 `deviceId` 为输入计算 SHA-256。
- 取摘要前 31 位作为基础 serial；值为 0 时替换为 1。
- 最高位用作方向标识：0 表示横屏，1 表示竖屏。
- 同一设备、同一方向和不同传输方式必须得到相同 serial。
- 多设备并发前必须增加冲突检测；MVP 虽只支持一台设备，也要记录冲突日志。

稳定身份能让 macOS 更有机会恢复显示排列，但系统的保存行为属于实现细节，因此本项目还要按 `deviceId` 自行持久化显示器 origin。

## 5.4 创建参数

创建时执行以下映射：

```text
descriptor.maxPixelsWide  = framebufferWidth
descriptor.maxPixelsHigh  = framebufferHeight
descriptor.sizeInMillimeters = handshake 或设备预设
settings.hiDPI = 1
mode.width  = framebufferWidth  / scaleFactor
mode.height = framebufferHeight / scaleFactor
mode.refreshRate = negotiatedRefreshRate // 60/90/120，创建失败时降档重试
```

所有宽高必须为正数，编码尺寸必须为偶数，逻辑尺寸不得小于 800 × 600。超过本机编码器或接收端声明能力的规格在创建前拒绝。

# 6. 生命周期与状态机

![会话状态机](report_assets/cgvd_state_machine.png)

## 6.1 状态定义

```swift
enum SessionState: Equatable, Sendable {
    case idle
    case checkingCapability
    case waitingForReceiver
    case creatingVirtualDisplay
    case waitingForDisplayEnumeration
    case stabilizingDisplayMode
    case startingCapture
    case startingEncoder
    case streaming
    case reconfiguring(reason: ReconfigureReason)
    case recovering(attempt: Int)
    case stopping
    case failed(SessionFailure)
}
```

## 6.2 关键不变量

- `streaming` 状态下必须同时存在 receiver connection、virtual display、SCStream 和 encoder。
- 在同一 session generation 中最多存在一块虚拟显示器。
- 所有异步回调携带 generation；旧 generation 回调必须丢弃。
- `stop()` 必须幂等，并能取消任何等待枚举、权限轮询和重连任务。
- `failed` 状态不得保留虚拟显示器强引用。
- 状态变更只允许发生在 `SessionCoordinator` actor 内。

## 6.3 创建顺序

1. 接收端建立连接并发送 `ClientHello`。
2. 校验协议版本、分辨率和解码能力。
3. 检查 `CGVirtualDisplay` 能力。
4. 在主线程创建 descriptor、display、settings 和 mode。
5. 调用 `applySettings`，失败则释放对象并进入重试或失败。
6. 通过 CoreGraphics 验证 displayID 已在线。
7. 轮询 `SCShareableContent`，直到出现同一 displayID。
8. 验证并稳定 HiDPI、扩展模式和排列位置。
9. 建立 SCStream。
10. 建立 VideoToolbox encoder。
11. 发送 `ServerReady`，开始输出视频。

## 6.4 销毁顺序

1. 停止接收新的输入事件。
2. 向接收端发送 session closing。
3. 等待 `SCStream.stopCapture()` 完成，设置超时保护。
4. 停止提交新帧并完成/失效 `VTCompressionSession`。
5. 清空待发送帧和关键帧缓存。
6. 释放虚拟显示器强引用。
7. 观察 CoreGraphics remove 事件或轮询在线列表，确认显示器消失。
8. 清理连接、定时器、回调和 session generation。
9. 回到 `idle`。

# 7. 创建后稳定化

## 7.1 ScreenCaptureKit 枚举竞态

`applySettings` 成功后，新 displayID 可能不会立即出现在 `SCShareableContent.displays`。实现采用可取消的指数退避：

```text
100 ms → 200 ms → 400 ms → 800 ms → 1 s（重复）
总等待上限：15 s
```

每次轮询必须重新获取 `SCShareableContent.current`，并同时检查：

- session generation 是否仍有效；
- displayID 是否仍在线；
- provider 是否收到 termination callback；
- 用户是否主动停止会话。

超时返回 `VD_ENUMERATION_TIMEOUT`，释放虚拟显示器后最多重建两次。禁止在未释放旧 display 的情况下使用相同 serial 创建新 display。

## 7.2 HiDPI 模式维护

使用 `CGDisplayCopyAllDisplayModes` 找到 logical width 与 `pixelWidth = logical width × 2` 的模式。如果当前模式不匹配：

1. 使用 `CGBeginDisplayConfiguration`；
2. 使用 `CGConfigureDisplayWithDisplayMode`；
3. 使用 `CGCompleteDisplayConfiguration` 提交；
4. 重新验证当前 mode。

监听 `CGDisplayRegisterReconfigurationCallback`，在模式变化后重新校验。创建后的前 8 秒每 250 ms 检查一次，进入稳定状态后改为事件驱动，并保留 5 秒一次的轻量 watchdog。

## 7.3 强制扩展模式

如果 `CGDisplayIsInMirrorSet(displayID) != 0`，使用公开的显示配置函数解除虚拟屏及其他显示器对它的镜像关系。提交范围优先使用 `.forSession`，不要永久写入用户的其他显示器配置。

解除镜像前后都要保存并验证显示器集合。若操作失败，不得继续推流“伪扩展”画面，应进入 `VD_MIRROR_DETACH_FAILED`。

## 7.4 排列位置

保存以下信息：

```json
{
  "deviceId": "UUID",
  "orientation": "landscape",
  "logicalWidth": 1280,
  "logicalHeight": 800,
  "originX": 1728,
  "originY": 0
}
```

恢复时使用 `CGConfigureDisplayOrigin`，随后读取 `CGDisplayBounds` 取得 WindowServer 实际吸附后的坐标，并以实际结果覆盖存储值。不得假设请求坐标会被原样接受。

# 8. ScreenCaptureKit 设计

## 8.1 绑定策略

只根据 `CGDirectDisplayID` 匹配 `SCDisplay.displayID`，不得根据显示器名称匹配。显示器名称可能本地化、重复或被系统修改。

```swift
protocol DisplayCaptureServicing: AnyObject, Sendable {
    func waitForDisplay(id: CGDirectDisplayID, timeout: Duration) async throws -> SCDisplay
    func start(display: SCDisplay, configuration: CaptureSpec) async throws -> AsyncStream<CapturedFrame>
    func stop() async
}
```

## 8.2 首版配置

| `SCStreamConfiguration` 参数 | 建议值 |
|---|---|
| width / height | 不超过 receiver 能力和 capture cap；必须为偶数 |
| minimumFrameInterval | 目标帧率达到显示源刷新率时使用 0，避免额外节流；低于源刷新率时按目标 fps 限流 |
| pixelFormat | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` |
| queueDepth | 低延迟默认 3；可配置范围 3–8，只有处理能力不足时才增加 |
| showsCursor | 默认 true；若采用独立游标通道则 false |
| capturesAudio | false |

## 8.3 帧接收规则

- 只处理 `.screen` 类型和有效 `CMSampleBuffer`。
- 解析 ScreenCaptureKit attachment，忽略 incomplete、blank 或 idle 状态帧。
- 每帧记录编码 PTS、`SCStreamFrameInfo.displayTime` 转换后的采集单调时钟、回调单调时钟、content rect 和 `dirtyRects` 脏区比例。
- 缺少 `dirtyRects` 元数据时按活动画面处理；空数组按静止画面处理；越界矩形先裁剪到 content rect 再累计面积。
- 脏区比例连续 750 ms 不高于 0.2% 时进入静止态；任一帧达到 1% 时立即恢复活动态，避免交互开始时仍停留在低码率。
- 编码队列拥塞时丢弃旧帧，而不是无限排队。
- 应用侧采集流只保留最新 1 帧；替换旧帧时，当前最新帧立即标记 discontinuity。
- 编码前同时检查回调等待时间和 capture PTS 总年龄，超过两个目标帧周期时丢弃。
- 分辨率变化、display removed 或 stream error 统一上报 SessionCoordinator。

# 9. VideoToolbox 编码

## 9.1 编码器抽象

```swift
protocol VideoEncoding: AnyObject, Sendable {
    func configure(_ spec: EncoderSpec) throws
    func encode(_ frame: CapturedFrame, forceKeyFrame: Bool) async throws -> EncodedFrame?
    func updateBitrate(_ bitsPerSecond: Int) throws
    func invalidate()
}
```

## 9.2 H.264 初始配置

| 参数 | MVP 值 |
|---|---|
| codec | H.264 |
| real-time | true |
| frame reordering | false |
| expected frame rate | 协商值，稳定默认 60；实验档 90/120 |
| max frame delay | 0 |
| bitrate | 60 fps 基准 12 Mbps，按 fps 线性缩放，范围 8–30 Mbps |
| profile | High AutoLevel；接收端不支持时降级 Main |
| keyframe | 首帧、重连、解码错误或显式请求时强制；最长间隔 2 s |

编码输出统一转换为 Annex B。转换时直接从 `CMBlockBuffer` 解析 AVCC NAL 范围，只分配一次最终 payload，并将起始码、SPS/PPS 和 NAL 直接写入；非连续 block buffer 只按 NAL 拷贝，不生成完整 AVCC 中间副本。IDR 前携带 SPS/PPS；传输层不得解析 AVCC。编码器回调返回的 frame 必须包含：sequence、PTS、keyframe、capture timestamp、encode-complete timestamp 和 payload。

活动态使用握手基准码率；进入静止态后降至基准的 55%（不低于 8 Mbps），恢复活动态时立即恢复基准码率。运行时码率更新失败按可选优化降级并记录指标，不得终止会话。

## 9.3 背压

- 编码前队列容量：2 帧。
- 发送队列容量：最多 2 个完整视频帧或 8 MiB，先达到者生效。
- 超限丢弃非关键帧，并设置 `forceNextKeyFrame = true`。
- 绝不阻塞 ScreenCaptureKit 回调队列等待网络。

# 10. 传输协议

## 10.1 分阶段选择

- PoC/MVP：控制通道和视频通道使用两个独立 TCP 连接，均开启 `TCP_NODELAY`；避免视频拥塞阻塞输入事件。
- 产品优化：保持控制通道可靠传输，将视频通道替换为 UDP/QUIC 实现；接口层不得依赖具体传输。
- USB：优先把 USB 抽象为 IP 网络接口，复用相同协议。HarmonyOS 不采用开发者调试端口作为商用方案。

## 10.2 握手模型

```json
{
  "type": "clientHello",
  "protocolVersion": 1,
  "deviceId": "UUID",
  "deviceName": "Harmony Tablet",
  "nativeWidth": 2560,
  "nativeHeight": 1600,
  "deviceScale": 2.0,
  "maxFps": 60,
  "codecs": ["h264"],
  "maxDecodeWidth": 2560,
  "maxDecodeHeight": 1600,
  "orientation": "landscape"
}
```

`maxFps` 必须取设备显示能力与 H.264 硬解能力的较小值，并归一化为 60/90/120。Mac 从不超过客户端能力和服务端首选值的标准档中选取最高档；高刷虚拟屏创建失败时按 120→90→60 降档，并以实际档位重新生成 `serverReady`。60 Hz 是默认稳定档，90/120 Hz 必须显式启用并以端到端数据验收。

Mac 返回：

```json
{
  "type": "serverReady",
  "protocolVersion": 1,
  "sessionId": "UUID",
  "display": {
    "logicalWidth": 1280,
    "logicalHeight": 800,
    "framebufferWidth": 2560,
    "framebufferHeight": 1600,
    "refreshRate": 60,
    "serialNumber": 123456
  },
  "stream": {
    "codec": "h264",
    "width": 1920,
    "height": 1200,
    "fps": 60,
    "bitrate": 16000000
  }
}
```

## 10.3 二进制视频帧

避免用“是否像 JSON”推断帧类型。所有视频帧使用固定二进制头，网络字节序：

| 字段 | 类型 | 说明 |
|---|---|---|
| magic | 4 bytes | `SDS1` |
| version | uint8 | 当前为 1 |
| frameType | uint8 | 1=video，2=codecConfig |
| flags | uint16 | bit0=keyframe，bit1=discontinuity |
| sequence | uint32 | 单调递增，允许回绕 |
| ptsUs | uint64 | 单调时钟微秒 |
| captureUs | uint64 | Mac 采集时间 |
| payloadLength | uint32 | 最大 16 MiB |
| payload | bytes | Annex B H.264 |

控制通道采用长度前缀 JSON：`uint32 length + UTF-8 JSON`。单条消息上限 64 KiB，未知 type 必须忽略并记录一次采样日志。

# 11. HarmonyOS 接收端

## 11.1 分层

```text
ArkTS / ArkUI
  ├── 配对与设备列表
  ├── 会话状态展示
  ├── 画质和触控设置
  └── XComponent Surface 生命周期
            ↓ NAPI
C++ Native Core
  ├── ControlClient
  ├── VideoReceiver
  ├── FrameParser
  ├── H264Decoder (OH_VideoDecoder)
  ├── NativeWindowRenderer
  └── MetricsCollector
```

## 11.2 解码流程

1. ArkUI 创建 `XComponent` Surface。
2. Native 层取得并持有 NativeWindow。
3. 收到 `serverReady` 后创建 `OH_VideoDecoder`。
4. 设置 H.264 MIME、宽高、帧率和 Surface 输出。
5. codecConfig/IDR 到达后启动解码。
6. 网络线程解析完整帧后写入解码输入缓冲。
7. 解码输出直接送 Surface；不回读到 CPU。
8. Surface 重建、应用前后台或分辨率变化时，执行可取消的 decoder 重建。

## 11.3 接收端背压

- 默认不建立超过 2 帧的抖动缓冲。
- 当 decoder 输入队列积压时丢弃到下一个 IDR，并发送 `requestKeyFrame`。
- 视频帧过期阈值初始为 120 ms；过期帧不得继续排队。
- 任何 decoder fatal error 都必须回传错误码和最近 sequence。

# 12. 输入回传

## 12.1 坐标系统

HarmonyOS 发送归一化坐标 `[0, 1]`，原点为视频左上角。macOS 使用当前 `CGDisplayBounds(displayID)` 映射到全局桌面坐标：

```text
globalX = display.origin.x + normalizedX × display.width
globalY = display.origin.y + normalizedY × display.height
```

必须使用 logical display bounds，不直接使用编码分辨率。视频缩放、HiDPI 和网络降分辨率都不得改变输入坐标语义。

## 12.2 权限与事件

- 使用 `AXIsProcessTrustedWithOptions` 检查辅助功能权限。
- 未授权时允许显示画面，但拒绝事件注入并在 UI 提示。
- 通过独立 `CGEventSource(.hidSystemState)` 创建事件。
- MVP 支持 move、leftDown、leftUp、drag、scroll。
- 事件带 sessionId 和 sequence；旧 session 输入必须丢弃。
- disconnect 时如果鼠标处于 down 状态，必须合成 mouseUp，避免卡住拖拽状态。

# 13. 并发与内存模型

| 执行域 | 负责内容 |
|---|---|
| `@MainActor` | 私有显示 API、AppKit UI、显示器创建和释放 |
| `SessionCoordinator actor` | 状态机、generation、恢复策略 |
| Capture serial queue | SCStream 回调与帧初筛 |
| Encoder serial queue | VTCompressionSession 提交与输出 |
| Transport queues | 控制和视频收发，互相独立 |
| Harmony native worker | 网络解析、decoder 输入和指标 |

CVPixelBuffer 在送入编码器期间必须保持有效；禁止把裸指针跨线程保存。所有回调捕获对象时优先使用弱引用，并由 session generation 防止过期回调复活已经停止的会话。

# 14. 故障恢复

| 场景 | 检测方式 | 恢复策略 |
|---|---|---|
| `applySettings` 失败 | 返回 false | 释放对象；2 秒间隔重试，最多 3 次 |
| SCK 枚举超时 | 15 秒未出现 displayID | 释放并重建，最多 2 次 |
| 系统终止虚拟屏 | termination handler / display callback | 停流并进入 recovering |
| SCStream 停止 | delegate error | 若 display 在线则重建 capture，否则重建 session |
| 编码器失败 | OSStatus / 无输出 watchdog | 重建 encoder 并请求 IDR |
| 网络断开 | connection state | 保留 display 最多 10 秒等待快速重连；超时销毁 |
| 接收端解码失败 | control error | 清队列、强制 IDR；重复失败则重建 encoder |
| 睡眠唤醒 | workspace notification + display callback | 全量重建 capture/encoder；必要时重建 display |
| 方向变化 | 新 hello / orientation event | MVP 提示重新连接；P2 实现 display 重建 |

重试使用指数退避并加随机抖动。任何路径的累计恢复时间超过 30 秒后停止自动重试，显示可操作错误，而不是无限循环。

# 15. 错误码

| 错误码 | 含义 | 用户动作 |
|---|---|---|
| `VD_CAPABILITY_MISSING` | 私有类或 selector 缺失 | 当前 macOS 不受支持 |
| `VD_APPLY_FAILED` | `applySettings` 返回失败 | 重试；导出诊断 |
| `VD_ENUMERATION_TIMEOUT` | SCK 未发现新显示器 | 重连或重启 Mac 伴侣端 |
| `VD_HIDPI_MODE_MISSING` | 未发现目标 2× 模式 | 降级规格或重建显示器 |
| `VD_MIRROR_DETACH_FAILED` | 无法解除镜像集合 | 用户在显示设置手动确认 |
| `VD_TERMINATED_BY_SYSTEM` | 系统终止虚拟屏 | 自动重建 |
| `CAP_PERMISSION_DENIED` | 缺少屏幕录制权限 | 打开系统设置授权 |
| `CAP_STREAM_STOPPED` | SCStream 意外终止 | 自动重建捕获 |
| `ENC_CREATE_FAILED` | 编码器创建失败 | 降低分辨率并重试 |
| `ENC_BACKPRESSURE` | 编码或发送积压 | 丢旧帧、降低码率、请求 IDR |
| `NET_PROTOCOL_MISMATCH` | 协议版本不兼容 | 更新对应客户端 |
| `DECODER_FATAL` | Harmony 解码器不可恢复错误 | 重建 decoder 或降级规格 |
| `INPUT_PERMISSION_DENIED` | 缺少辅助功能权限 | 只显示，不控制 |

# 16. 权限与安全

## 16.1 macOS 权限

- 屏幕录制：首次建立 capture 前检查；使用有上下文的用户操作触发授权。
- 辅助功能：只有用户开启“触控控制”时请求。
- 本地网络：说明画面只在本地设备间传输。

## 16.2 连接安全

- 首次配对通过 PIN/二维码确认，保存双方公钥指纹。
- 控制通道使用 TLS 1.3。
- MVP 视频 TCP 通道同样启用 TLS；后续 UDP/QUIC 必须保持认证加密。
- 默认仅绑定本地接口，不监听公网。
- 日志禁止记录帧数据、键盘文本和剪贴板内容。
- 接收端设备移除后立即吊销长期凭据。

# 17. 指标与诊断

每个 session 至少记录：

```text
virtual_display_create_ms
virtual_display_enumeration_ms
capture_fps / capture_drop_count
encode_p50_ms / encode_p95_ms
encoded_bitrate_bps
video_send_queue_depth
network_rtt_ms
decoder_queue_depth
receiver_render_fps
estimated_end_to_end_latency_ms
recovery_count_by_reason
```

日志使用结构化 JSON Lines，包含 timestamp、level、sessionId、generation、component、event、errorCode 和采样字段。诊断导出前对设备名称、IP、UUID 和用户路径做哈希或移除。

# 18. 测试策略

## 18.1 单元测试

- serial 生成稳定性、方向隔离和冲突处理。
- `VirtualDisplaySpec` 参数校验。
- 状态机合法/非法转换。
- 二进制帧编码解码和大小限制。
- Annex B SPS/PPS 与 NAL 拆分。
- 坐标映射、滚动缩放和 mouseUp 补偿。
- 背压与丢帧策略。

## 18.2 集成测试

- 创建显示器后在系统显示列表中出现，并确认为扩展而非镜像。
- 释放 handle 后显示器从在线列表消失。
- SCK 能按 displayID 枚举并输出非空帧。
- 1080p/1200p H.264 测试向量可在 HarmonyOS 真机连续解码。
- 网络断开、重连后首个可显示帧必须是 IDR。
- 休眠唤醒、锁屏、App 前后台和 Surface 重建。

## 18.3 兼容矩阵

| 维度 | 最低覆盖 |
|---|---|
| Mac 芯片 | M1、M2/M3、M4 或更新一款 |
| macOS | 14、15、26 当前最新小版本 |
| HarmonyOS 设备 | 至少 3 款目标平板 |
| 网络 | 2.4 GHz、5 GHz、6 GHz（如设备支持）、USB 网络 |
| 显示场景 | 仅内屏、已有外接屏、合盖、睡眠唤醒 |

## 18.4 长稳与故障注入

- 8 小时持续桌面变化测试。
- 每 30 秒断网/恢复，共 100 次。
- 每 5 分钟销毁/重建虚拟显示器，共 100 次。
- 快速连接/断开、App 强退和 Mac 睡眠期间断开。
- 发送损坏帧头、超长 payload、旧 session 输入和乱序控制消息。

# 19. 性能验收

| 指标 | MVP 门槛 | 目标值 |
|---|---:|---:|
| 虚拟显示创建到可采集 | P95 ≤ 8 s | P95 ≤ 3 s |
| 画面分辨率/帧率 | 1920×1200 / 60 fps | 2560×1600 / 60 fps |
| Wi-Fi 端到端延迟 | P50 ≤ 100 ms，P95 ≤ 180 ms | P50 ≤ 80 ms，P95 ≤ 140 ms |
| 有线端到端延迟 | P50 ≤ 70 ms | P50 ≤ 50 ms |
| 良好网络下接收帧率 | ≥ 55 fps | ≥ 58 fps |
| 连续运行 | 30 分钟无断流 | 8 小时无不可恢复错误 |
| 断线恢复 | ≤ 5 s | ≤ 3 s |

# 20. 发布与降级策略

1. macOS 端采用独立签名、公证和更新通道；每次构建保持稳定 bundle identifier 和签名身份，避免 TCC 权限反复失效。
2. 维护 `CompatibilityManifest`：按 OS build 标记 supported、experimental、blocked。
3. 新 macOS Beta 发布后自动运行 capability probe 和创建/枚举/销毁冒烟测试。
4. 发现破坏性系统更新时，通过远程兼容清单停止新建虚拟屏，并给出明确提示；远程配置失败时沿用本地最后成功清单，不得任意启用未知系统。
5. 提供 HDMI Dummy 兼容模式作为非私有 API 的产品兜底，但它不属于本设计的 MVP 实现范围。

# 21. 架构决策记录

| ADR | 决策 | 原因 |
|---|---|---|
| ADR-001 | 私有 API 只存在于独立 Shim | 降低变更面并支持运行时阻断 |
| ADR-002 | MVP 仅支持单虚拟屏 | 优先解决生命周期和稳定性 |
| ADR-003 | 2× HiDPI、60 Hz、SDR | 覆盖办公体验并控制复杂度 |
| ADR-004 | ScreenCaptureKit 按 displayID 绑定 | 避免名称匹配不稳定 |
| ADR-005 | H.264 + VideoToolbox | 兼容性和硬件覆盖最好 |
| ADR-006 | 控制与视频分离连接 | 避免视频拥塞阻塞输入 |
| ADR-007 | Harmony 高频链路放在 C++ | 降低 ArkTS 主线程和 GC 压力 |
| ADR-008 | 重建优先于原地修复 | 私有显示对象内部状态不可观察 |

# 22. 参考资料

1. [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/)：公开的高性能屏幕采集框架。
2. [Apple SCShareableContent](https://developer.apple.com/documentation/screencapturekit/scshareablecontent)：可采集显示器、应用和窗口的枚举入口。
3. [Apple 低延迟 VideoToolbox 编码](https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing)：实时编码的官方配置方向。
4. [Apple CGDisplayRegisterReconfigurationCallback](https://developer.apple.com/documentation/coregraphics/cgdisplayregisterreconfigurationcallback%28_%3A_%3A%29)：显示器配置变化监听。
5. [Apple AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)：辅助功能授权检查。
6. [Chromium VirtualDisplayMacUtil](https://chromium.googlesource.com/chromium/src/+/d441ddf663e568fe8383d59a31e0dfacb9d9535b/ui/display/mac/test/virtual_display_mac_util.mm)：Chromium 测试代码中的虚拟显示创建方式；其接口注释明确由 CoreGraphics 二进制生成。
7. [KhaosT/CGVirtualDisplay](https://github.com/KhaosT/CGVirtualDisplay)：早期最小示例与私有头声明。
8. [VirtualDisplayKit](https://github.com/xocialize/VirtualDisplayKit)：将虚拟显示、ScreenCaptureKit 和 VideoToolbox 组合的开源实现，并明确说明私有 API 风险。
9. [OpenDisplay](https://github.com/peetzweg/opendisplay)：虚拟显示、低延迟编码、Wi-Fi/USB 与输入回传的端到端开源参考。
10. [OpenDisplay 枚举/重连竞态](https://github.com/peetzweg/opendisplay/issues/107)：新建虚拟显示与 ScreenCaptureKit 可见性之间的实际竞态案例。
11. [HarmonyOS AVCodec Kit](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/avcodec-kit)：HarmonyOS 音视频编解码能力入口。
12. [HarmonyOS XComponent](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-xcomponent)：Native Surface 与媒体渲染承载组件。

> 参考开源项目仅用于验证技术路径和学习公开源代码。正式产品必须逐一核对许可证、归属要求和代码质量，禁止未经审查直接复制实现。
