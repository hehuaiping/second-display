# Second Display

[中文](README.md) · [English](README.en.md)

Second Display 是一个将 HarmonyOS NEXT 手机或平板变成 macOS 扩展屏幕的实验性项目。
macOS 端创建真正的扩展桌面、采集并硬件编码画面；HarmonyOS 端通过硬件解码器直接渲染，
同时把触控、滚动和多指手势回传给 Mac。

> 项目使用 macOS 私有的 `CGVirtualDisplay` 能力。它适合研究、个人使用和受控环境，
> 但系统升级可能导致兼容性变化，Apple 公证也不保证接受包含私有 API 的发行包。

## 能做什么

- **把 HarmonyOS 设备作为扩展屏幕**：不是镜像投屏，Mac 可以把窗口拖到独立虚拟显示器。
- **匹配设备原生分辨率**：接收端上报系统显示尺寸，不再固定为 1920×1200。
- **横竖屏切换**：应用默认横屏启动，旋转后安全重建对应方向的虚拟显示器。
- **60/90/120 Hz 协商**：根据 Mac、显示面板和硬件解码能力选择双方都支持的刷新率。
- **H.264/HEVC 硬编硬解**：macOS 使用 VideoToolbox，HarmonyOS 使用 AVCodec 和
  XComponent Surface；能力不足时自动回退 H.264。
- **低延迟桌面传输**：ScreenCaptureKit 采集、最新帧优先队列、禁止 B 帧、IDR 恢复、
  Direct Surface Rendering 和主动丢弃过期帧。
- **网络自适应**：结合 RTT、发送队列、解码队列、掉帧和实时渲染 FPS 动态调整码率与分辨率。
- **静态桌面优化**：利用 `dirtyRects` 区分静止/活动内容，降低静止画面的编码负载。
- **触控控制**：支持单指移动/点击/拖动、双指滚动，以及 3/4/5 指滑动和捏合手势。
- **可靠恢复**：网络切换、短暂断连、Surface 重建、睡眠唤醒和方向变化均使用 generation
  隔离，旧异步回调不能复活已经结束的会话。
- **可安装的 Mac 应用**：DMG 应用内置服务生命周期界面，可启动/停止服务并查看 IP、
  连接状态、配对信息、分辨率、帧率、码率、RTT 和掉帧。

## 工作原理

```text
macOS 虚拟显示器
  → ScreenCaptureKit / IOSurface
  → VideoToolbox H.264 或 HEVC
  → 加密视频通道
  → HarmonyOS AVCodec
  → XComponent Native Surface

HarmonyOS 触控/手势
  → TLS 1.3 控制通道
  → macOS 公共输入事件 API
```

控制和视频使用独立连接，避免视频拥塞阻塞输入。当前 HarmonyOS API 21 真机运行时使用
TLS/TCP 视频通道；仓库已经包含 QUIC 能力协商、分片、乱序重组和丢帧恢复基础设施，
但只有双方都具备可用 QUIC API 时才会启用。

## 当前状态和限制

- macOS 14 或更高版本，Apple Silicon 为主要验证平台。
- HarmonyOS NEXT 工程当前目标版本为 6.0.1 (API 21)。
- 当前 DMG 界面一次管理一个活动接收端；底层已经支持持久设备身份、方向隔离和跨
  Provider serial 冲突检测。
- HarmonyOS 接收端当前默认连接 `192.168.43.9:52340/52341`，Mac IP 变化时需要同步修改
  接收端配置；后续可增加服务发现或可编辑地址。
- 本地 DMG 默认使用 ad-hoc 签名。应用二进制更新后，macOS 可能要求重新授予屏幕录制和
  辅助功能权限。稳定发行应使用 Developer ID 签名并实际完成公证测试。
- 剪贴板、软键盘和快捷键通道尚未实现；独立光标侧信道代码保留，但默认使用原始 Mac 光标。

详细的 P6 能力和运行时门控见
[P6 实现状态](docs/P6_IMPLEMENTATION_STATUS.md)。

## 快速开始

### 1. 启动 macOS 服务

1. 构建或安装 `Second Display.app`。
2. 在“系统设置 → 隐私与安全性”中允许**屏幕录制**；需要触控 Mac 时再允许**辅助功能**。
3. 打开应用，确认显示的 Mac IP 和配对证书信息。
4. 点击 **Start Service**。

### 2. 连接 HarmonyOS 设备

1. 使用 DevEco Studio 或 `hdc` 安装已签名 HAP。
2. 确保 HarmonyOS 设备与 Mac 处于同一可达网络。
3. 打开 Second Display，点击**连接 Mac**。
4. 连接成功后控制面板会自动隐藏，设备显示 macOS 扩展桌面。

停止服务时，Mac 应用会取消采集、编码和网络任务，并释放虚拟显示器。

## 构建与测试

### macOS

需要 Xcode、Swift 6.1 和 macOS SDK：

```sh
swift build
swift test
python3 tools/validate_shared_vectors.py
```

生成本地 DMG：

```sh
tools/package_macos_dmg.sh
tools/verify_macos_distribution.sh
```

生成 Developer ID 签名包时设置：

```sh
MACOS_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="second-display-notary" \
tools/package_macos_dmg.sh
```

### HarmonyOS

```sh
cd harmony
hvigorw assembleHap --mode module \
  -p product=default \
  -p module=entry@default \
  -p buildMode=debug \
  --no-daemon
```

签名配置只保存在开发者本机，不能提交到 Git。更多命令见
[HarmonyOS 构建说明](harmony/README.md)。

## 目录结构

| 目录 | 内容 |
|---|---|
| `macos/VirtualDisplayCore` | 私有 API Shim、虚拟显示器身份、模式和排列管理 |
| `macos/CapturePipeline` | ScreenCaptureKit、VideoToolbox、背压和码率控制 |
| `macos/TransportCore` | TLS/QUIC 抽象、通道、心跳、网络自适应 |
| `macos/P3HostCore` | 服务生命周期、会话恢复、输入和诊断 |
| `macos/SecondDisplayMacApp` | DMG 中的 SwiftUI 主机应用 |
| `harmony/entry` | ArkUI 页面、网络 Worker、AVCodec C++ 解码器 |
| `shared/` | 协议文档、JSON Schema 和跨平台测试向量 |
| `tools/` | DMG、证书、兼容性和协议验证脚本 |
| `docs/` | 技术设计、编码任务和真机测试记录 |

## 安全和隐私

- 控制通道使用 TLS 1.3；视频通道同样经过认证加密。
- 配对私钥和签名材料仅保存在开发者本机，不进入应用包或 Git 仓库。
- 控制消息、视频帧、队列和分片均有硬上限。
- 日志不记录视频帧、键盘文本、私钥或完整设备标识。
- 所有失败返回项目错误码，不使用 `fatalError` 终止进程。
- HarmonyOS 版隐私说明见
  [《Second Display 隐私政策》](docs/HarmonyOS_Privacy_Policy_ZH.md)。

## 进一步阅读

- [技术设计](docs/CGVirtualDisplay_Technical_Design.md)
- [AI 编码任务清单](docs/AI_CODING_TASKS.md)
- [协议 v1](shared/protocol/PROTOCOL_V1.md)
- [P5 可靠性和发布](docs/P5_RELIABILITY_AND_RELEASE.md)
- [P6 实现状态](docs/P6_IMPLEMENTATION_STATUS.md)
