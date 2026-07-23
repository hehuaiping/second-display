# CGVirtualDisplay 扩展桌面：AI Coding 实施任务

版本：v1.0  
日期：2026-07-21  
关联设计：[CGVirtualDisplay_Technical_Design.md](CGVirtualDisplay_Technical_Design.md)

## 1. 使用方式

本文件用于把项目拆成适合 Codex、Claude Code 等 AI Coding 工具逐项执行的任务。每次只选择一个任务，不要让 AI 同时实现多个 Epic。开始前必须把关联设计章节、目标文件和验收命令一起提供给 AI。

### 1.1 单任务执行规则

1. 一个任务对应一个分支或一个独立提交。
2. AI 开始编码前先读取本任务指定文件、项目约束和现有测试。
3. 未列入任务范围的重构一律禁止。
4. 私有 API 只能出现在 `macos/VirtualDisplayCore/PrivateAPIShim`。
5. 每个任务必须包含自动化测试或说明为什么只能真机验证。
6. 任务完成后输出：修改文件、关键决策、测试结果、已知风险和下一任务依赖。
7. 未达到验收标准不得自动进入下一任务。

### 1.2 通用 AI Coding 提示词模板

```text
你正在实现 CGVirtualDisplay 扩展桌面项目的任务 <TASK-ID>。

必须先阅读：
1. docs/CGVirtualDisplay_Technical_Design.md 的 <章节>
2. docs/AI_CODING_TASKS.md 的 <TASK-ID>
3. <相关现有源码和测试>

目标：<任务目标>
允许修改：<文件或目录>
禁止修改：<文件或目录>
硬性约束：
- 不扩大任务范围；
- 不在 PrivateAPIShim 之外引用 CGVirtualDisplay 私有类型；
- 不删除或弱化已有测试；
- 异步流程必须支持取消并防止旧 generation 回调复活；
- 失败必须返回项目错误码，不得 fatalError/强制解包；
- 保持现有公开接口向后兼容，除非任务明确要求修改。

验收标准：<从任务清单复制>
验证命令：<命令>

先给出不超过 8 条的实施计划，然后直接实现、运行测试并汇报结果。
```

## 2. 里程碑与关键路径

```text
M0 工程骨架
  → M1 虚拟显示 PoC
    → M2 本地采集与编码
      → M3 HarmonyOS 解码
        → M4 端到端扩展桌面
          → M5 输入与恢复
            → M6 发布与兼容
```

| 里程碑 | 目标 | Go 条件 |
|---|---|---|
| M0 | 工程、协议和 CI 可运行 | Mac/Harmony 工程均能构建，协议测试通过 |
| M1 | macOS 创建真正扩展屏 | 系统显示设置出现独立屏，窗口可拖入，销毁无残留 |
| M2 | 本地输出可解码 H.264 | 60 fps 采集，输出测试码流可被标准解码器播放 |
| M3 | Harmony 真机硬解码 | 测试向量连续运行 30 分钟，无不可恢复错误 |
| M4 | 端到端显示 | 1920×1200/60 fps，P50 延迟不高于 100 ms |
| M5 | 可交互、可恢复 | 输入可用，断网/睡眠/重连恢复达到门槛 |
| M6 | 可发布 Beta | 兼容矩阵、权限、签名、公证和诊断闭环 |

## 3. P0：工程基础

### T001｜建立 Monorepo 工程骨架

- 优先级：P0
- 依赖：无
- 目标：创建设计文档规定的目录、macOS Swift Package/Xcode 工程、HarmonyOS 工程和 shared 协议目录。
- 允许修改：仓库根目录、`macos/`、`harmony/`、`shared/`、CI 配置。
- 输出：可构建的空 App、基础测试 Target、格式化和 lint 配置。
- 验收：
  - macOS Debug 构建成功；
  - HarmonyOS 示例页面可在真机启动；
  - shared 测试向量目录可被两端测试读取；
  - CI 不需要私有证书即可执行单元测试。

### T002｜定义共享协议 v1

- 优先级：P0
- 依赖：T001
- 目标：定义 ClientHello、ServerReady、错误、输入事件、关键帧请求及二进制视频帧头。
- 允许修改：`shared/protocol/`、两端 protocol model、协议测试。
- 输出：协议说明、JSON Schema 或等价模型、黄金测试向量。
- 验收：
  - Swift 与 Harmony C++ 能解析同一组 hello/ready/error 测试向量；
  - 视频帧头能往返编码，拒绝错误 magic、超长 payload 和截断数据；
  - 未知控制消息可忽略；
  - 缺失可选字段使用明确默认值。

### T003｜建立统一错误与日志模型

- 优先级：P1
- 依赖：T001
- 目标：实现设计文档中的错误码、sessionId、generation 和 JSON Lines 日志。
- 输出：`SessionError`、`LogEvent`、日志脱敏器和测试。
- 验收：
  - 所有错误可映射为稳定字符串错误码；
  - 日志中不存在原始 IP、用户路径和完整设备 UUID；
  - release 构建默认关闭帧级 debug 日志。

## 4. P1：CGVirtualDisplay 核心

### T101｜创建 PrivateAPIShim

- 优先级：P0
- 依赖：T001
- 设计章节：4
- 目标：建立独立 Target，封装私有头和 Objective-C runtime 能力探测。
- 允许修改：`macos/VirtualDisplayCore/PrivateAPIShim/` 及其测试。
- 禁止修改：Capture、Codec、Transport、UI。
- 输出：`VirtualDisplayCapabilityReport` 和可注入的 runtime checker。
- 验收：
  - 私有类名只出现在 Shim Target；
  - 类或 selector 缺失时返回 `VD_CAPABILITY_MISSING`；
  - 测试可通过 fake runtime 模拟缺失组合；
  - 不使用 `fatalError`、`!` 强制解包或未检查的 `objc_msgSend`。

### T102｜实现 VirtualDisplaySpec 与身份生成

- 优先级：P0
- 依赖：T101
- 设计章节：5
- 目标：实现规格校验、stable serial、方向隔离、vendor/product 常量和冲突检查。
- 输出：纯 Swift 数据模型和单元测试。
- 验收：
  - 同一 deviceId 在重复运行时 serial 完全一致；
  - 横竖方向 serial 不同；
  - 非法尺寸、奇数编码尺寸、scale 非 2 和 refresh 非 60 被拒绝；
  - 10,000 个随机 UUID 不发生测试碰撞；
  - serial 永不为 0。

### T103｜实现虚拟显示创建与销毁 PoC

- 优先级：P0
- 依赖：T101、T102
- 设计章节：4、5、6
- 目标：创建 2560×1600 framebuffer、1280×800 logical、60 Hz、2× HiDPI 显示器并返回 displayID。
- 输出：`CGVirtualDisplayProvider`、最小诊断 UI 和真机测试说明。
- 验收：
  - macOS 显示设置出现独立显示器；
  - 可将 TextEdit 窗口拖入；
  - 显示器不是镜像集合成员；
  - stop 后 5 秒内从在线显示列表消失；
  - 连续创建/销毁 50 次无崩溃、无永久残留；
  - apply 失败时不会保留半初始化对象。

### T104｜实现显示器重配置观察器

- 优先级：P0
- 依赖：T103
- 设计章节：7
- 目标：封装 `CGDisplayRegisterReconfigurationCallback`，以 AsyncStream 或 actor-safe 回调输出事件。
- 验收：
  - add/remove/mode-change 事件包含 displayID 和 flags；
  - observer 释放后注销 callback；
  - C callback 不直接访问已释放 Swift 对象；
  - 事件可以按 session generation 过滤。

### T105｜实现 HiDPI 和扩展模式维护

- 优先级：P0
- 依赖：T103、T104
- 设计章节：7.2、7.3
- 目标：选择 2× 模式、解除意外镜像，并在系统异步恢复旧配置后重新校正。
- 验收：
  - 当前 mode 满足 `pixelWidth = width × 2`；
  - 手工切换到低分辨率后，watchdog 能检测并恢复；
  - 虚拟屏被加入镜像集合后能恢复为扩展；
  - 不永久改写其他物理显示器配置；
  - 无目标模式时返回 `VD_HIDPI_MODE_MISSING`。

### T106｜实现排列位置持久化

- 优先级：P1
- 依赖：T103、T104
- 设计章节：7.4
- 目标：按 deviceId 和 orientation 保存实际 origin，并在创建后短窗口内恢复。
- 验收：
  - 用户将虚拟屏拖到 Mac 左侧，重连后仍位于左侧；
  - 系统吸附后保存的是实际 origin；
  - 接收端分辨率变化时按中心位置转换并接受系统吸附；
  - 不读取或修改其他显示器的持久化记录。

### T107｜实现创建/枚举竞态恢复

- 优先级：P0
- 依赖：T103、T104、T201
- 设计章节：7.1
- 目标：等待 `SCShareableContent` 出现目标 displayID，支持取消、15 秒超时和释放后重建。
- 验收：
  - 通过 fake provider 模拟 0.1–12 秒延迟均能正确完成；
  - 超时返回 `VD_ENUMERATION_TIMEOUT`；
  - stop 能立即取消等待；
  - 旧 generation 的迟到结果不能启动 capture；
  - 重建前确认旧 display 已释放，不复用仍注册的 serial。

## 5. P2：采集与编码

### T201｜实现 ScreenCaptureKit CaptureService

- 优先级：P0
- 依赖：T001
- 设计章节：8
- 目标：按 displayID 枚举 `SCDisplay`、创建 `SCStream` 并输出有效 CVPixelBuffer。
- 验收：
  - 只按 displayID 绑定；
  - 过滤无效/不完整帧；
  - queueDepth 可配置且范围受限；
  - stop 幂等并等待 capture 停止；
  - 缺少屏幕录制权限返回 `CAP_PERMISSION_DENIED`；
  - 采集回调不执行网络 I/O。

### T202｜实现 VideoToolbox H.264 EncoderService

- 优先级：P0
- 依赖：T201
- 设计章节：9
- 目标：实时 H.264 编码，关闭重排序，支持强制 IDR 和运行时码率更新。
- 验收：
  - 编码测试帧可由 ffmpeg/标准解码器解码；
  - IDR 前包含 SPS/PPS；
  - 输出统一为 Annex B；
  - 编码队列不超过 2 帧；
  - invalidate 后迟到 callback 被忽略；
  - 记录 encode p50/p95。

### T203｜实现 Capture → Encoder 背压

- 优先级：P0
- 依赖：T201、T202
- 目标：将采集和编码串联，队列积压时丢旧帧并强制下一关键帧。
- 验收：
  - 人工降低编码速度时内存保持有界；
  - 丢帧后下一个发送帧为可独立解码的 IDR；
  - ScreenCaptureKit callback queue 不阻塞；
  - 指标区分 capture drop、encode drop 和 send drop。

### T204｜生成媒体测试向量

- 优先级：P0
- 依赖：T202
- 目标：生成 1280×800、1920×1200 的 H.264 Annex B 测试向量及帧元数据。
- 验收：
  - 测试向量纳入版本控制且体积受控；
  - 每个向量记录 codec、profile、width、height、fps 和 SHA-256；
  - Harmony 解码测试和 Mac 回归测试使用同一份向量。

## 6. P3：传输与 HarmonyOS 解码

### T301｜实现控制通道

- 优先级：P0
- 依赖：T002
- 设计章节：10
- 目标：完成长度前缀 JSON、握手、heartbeat、requestKeyFrame 和结构化错误。
- 验收：
  - 控制消息上限 64 KiB；
  - 半包、粘包、断包均能正确处理；
  - 未知消息不导致断开；
  - protocolVersion 不兼容时返回 `NET_PROTOCOL_MISMATCH`；
  - heartbeat 超时触发连接状态变更。

### T302｜实现视频 TCP 通道

- 优先级：P0
- 依赖：T002、T202
- 目标：发送/接收固定二进制头和 Annex B payload，与控制通道完全分离。
- 验收：
  - 支持半包和连续帧解析；
  - payload 超过 16 MiB 时断开并报告协议错误；
  - TCP_NODELAY 生效；
  - 发送队列按 2 帧/8 MiB 限制；
  - 网络变慢时不拖高 capture/encode 队列。

### T303｜实现 Harmony Native FrameParser

- 优先级：P0
- 依赖：T002
- 目标：在 C++ 层增量解析帧头、边界和 Annex B payload。
- 验收：
  - fuzz 测试覆盖截断、随机字节、超长和错误 magic；
  - 解析器不发生越界、无限分配和死循环；
  - 旧 sessionId 或 sequence 回退可检测；
  - 解析线程不进入 ArkTS UI 主线程。

### T304｜实现 Harmony H.264 Surface Decoder

- 优先级：P0
- 依赖：T204、T303
- 设计章节：11
- 目标：使用 OH_VideoDecoder 将测试向量输出至 XComponent/NativeWindow。
- 验收：
  - 1920×1200/60 fps 测试向量连续播放 30 分钟；
  - Surface 重建能安全重建 decoder；
  - 输入积压时丢弃到 IDR 并请求关键帧；
  - decoder fatal error 返回 `DECODER_FATAL`；
  - 不执行 CPU 侧 YUV→RGB 全帧转换。

### T305｜完成端到端扩展桌面 PoC

- 优先级：P0
- 依赖：T103、T107、T203、T301、T302、T304
- 目标：连接 HarmonyOS 平板后创建虚拟屏，并显示该虚拟桌面。
- 验收：
  - macOS 系统显示设置出现独立显示器；
  - 窗口可拖入平板并实时显示；
  - 1920×1200/60 fps 良好网络下接收 ≥55 fps；
  - 30 分钟无不可恢复断流；
  - P50 端到端延迟 ≤100 ms；
  - 断开后 5 秒内虚拟显示器消失。

## 7. P4：会话、权限与输入

### T401｜实现 SessionCoordinator 状态机

- 优先级：P0
- 依赖：T103、T201、T202、T301
- 设计章节：6、13、14
- 目标：以 actor 实现状态转换、generation、取消、超时和统一清理。
- 验收：
  - 状态转换表具有单元测试；
  - stop 在所有中间状态都能完成；
  - 旧 callback 不能让 stopped session 重新进入 streaming；
  - 任一子组件失败都按统一顺序清理；
  - failed 状态无虚拟显示器强引用。

### T402｜实现屏幕录制权限流程

- 优先级：P0
- 依赖：T201、T401
- 目标：权限预检、用户触发请求、设置引导和授权后恢复。
- 验收：
  - App 启动时不无上下文弹权限；
  - 未授权不会创建长期残留虚拟屏；
  - 授权后无需重启即可重新尝试；
  - 签名身份稳定时升级不重复丢失授权。

### T403｜实现 macOS InputInjector

- 优先级：P1
- 依赖：T301、T401
- 设计章节：12
- 目标：映射归一化坐标并注入 move/down/up/drag/scroll。
- 验收：
  - 网络降分辨率不影响点击位置；
  - 虚拟屏位于主屏左/右/上/下时坐标正确；
  - 断开时补发 mouseUp；
  - 缺少辅助功能权限时不注入事件；
  - 菜单、拖拽和滚动基本场景通过人工测试。

### T404｜实现 Harmony 触控手势协议

- 优先级：P1
- 依赖：T002、T301、T403
- 目标：把单指、拖拽和双指滚动转换为协议事件。
- 验收：
  - 每个事件带 sessionId 和递增 sequence；
  - 超出画面区域坐标被 clamp；
  - 应用前后台切换会发送 cancel/up；
  - 触控采样不会阻塞渲染线程。

## 8. P5：可靠性、体验与发布

### T501｜实现断线与快速重连

- 优先级：P0
- 依赖：T401
- 目标：短暂断线保留虚拟屏最多 10 秒，重连后重建网络/编码并强制 IDR。
- 验收：
  - 1–5 秒断网后 ≤5 秒恢复画面；
  - 超过 10 秒释放虚拟屏；
  - 重连后首个可显示帧为 IDR；
  - 100 次断线循环无 zombie display。

### T502｜实现睡眠唤醒恢复

- 优先级：P0
- 依赖：T401、T501
- 目标：监听 workspace 和 display 事件，唤醒后全量校验并按需重建。
- 验收：
  - 10 次睡眠唤醒均可重新进入 streaming；
  - 不重复创建同 serial 显示器；
  - SCK/encoder 旧对象均被失效；
  - 失败时给出可操作错误而非无限重试。

### T503｜实现诊断面板与导出

- 优先级：P1
- 依赖：T003、T401
- 目标：显示 capability、displayID、mode、fps、bitrate、RTT、队列和最近错误。
- 验收：
  - 可执行创建/枚举/销毁测试；
  - 导出文件经过脱敏；
  - 用户可复制错误码；
  - 指标采集本身不导致明显掉帧。

### T504｜建立 macOS 兼容矩阵自动测试

- 优先级：P0
- 依赖：T103、T107、T401
- 目标：在可用 Mac runner 上执行 capability、create、enumerate、capture、destroy 冒烟测试。
- 验收：
  - 测试输出 OS build、芯片和阶段耗时；
  - 失败自动生成兼容清单候选变更；
  - 新 macOS Beta 不自动标记 supported；
  - blocked build 无法进入创建路径。

### T505｜签名、公证与独立分发验证

- 优先级：P0
- 依赖：M5 完成
- 目标：验证 Developer ID 签名、公证、安装、升级和卸载流程。
- 验收：
  - 干净机器安装可启动；
  - Gatekeeper 不阻断；
  - 升级保持 bundle id 和权限身份；
  - 卸载后无 LaunchAgent、helper 或虚拟屏残留；
  - 明确记录私有 API 对公证/分发的实际测试结果。

## 9. P6：MVP 后优化

| 任务 | 内容 | 依赖 |
|---|---|---|
| T601 | UDP/QUIC 视频通道，保留可靠控制通道 | T302、T305 |
| T602 | 基于 RTT、丢包、队列的动态码率/分辨率 | T601、T503 |
| T603 | USB 网络接口识别和 Wi-Fi↔USB 无缝迁移 | T501 |
| T604 | 横竖屏方向切换和虚拟屏安全重建 | T401、T502 |
| T605 | HEVC 能力协商和硬编硬解 | T202、T304 |
| T606 | 多设备、多虚拟屏和 serial 冲突管理 | T102、T401 |
| T607 | 独立游标 sprite/位置通道 | T301、T403 |
| T608 | 剪贴板、软键盘和快捷键 | T301、T403 |

这些任务不应进入首个端到端 PoC。只有 M5 稳定性指标达标后才能启动。

## 10. P7：局域网服务发现与安全连接

P7 在不改变现有媒体和输入协议的前提下，消除 HarmonyOS 端固定 IP 配置。发现信息只用于定位候选服务，不能替代已有配对信任。

### T701｜发布 Second Display Bonjour 服务

- 优先级：P0
- 依赖：T301、T401、T501
- 设计章节：6、10、14、16
- 目标：macOS 服务进入监听态后，通过 mDNS/DNS-SD 发布 `_seconddisplay._tcp` 服务，并使广播与当前 session generation 同生共灭。
- 允许修改：`macos/TransportCore/`、`macos/P3HostCore/`、macOS App 配置及对应测试。
- 禁止修改：PrivateAPIShim、Capture、Codec、共享媒体/输入协议。
- TXT 字段：`pv`、`vp`、`tls`、`fp`、`state`、`caps`；不得发布证书、私钥、设备 UUID 或配对令牌。
- 验收：
  - 只在控制、视频监听器均 ready 后发布服务；
  - stop、连接建立、恢复重建和 generation 失效时撤销旧广播；
  - TXT 指纹采用规范化 SHA-256，端口和协议版本有边界校验；
  - 广播注册失败返回项目错误码，不使用 `fatalError` 或强制解包；
  - 现有 `accept()` 调用保持兼容。
- 验证命令：`swift test`

### T702｜HarmonyOS 主动发现与服务列表

- 优先级：P0
- 依赖：T701
- 设计章节：6、11、14、16
- 目标：HarmonyOS 使用 mDNS 发现、解析、去重并展示同一局域网内的 Second Display 服务，用户可点击已配对服务连接。
- 允许修改：`harmony/entry/src/main/ets/`、HarmonyOS 清单和对应测试。
- 禁止修改：Native decoder、渲染、媒体帧协议。
- 验收：
  - 页面出现后自动发现，离开页面、开始连接或停止时注销回调并停止搜索；
  - `serviceFound` 异步解析携带 discovery generation，旧回调不能重新加入列表；
  - `serviceLost` 能移除项目，多网卡/重复回调按证书指纹和端点去重；
  - 只接受 `pv=1`、TLS、有效控制/视频端口和可用主机地址；
  - 未配对或指纹不匹配的服务不可静默连接；
  - 保留手动 IP 输入和 10 秒原端点快速重连。
- 验证命令：`hvigorw assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon`

### T703｜动态地址证书固定

- 优先级：P0
- 依赖：T702
- 设计章节：10、16
- 目标：允许服务 IP 变化，同时继续以已配对证书 SHA-256 固定身份，不能把 mDNS TXT 当作信任根。
- 允许修改：HarmonyOS 网络 worker、配对信息桥接和对应测试。
- 禁止修改：TLS 最低版本、服务端私钥格式、媒体/输入协议。
- 验收：
  - 两条 TLS 通道在发送任何应用数据前读取远端证书；
  - 控制、视频证书必须彼此一致，并同时匹配本地已配对证书和发现 TXT 指纹；
  - 证书不匹配立即关闭连接并返回项目错误码；
  - 手动地址连接也执行本地证书固定；
  - 动态 IP 不依赖证书中的旧 IP SAN。
- 验证命令：HarmonyOS HAP 构建及两台设备换网真机验证。

### T704｜发现可靠性与首次配对

- 优先级：P1
- 依赖：T701、T702、T703
- 设计章节：10、14、16
- 目标：补齐多 Mac、网络切换、AP 禁止组播时的体验，并为未知服务增加用户确认的 PIN/二维码首次配对。
- 允许修改：`macos/P3HostCore/`、macOS App 配对界面、`harmony/entry/src/main/ets/` 及对应测试。
- 禁止修改：PrivateAPIShim、Capture、Codec、媒体/输入协议、TLS 最低版本。
- 验收：
  - 多个 Mac 可稳定出现且名称冲突不会误连；
  - Wi-Fi/USB 网络切换后重新解析地址，不静默切换到不同指纹主机；
  - 路由器禁用 mDNS 时仍可使用手动地址；
  - PIN/二维码确认成功前不保存或信任新证书；
  - 移除设备后吊销本地长期信任。
- 验证命令：`swift test -c release`、HarmonyOS HAP 构建，以及多 Mac、换网、扫码/校验码和移除信任真机验证。

## 11. AI Coding 评审清单

每个任务合并前逐项回答：

- [ ] 修改是否严格限制在任务允许目录？
- [ ] 是否在 Shim 之外出现私有 API 类名？
- [ ] 是否新增强制解包、`fatalError` 或不可取消的无限循环？
- [ ] 异步 callback 是否检查 session generation？
- [ ] stop/cleanup 是否幂等？
- [ ] 队列和输入长度是否有硬上限？
- [ ] 是否新增结构化错误码和必要指标？
- [ ] 是否包含单元测试、集成测试或明确的真机步骤？
- [ ] 是否实际运行构建和测试命令？
- [ ] 是否更新设计文档或 ADR（如改变架构决策）？

## 12. 建议的第一轮执行顺序

第一轮只执行以下任务：

```text
T001 → T002
  ↓
T101 → T102 → T103 → T104 → T105
  ↓                         ↓
T201 → T107 → T202 → T203 → T204
  ↓
T303 → T304
  ↓
T301 → T302 → T305
```

T305 通过后再开始 T401 及后续产品化任务。这样可以尽早确认三个最高风险点：私有 API 是否能创建稳定扩展屏、ScreenCaptureKit 是否能可靠捕获、HarmonyOS 目标平板是否能持续硬解码。
