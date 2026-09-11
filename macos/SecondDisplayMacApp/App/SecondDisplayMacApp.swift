import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import P3HostCore
import SecondDisplayCore
import SwiftUI
import UniformTypeIdentifiers
import VirtualDisplayCore

@main
struct SecondDisplayMacApp: App {
    @NSApplicationDelegateAdaptor(SecondDisplayAppDelegate.self) private var appDelegate
    @StateObject private var model = HostServiceModel.shared

    var body: some Scene {
        WindowGroup {
            HostServiceView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class SecondDisplayAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        HostServiceModel.shared.cancelPairingInitialization()
        guard HostServiceModel.shared.isServiceActive else { return .terminateNow }
        Task {
            await HostServiceModel.shared.stopService()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct HostServiceView: View {
    @ObservedObject var model: HostServiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "display.2")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Second Display Mac 服务端")
                        .font(.title2.bold())
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.statusColor)
                            .frame(width: 9, height: 9)
                        Text(model.phaseLabel)
                            .font(.headline)
                    }
                }
                Spacer()
                Button("启动服务") {
                    Task { await model.startService() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.isServiceActive || !model.pairingReady || !model.screenCaptureAllowed
                )
                .help(
                    model.screenCaptureAllowed
                        ? "启动 Second Display 服务"
                        : "请先授予录屏权限，再启动服务"
                )
                Button("停止服务") {
                    Task { await model.stopService() }
                }
                .disabled(!model.isServiceActive)
            }

            Text(model.statusMessage)
                .foregroundStyle(model.phase == .failed ? Color.red : Color.secondary)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Toggle(
                    "自适应高刷新率（实验性）",
                    isOn: $model.adaptiveHighRefreshEnabled
                )
                .toggleStyle(.switch)
                .disabled(model.isServiceActive)
                Text("默认以 60 FPS 启动，仅在持续具备性能余量后提升刷新率。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .top, spacing: 12) {
                GroupBox("网络") {
                    DetailGrid(rows: [
                        ("Mac IP 地址", model.localIPAddress),
                        ("控制通道", "TCP/TLS 52340"),
                        ("视频通道", "TCP/TLS 52341"),
                    ])
                }
                GroupBox("连接") {
                    DetailGrid(rows: [
                        ("接收设备", model.deviceName),
                        ("显示器 ID", model.displayID),
                        ("已编码帧", model.encodedFrames),
                        ("已丢弃帧", model.droppedFrames),
                    ])
                }
            }

            GroupBox("诊断") {
                VStack(alignment: .leading, spacing: 10) {
                    DetailGrid(rows: [
                        ("系统能力", model.capabilitySummary),
                        ("传输模式", model.streamMode),
                        ("码率", model.currentBitrate),
                        ("RTT", model.networkRTT),
                        ("视频队列", model.videoQueueDepth),
                        ("恢复次数", model.recoveryCount),
                        ("最近错误", model.recentErrorCode),
                        ("自检结果", model.selfTestSummary),
                    ])
                    HStack {
                        Button("运行显示器自检") {
                            Task { await model.runDisplaySelfTest() }
                        }
                        .disabled(model.isServiceActive || !model.screenCaptureAllowed)
                        Button("导出诊断信息") {
                            model.exportDiagnostics()
                        }
                        Button("复制错误码") {
                            model.copyRecentErrorCode()
                        }
                        .disabled(model.recentErrorCode == "—")
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("权限") {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Label(
                            model.screenCaptureAllowed
                                ? "已授予录屏权限" : "需要录屏权限",
                            systemImage: model.screenCaptureAllowed
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(model.screenCaptureAllowed ? Color.green : Color.orange)
                        Spacer()
                        Button(model.screenCapturePermissionActionLabel) {
                            model.requestScreenCapturePermission()
                        }
                        .disabled(model.screenCaptureAllowed)
                    }
                    HStack(spacing: 12) {
                        Label(
                            model.accessibilityAllowed
                                ? "已允许触控操作" : "触控操作需要辅助功能权限",
                            systemImage: model.accessibilityAllowed
                                ? "checkmark.circle.fill" : "hand.tap.fill"
                        )
                        .foregroundStyle(model.accessibilityAllowed ? Color.green : Color.orange)
                        Spacer()
                        Button(model.accessibilityPermissionActionLabel) {
                            model.requestAccessibilityPermission()
                        }
                        .disabled(model.accessibilityAllowed)
                    }
                    Text(
                        "只有点击权限请求按钮后才会显示系统授权提示。打开系统设置前，"
                            + "应用会先向 macOS 注册录屏权限请求。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            }

            GroupBox("配对") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(
                            model.pairingStatusLabel,
                            systemImage: model.pairingStatusIcon
                        )
                        .foregroundStyle(model.pairingReady ? Color.green : Color.orange)
                        Spacer()
                        if model.pairingInitializing {
                            ProgressView()
                                .controlSize(.small)
                        } else if !model.pairingReady {
                            Button("重试") {
                                model.retryPairingIdentity()
                            }
                            if model.pairingRecoveryAvailable {
                                Button("重置身份") {
                                    model.pairingResetConfirmationPresented = true
                                }
                                .disabled(model.isServiceActive)
                            }
                        }
                        Text("TLS 1.3 · 已固定 CA")
                            .foregroundStyle(.secondary)
                    }
                    Text("证书 SHA-256 指纹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.certificateFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    HStack(alignment: .top, spacing: 16) {
                        if let image = model.pairingQRCode {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 128, height: 128)
                                .background(Color.white)
                                .accessibilityLabel("Second Display 配对二维码")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("请使用 HarmonyOS 应用扫描此二维码")
                                .font(.headline)
                            Text("验证码")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model.pairingVerificationCode)
                                .font(.system(.title3, design: .monospaced).bold())
                                .textSelection(.enabled)
                            Text("仅在接收端确认后才会保存信任关系。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(model.pairingLocation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in model.refreshPermissions()
        }
        .alert("重置配对身份？", isPresented: $model.pairingResetConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("重置并重新生成", role: .destructive) {
                model.resetPairingIdentity()
            }
        } message: {
            Text("旧证书将失效，所有已经配对的 HarmonyOS 设备都需要重新配对。")
        }
    }
}

private struct DetailGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Text(row.1)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

@MainActor
private final class HostServiceModel: ObservableObject {
    static let shared = HostServiceModel()

    @Published private(set) var phase: P3HostPhase = .stopped
    @Published private(set) var statusMessage = "服务已停止"
    @Published private(set) var localIPAddress = "不可用"
    @Published private(set) var deviceName = "等待接收设备连接"
    @Published private(set) var displayID = "—"
    @Published private(set) var encodedFrames = "0"
    @Published private(set) var droppedFrames = "0"
    @Published private(set) var pairingReady = false
    @Published private(set) var pairingInitializing = true
    @Published private(set) var pairingRecoveryAvailable = false
    @Published var pairingResetConfirmationPresented = false
    @Published private(set) var screenCaptureAllowed = false
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var screenCaptureRequestIssued = false
    @Published private(set) var accessibilityRequestIssued = false
    @Published private(set) var certificateFingerprint = "不可用"
    @Published private(set) var pairingLocation = ""
    @Published private(set) var pairingVerificationCode = "不可用"
    @Published private(set) var pairingQRCode: NSImage?
    @Published private(set) var capabilitySummary = "正在检测"
    @Published private(set) var streamMode = "—"
    @Published private(set) var currentBitrate = "—"
    @Published private(set) var networkRTT = "—"
    @Published private(set) var videoQueueDepth = "—"
    @Published private(set) var recoveryCount = "0"
    @Published private(set) var recentErrorCode = "—"
    @Published private(set) var selfTestSummary = "尚未运行"
    @Published var adaptiveHighRefreshEnabled = false {
        didSet {
            UserDefaults.standard.set(
                adaptiveHighRefreshEnabled,
                forKey: Self.adaptiveHighRefreshKey
            )
        }
    }

    private let service = P3HostService()
    private let screenCapturePermission = ScreenCapturePermissionController()
    private let pairingStore: PairingIdentityStore? = try? PairingIdentityStore.applicationDefault()
    private var credentials: PairingIdentityCredentials?
    private var pairingTask: Task<Void, Never>?
    private var pairingGeneration: UInt64 = 0
    private var latestGeneration: UInt64 = 0
    private var eventHistory: [P3HostEvent] = []
    private var latestSelfTest: P3DiagnosticSelfTestResult?
    private static let accessibilityPromptKey = "SecondDisplay.AccessibilityPromptIssued"
    private static let adaptiveHighRefreshKey = "SecondDisplay.AdaptiveHighRefreshEnabled"

    private init() {
        adaptiveHighRefreshEnabled = UserDefaults.standard.bool(
            forKey: Self.adaptiveHighRefreshKey
        )
        accessibilityRequestIssued = UserDefaults.standard.bool(
            forKey: Self.accessibilityPromptKey
        )
        localIPAddress = LocalNetworkInfo.preferredIPv4Address() ?? "不可用"
        refreshPermissions()
        schedulePairingReload()
        let capability = VirtualDisplayCapabilityProbe().report()
        let compatibility = SystemMacCompatibilityChecker().decision()
        let compatibilityLabel: String
        switch compatibility.status {
        case .supported: compatibilityLabel = "已支持"
        case .experimental: compatibilityLabel = "实验性支持"
        case .blocked: compatibilityLabel = "已阻止"
        }
        capabilitySummary =
            capability.supported
            ? "\(compatibilityLabel) · 系统构建 \(compatibility.osBuild) · 探测 v\(capability.probeVersion)"
            : "不支持 · 缺少 \(capability.missingClasses.count + capability.missingSelectors.count) 项能力"
    }

    var isServiceActive: Bool {
        switch phase {
        case .starting, .listening, .connected, .preparingDisplay, .streaming, .recovering, .stopping:
            return true
        case .stopped, .failed:
            return false
        }
    }

    var pairingStatusLabel: String {
        if pairingInitializing { return "正在初始化配对身份" }
        return pairingReady ? "配对身份已就绪" : "配对身份不可用"
    }

    var pairingStatusIcon: String {
        if pairingInitializing { return "hourglass.circle.fill" }
        return pairingReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
    }

    var phaseLabel: String {
        switch phase {
        case .stopped: "已停止"
        case .starting: "正在启动"
        case .listening: "等待连接"
        case .connected: "接收设备已连接"
        case .preparingDisplay: "正在准备显示器"
        case .streaming: "正在传输画面"
        case .recovering: "正在恢复"
        case .stopping: "正在停止"
        case .failed: "启动失败"
        }
    }

    var statusColor: Color {
        switch phase {
        case .streaming: .green
        case .starting, .listening, .connected, .preparingDisplay, .recovering, .stopping: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    var screenCapturePermissionActionLabel: String {
        screenCaptureRequestIssued ? "打开系统设置" : "请求录屏权限"
    }

    var accessibilityPermissionActionLabel: String {
        accessibilityRequestIssued ? "打开系统设置" : "启用触控操作"
    }

    func startService() async {
        guard !isServiceActive else { return }
        refreshPermissions()
        guard screenCaptureAllowed else {
            phase = .failed
            recentErrorCode = SessionErrorCode.capPermissionDenied.rawValue
            statusMessage =
                "CAP_PERMISSION_DENIED：请先在权限区域授予录屏权限"
            return
        }
        guard let credentials else {
            phase = .failed
            statusMessage = "NET_PROTOCOL_MISMATCH：配对身份不可用"
            return
        }
        deviceName = "等待接收设备连接"
        displayID = "—"
        encodedFrames = "0"
        droppedFrames = "0"
        streamMode = "—"
        currentBitrate = "—"
        networkRTT = "—"
        videoQueueDepth = "—"
        recoveryCount = "0"
        recentErrorCode = "—"
        let configuration = P3HostConfiguration(
            identityData: credentials.identityData,
            identityPassword: credentials.password,
            maximumFramesPerSecond: adaptiveHighRefreshEnabled ? 120 : 60,
            allowsAdaptiveHighRefreshRate: adaptiveHighRefreshEnabled,
            certificateFingerprint: credentials.fingerprint
        )
        await service.start(configuration: configuration) { [weak self] event in
            await self?.apply(event)
        }
    }

    func stopService() async {
        await service.stop()
    }

    func refreshPermissions() {
        screenCaptureAllowed = screenCapturePermission.preflight()
        accessibilityAllowed = AXIsProcessTrusted()
    }

    func requestScreenCapturePermission() {
        refreshPermissions()
        guard !screenCaptureAllowed else { return }
        // ad-hoc 应用更新后，TCC 可能移除旧代码身份的条目，但 UserDefaults 会继续保留。
        // 因此录屏请求只在当前进程内去重，每次新启动都先调用系统请求 API 完成注册。
        screenCaptureRequestIssued = true
        _ = screenCapturePermission.requestFromUserAction()
        refreshPermissions()
        if screenCaptureAllowed {
            statusMessage = "已授予录屏权限"
        } else {
            recentErrorCode = SessionErrorCode.capPermissionDenied.rawValue
            statusMessage =
                "CAP_PERMISSION_DENIED：请在系统设置中允许录屏，然后返回应用"
            openScreenRecordingSettings()
        }
    }

    func requestAccessibilityPermission() {
        refreshPermissions()
        guard !accessibilityAllowed else { return }
        guard !accessibilityRequestIssued else {
            openAccessibilitySettings()
            return
        }
        accessibilityRequestIssued = true
        UserDefaults.standard.set(true, forKey: Self.accessibilityPromptKey)
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refreshPermissions()
        if !accessibilityAllowed {
            recentErrorCode = SessionErrorCode.inputPermissionDenied.rawValue
            statusMessage =
                "INPUT_PERMISSION_DENIED：请在系统设置中允许辅助功能，以启用触控操作"
        }
    }

    func openScreenRecordingSettings() {
        openPrivacySettings(
            anchor: "Privacy_ScreenCapture",
            errorCode: .capPermissionDenied,
            failureDetail: "无法打开录屏权限设置"
        )
    }

    private func openAccessibilitySettings() {
        openPrivacySettings(
            anchor: "Privacy_Accessibility",
            errorCode: .inputPermissionDenied,
            failureDetail: "无法打开辅助功能权限设置"
        )
    }

    private func openPrivacySettings(
        anchor: String,
        errorCode: SessionErrorCode,
        failureDetail: String
    ) {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
            )
        else {
            phase = .failed
            recentErrorCode = errorCode.rawValue
            statusMessage = "\(errorCode.rawValue): \(failureDetail)"
            return
        }
        if !NSWorkspace.shared.open(url) {
            phase = .failed
            recentErrorCode = errorCode.rawValue
            statusMessage = "\(errorCode.rawValue): \(failureDetail)"
        }
    }

    func runDisplaySelfTest() async {
        guard !isServiceActive else { return }
        do {
            statusMessage = "正在运行创建、枚举和销毁诊断"
            let result = try await P3DiagnosticSelfTest.run()
            latestSelfTest = result
            selfTestSummary = String(
                format: "通过 · 创建 %.0f ms · 枚举 %.0f ms · 销毁 %.0f ms",
                result.createMilliseconds,
                result.enumerationMilliseconds,
                result.destroyMilliseconds
            )
            statusMessage = "虚拟显示器自检通过"
        } catch let error as SessionError {
            recentErrorCode = error.code.rawValue
            selfTestSummary = "失败 · \(error.code.rawValue)"
            statusMessage = localizedErrorMessage(error)
        } catch is CancellationError {
            statusMessage = "诊断自检已取消"
        } catch {
            recentErrorCode = SessionErrorCode.vdApplyFailed.rawValue
            selfTestSummary = "失败 · \(recentErrorCode)"
            statusMessage = "VD_APPLY_FAILED：诊断自检失败"
        }
    }

    func exportDiagnostics() {
        do {
            let data = try P3DiagnosticExporter.makeReport(
                events: eventHistory,
                selfTest: latestSelfTest
            )
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "SecondDisplay-Diagnostics.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = "诊断信息已导出"
        } catch let error as SessionError {
            recentErrorCode = error.code.rawValue
            statusMessage = localizedErrorMessage(error)
        } catch {
            recentErrorCode = SessionErrorCode.netProtocolMismatch.rawValue
            statusMessage = "NET_PROTOCOL_MISMATCH：无法导出诊断信息"
        }
    }

    func copyRecentErrorCode() {
        guard recentErrorCode != "—" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recentErrorCode, forType: .string)
    }

    /// 事件本身保留稳定的英文诊断内容，用户界面只呈现中文状态，避免改变日志和协议语义。
    private func localizedEventMessage(_ event: P3HostEvent) -> String {
        if let error = event.error { return localizedErrorMessage(error) }
        switch event.phase {
        case .stopped:
            return "服务已停止"
        case .starting:
            return "正在准备安全连接服务"
        case .listening:
            return "服务已启动，正在等待 HarmonyOS 设备连接"
        case .connected:
            return "HarmonyOS 接收设备已连接"
        case .preparingDisplay:
            if let displayID = event.displayID {
                return "正在准备虚拟显示器 \(displayID)"
            }
            return "正在准备虚拟显示器"
        case .streaming:
            if event.message.contains("drops C/E/S") {
                return localizedStreamingMetrics(event.message)
            }
            if let width = event.streamWidth, let height = event.streamHeight {
                return "正在传输 \(width)×\(height) · \(event.framesPerSecond ?? 0) FPS"
            }
            return "正在传输画面"
        case .recovering:
            return event.message.contains("preserving display")
                ? "连接已中断，将暂时保留虚拟显示器并尝试恢复"
                : "会话已中断，正在重建虚拟显示器"
        case .stopping:
            return "正在停止服务并释放虚拟显示器"
        case .failed:
            return "服务运行失败"
        }
    }

    /// 保留运行时诊断中的全部数值，只翻译固定标签。
    private func localizedStreamingMetrics(_ message: String) -> String {
        let replacements = [
            ("Streaming ", "正在传输 "),
            (" at ", " · "),
            (" fps · drops C/E/S ", " FPS · 丢帧 采集/编码/发送 "),
            (" · p95 cap ", " · P95 采集 "),
            (" q ", " 队列 "),
            (" pack ", " 封包 "),
            (" enc ", " 编码 "),
            (" send ", " 发送 "),
            (" ms · src ", " ms · 帧率 源 "),
            ("/cap ", "/采集 "),
            ("/enc ", "/编码 "),
            (" · recv ", " · 接收 "),
            ("/display ", "/显示 "),
            (" fps decodeP95 ", " FPS · 解码输出 P95 "),
            (" · dirty ", " · 变化区域 "),
            (" active ", " 活动 "),
            (" static ", " 静止 "),
            (" · HW LL on ", " · 硬件编码 · 低延迟 开启 "),
            (" · HW LL off ", " · 硬件编码 · 低延迟 关闭 "),
            (" · SW LL on ", " · 软件编码 · 低延迟 开启 "),
            (" · SW LL off ", " · 软件编码 · 低延迟 关闭 "),
            (" · net ", " · 网络 "),
            (" · E age/q/vt/rec/fail/u ", " · 编码丢弃 年龄/队列/VT/恢复/失败/未知 "),
        ]
        return replacements.reduce(message) { result, replacement in
            result.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    /// 错误码保持不变，便于检索诊断；仅将面向用户的说明转换为中文。
    private func localizedErrorMessage(_ error: SessionError) -> String {
        let detail: String
        switch error.code {
        case .vdCapabilityMissing: detail = "当前 macOS 缺少所需的虚拟显示器能力"
        case .vdApplyFailed: detail = "无法创建或配置虚拟显示器"
        case .vdEnumerationTimeout: detail = "等待虚拟显示器出现超时"
        case .vdHiDPIModeMissing: detail = "所需的 HiDPI 显示模式不可用"
        case .vdMirrorDetachFailed: detail = "无法将虚拟显示器切换为扩展模式"
        case .vdTerminatedBySystem: detail = "虚拟显示器已被系统移除"
        case .capPermissionDenied: detail = "未获得录屏权限"
        case .capStreamStopped: detail = "屏幕采集已停止"
        case .encCreateFailed: detail = "无法启动视频编码器"
        case .encBackpressure: detail = "视频编码队列出现积压"
        case .netProtocolMismatch: detail = "连接协议不兼容或配对身份不可用"
        case .decoderFatal: detail = "接收端视频解码失败"
        case .inputPermissionDenied: detail = "未获得辅助功能权限"
        }
        return "\(error.code.rawValue)：\(detail)"
    }

    private func apply(_ event: P3HostEvent) {
        guard event.generation >= latestGeneration else { return }
        latestGeneration = event.generation
        eventHistory.append(event)
        if eventHistory.count > 200 { eventHistory.removeFirst(eventHistory.count - 200) }
        phase = event.phase
        statusMessage = localizedEventMessage(event)
        if let value = event.deviceName { deviceName = value }
        if let value = event.displayID { displayID = String(value) }
        if let value = event.encodedFrameCount { encodedFrames = value.formatted() }
        if let value = event.droppedFrameCount { droppedFrames = value.formatted() }
        if let width = event.streamWidth, let height = event.streamHeight {
            streamMode = "\(width)×\(height) · \(event.framesPerSecond ?? 0) FPS"
        } else if let fps = event.framesPerSecond {
            streamMode = "\(fps) FPS"
        }
        if let bitrate = event.bitrate {
            currentBitrate = String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        }
        if let rtt = event.networkRTTMilliseconds {
            networkRTT = String(format: "%.1f ms", rtt)
        }
        if let depth = event.videoQueueDepth { videoQueueDepth = String(depth) }
        recoveryCount = event.recoveryCount.formatted()
        if let error = event.error { recentErrorCode = error.code.rawValue }
        if event.phase == .stopped {
            displayID = "—"
            deviceName = "等待接收设备连接"
        }
        if event.error?.code == .capPermissionDenied {
            refreshPermissions()
        }
    }

    func retryPairingIdentity() {
        guard !isServiceActive else { return }
        schedulePairingReload()
    }

    func resetPairingIdentity() {
        guard !isServiceActive else { return }
        pairingResetConfirmationPresented = false
        schedulePairingReload(resetsExistingIdentity: true)
    }

    func cancelPairingInitialization() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingGeneration &+= 1
        guard let pairingStore else { return }
        Task { await pairingStore.cancel() }
    }

    private func schedulePairingReload(resetsExistingIdentity: Bool = false) {
        pairingTask?.cancel()
        pairingGeneration &+= 1
        let generation = pairingGeneration
        pairingInitializing = true
        pairingReady = false
        pairingRecoveryAvailable = false
        credentials = nil
        certificateFingerprint = "不可用"
        pairingVerificationCode = "不可用"
        pairingQRCode = nil
        pairingLocation =
            resetsExistingIdentity
            ? "正在安全重置并重新生成本机身份…"
            : "正在安全初始化本机身份…"
        guard let pairingStore else {
            pairingInitializing = false
            pairingLocation = "NET_PROTOCOL_MISMATCH：无法访问应用支持目录"
            return
        }
        pairingTask = Task { [weak self] in
            do {
                let loaded =
                    if resetsExistingIdentity {
                        try await pairingStore.resetAndCreate(generation: generation)
                    } else {
                        try await pairingStore.loadOrCreate(generation: generation)
                    }
                try Task.checkCancellation()
                guard let self, self.pairingGeneration == generation else { return }
                self.applyPairingCredentials(loaded)
            } catch is CancellationError {
                return
            } catch let error as SessionError {
                guard let self, self.pairingGeneration == generation else { return }
                self.applyPairingFailure(error)
            } catch {
                guard let self, self.pairingGeneration == generation else { return }
                self.applyPairingFailure(
                    SessionError(
                        code: .netProtocolMismatch,
                        detail: "Unable to initialize pairing identity"
                    )
                )
            }
        }
    }

    private func applyPairingCredentials(_ loaded: PairingIdentityCredentials) {
        pairingTask = nil
        pairingInitializing = false
        pairingRecoveryAvailable = false
        credentials = loaded
        pairingReady = true
        certificateFingerprint = loaded.fingerprint
        pairingLocation = loaded.directory.path
        do {
            let presentation = try P3PairingPresentation(
                fingerprint: loaded.fingerprint,
                name: Host.current().localizedName ?? "Second Display Mac"
            )
            pairingVerificationCode = presentation.verificationCode
            pairingQRCode = try makePairingQRCode(payload: presentation.encodedJSON())
        } catch let error as SessionError {
            applyPairingFailure(error)
        } catch {
            applyPairingFailure(
                SessionError(code: .netProtocolMismatch, detail: "Unable to render pairing code")
            )
        }
    }

    private func applyPairingFailure(_ error: SessionError) {
        pairingTask = nil
        pairingInitializing = false
        pairingRecoveryAvailable = PairingIdentityStore.requiresExplicitReset(error)
        credentials = nil
        pairingReady = false
        certificateFingerprint = "不可用"
        pairingLocation =
            pairingRecoveryAvailable
            ? "NET_PROTOCOL_MISMATCH：配对身份不完整或损坏，请重置后重新配对"
            : localizedErrorMessage(error)
        pairingVerificationCode = "不可用"
        pairingQRCode = nil
    }

    private func makePairingQRCode(payload: String) throws -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unable to generate pairing QR code"
            )
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private enum LocalNetworkInfo {
    static func preferredIPv4Address() -> String? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var values: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let socketAddress = interface.pointee.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET),
                interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var ipv4 = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in.self)
                .pointee.sin_addr
            guard inet_ntop(AF_INET, &ipv4, &address, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            let bytes = address.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let value = String(decoding: bytes, as: UTF8.self)
            if !values.contains(value) { values.append(value) }
        }
        return values.sorted { lhs, rhs in
            let lhsPreferred = lhs.hasPrefix("192.168.43.")
            let rhsPreferred = rhs.hasPrefix("192.168.43.")
            return lhsPreferred == rhsPreferred ? lhs < rhs : lhsPreferred
        }.first
    }
}
