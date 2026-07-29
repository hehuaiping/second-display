import AppKit

@MainActor
final class P3AnimatedTestPattern {
    private let window: NSWindow
    private let view: P3TestPatternView
    private let framesPerSecond: Int
    private var timer: DispatchSourceTimer?

    var generatedFrameCount: UInt64 { view.generatedFrameCount }

    init(
        screen: NSScreen,
        framebufferWidth: Int,
        framebufferHeight: Int,
        framesPerSecond: Int
    ) {
        _ = NSApplication.shared
        self.framesPerSecond = framesPerSecond
        view = P3TestPatternView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            framebufferWidth: framebufferWidth,
            framebufferHeight: framebufferHeight,
            framesPerSecond: framesPerSecond
        )
        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = view
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.stationary]
        window.setFrame(screen.frame, display: true)
    }

    func start() {
        guard timer == nil else { return }
        window.orderFrontRegardless()
        let source = DispatchSource.makeTimerSource(queue: .main)
        let intervalNanoseconds = max(1, 1_000_000_000 / framesPerSecond)
        source.schedule(
            deadline: .now(),
            repeating: .nanoseconds(intervalNanoseconds),
            leeway: .microseconds(min(1_000, intervalNanoseconds / 10_000))
        )
        source.setEventHandler { [weak self] in self?.view.advanceFrame() }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
private final class P3TestPatternView: NSView {
    private var frameNumber: UInt64 = 0
    private let framebufferWidth: Int
    private let framebufferHeight: Int
    private let framesPerSecond: Int

    init(
        frame frameRect: NSRect,
        framebufferWidth: Int,
        framebufferHeight: Int,
        framesPerSecond: Int
    ) {
        self.framebufferWidth = framebufferWidth
        self.framebufferHeight = framebufferHeight
        self.framesPerSecond = framesPerSecond
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool { true }
    var generatedFrameCount: UInt64 { frameNumber }

    func advanceFrame() {
        frameNumber &+= 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let phase = CGFloat(frameNumber % 360) / 360
        NSColor(calibratedHue: phase, saturation: 0.75, brightness: 0.28, alpha: 1).setFill()
        bounds.fill()

        let barWidth = max(bounds.width * 0.12, 80)
        let travel = max(bounds.width - barWidth, 1)
        let position = CGFloat(frameNumber % 240) / 239
        let x = position * travel
        NSColor(
            calibratedHue: (phase + 0.5).truncatingRemainder(dividingBy: 1),
            saturation: 0.85,
            brightness: 1,
            alpha: 1
        ).setFill()
        NSRect(x: x, y: 0, width: barWidth, height: bounds.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        NSString(
            string: "P3 \(framebufferWidth) x \(framebufferHeight) @ \(framesPerSecond)\nframe \(frameNumber)"
        )
        .draw(at: NSPoint(x: 80, y: 80), withAttributes: attributes)
    }
}
