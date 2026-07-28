---
name: second-display-validation
description: 对 Second Display 仓库的每次改动执行 Swift、共享协议、HarmonyOS 构建、原生 C++ 和真机质量门禁。修改源码、测试、构建配置、运行时资源、媒体/输入/网络/会话行为、性能、打包或发布流程时，以及用户要求测试、验证、安装、压力测试、测量 FPS/延迟或完成功能验收时，都应使用本技能。运行时改动只有在当前 HarmonyOS 构建已安装到真机且实测指标达到门槛后才能完成验收。
compatibility: 需要 macOS、Swift 6.1、Python 3、CMake、DevEco Studio 或 HarmonyOS 命令行工具、HDC；运行时验收还需要一台已授权的 HarmonyOS 真机
---

# Second Display 项目验证

使用本流程把“测试通过”转化为可复现的验收证据。本项目是跨两台设备的实时系统，只运行
主机单元测试无法证明画面流畅度、输入跟手性、重新连接能力或长时间稳定性。

## 1. 判断改动类型

先检查 `git status --short` 和实际变更文件，再选择验证门禁。

| 改动类型 | 必须执行的门禁 |
|---|---|
| 仅文档、注释或网站内容，不改变可执行产物 | 静态差异检查，以及相关链接和内容检查 |
| Swift、共享协议、macOS 应用、构建或运行时资源 | 自动化门禁 + 120 秒真机媒体门禁 |
| HarmonyOS ArkTS/C++、清单、资源或构建配置 | 自动化门禁 + 安装当前 HAP + 120 秒真机媒体门禁 |
| 采集、编码、传输、解码、显示或 FPS 自适应 | 自动化门禁 + 媒体门禁 + 交互门禁 + 5 分钟长稳门禁 |
| 输入、手势、光标、方向、生命周期或恢复 | 自动化门禁 + 交互/生命周期清单 + 5 分钟长稳门禁 |
| 发布、打包、版本或签名流程 | 完整发布自动化门禁 + DMG 验证 + 本地签名 HAP 构建 + 5 分钟真机门禁 |

如果改动同时符合多行，执行这些门禁的并集。不要因为改动看起来很小就降低门槛：时序和
生命周期回归经常跨越多个模块。

## 2. 阅读验收矩阵

执行真机测试前，先阅读
[references/acceptance-matrix.md](references/acceptance-matrix.md)。其中定义了当前非回归
门槛、接近原生体验的目标门槛、人工场景以及必须汇报的证据。

非回归门禁用于保护当前已经真机验证的最佳基线；接近原生的目标更严格，未达到时仍要作为
差距报告。只通过基线门禁时，不得宣称已经达到更高目标。

## 3. 执行自动化门禁

在仓库根目录运行：

```sh
.agents/skills/second-display-validation/scripts/run_automated_checks.sh
```

验证发布候选版本时运行：

```sh
.agents/skills/second-display-validation/scripts/run_automated_checks.sh --release
```

脚本会验证共享测试向量、Swift 测试、release 版 `P3PoCHost`、Harmony 原生测试、
HarmonyOS HAP、私有 API 隔离、技能指标分析器和空白字符错误。`--release` 还会运行
完整的 Swift release 测试套件。

如果 DevEco 命令行工具不在 `PATH` 中，将 `SD_HVIGORW`、`SD_CMAKE` 和 `SD_CTEST`
设置为对应可执行文件的绝对路径。在 macOS 上，脚本也会自动查找 DevEco Studio 的标准
安装位置。排查构建问题时不得打印或复制签名材料。

## 4. 执行强制真机门禁

确认 macOS 已获得录屏权限，Mac 和 HarmonyOS 设备位于同一可达局域网，并且设备已经在
HDC 中授权。关闭正常运行的 Second Display Mac 应用，避免它与 `P3PoCHost` 争用服务端口。

执行默认的当前构建真机门禁：

```sh
.agents/skills/second-display-validation/scripts/run_device_validation.sh
```

脚本会：

1. 构建已签名的 debug HAP 和 release 版 `P3PoCHost`；
2. 使用 `hdc install -r` 安装当前 HAP；
3. 启动 Ability 和全屏动态测试源；
4. 通过 `uitest dumpLayout` 按控件文本定位界面，自动接受应用隐私提示、触发一次扫描，
   并点击已配对服务的“连接”按钮；坐标来自实时布局树，不写死屏幕分辨率；
5. 同时确认主机已经编码非零帧且 HarmonyOS 接收 FPS 非零，只有真实视频流就绪后才开始
   计算请求的 120/300 秒采样时长；
6. 采集主机指标、RenderService FPS 记录、Surface 状态、屏幕模式、设备 CPU/内存、
   应用包元数据和命令元数据；
7. 将布局树、自动点击记录和连接等待结果随其他证据写入
   `.build/validation/<timestamp>/`；
8. 未建立真实流、连接中途退出或任一自动指标未达到门槛时，以非零状态退出。

自动化不会点击“配对”、不会输入校验码，也不会自动信任陌生 Mac。测试设备第一次使用时，
先人工完成一次安全配对；之后每次安装和启动都由脚本自动扫描并连接。如果只发现未配对服务，
脚本返回 `NET_PAIRING_REQUIRED`，不会继续生成没有真实连接的性能采样。

使用 `SD_HDC`、`SD_HVIGORW` 或 `SD_DEVICE_ID` 可以覆盖自动发现结果。`--no-install`
只能用于诊断；由于被测应用可能不是当前源码对应的产物，未安装当前 HAP 的结果不能用于
源码改动验收。仅在排查界面自动化本身时可使用 `--manual-ui` 或
`SD_UI_AUTOMATION=0`，但仍必须在超时前建立真实视频流，否则门禁失败。

## 5. 执行改动对应的真机场景

输入或桌面交互相关改动运行：

```sh
.agents/skills/second-display-validation/scripts/run_device_validation.sh \
  --scenario interaction --duration 180
```

测试期间执行脚本输出的交互清单，并在生成的 `operator-checklist.md` 中记录每一项。
即使自动化指标通过，只要存在未勾选的人工项目，验收仍然处于待完成状态。

需要长稳验证时运行：

```sh
.agents/skills/second-display-validation/scripts/run_device_validation.sh --long
```

当前长稳门禁为 300 秒。发布、性能、生命周期、恢复或输入改动不得缩短该时长。更短的
探索性测试可以用于迭代，但不能作为正式验收证据。

生命周期和恢复相关改动还必须执行验收矩阵中的人工序列：旋转屏幕、切换后台/前台、
停止并重启主机、断开并恢复一次 Wi-Fi，以及验证重新连接后界面不会永久停留在“连接中”。

## 6. 判定结果

读取真机脚本生成的两个文件：

- `summary.md`：便于人工阅读的门槛、实测值、通过/失败结果和目标差距；
- `metrics.json`：机器可读的实测指标和原始证据路径。

按以下规则处理结果：

- `PASS`：自动化指标通过，但仍要检查所选场景是否包含未完成的人工项目。
- `FAIL`：修复或解释回归，保留证据，并重新执行完整的适用门禁。
- `INCOMPLETE`：缺少设备、权限、配对、当前构建安装或人工确认。

不得用平均值掩盖尾延迟回归。除了平均 FPS，还必须报告 P95/P99 和稳定窗口中的最差值。
只允许丢弃分析器固定的前两个预热样本，不得人工删除异常样本。

## 7. 完成报告

报告必须包含：

- commit/worktree 标识和变更文件范围；
- 实际执行的完整命令及退出状态；
- 设备标识/型号、系统、应用版本、已安装 HAP 路径、场景和持续时间；
- 实际显示 FPS、帧间隔 P95/P99、源/采集/编码/接收 FPS、VideoToolbox P95、
  解码输出 P95、发送 P95、总丢帧率和活动刷新率；
- 自动化结果、人工清单结果、目标差距和证据目录；
- 所有跳过项目及原因。

如果必须执行的门禁无法运行或指标未达到门槛，应说明“实现已完成，但尚未通过验收”，
不得将任务标记为完成。
