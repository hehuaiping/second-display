import receiverNative, { DecoderStatus } from 'libentry.so'
import { ErrorEvent, MessageEvents, util, worker } from '@kit.ArkTS'
import { display } from '@kit.ArkUI'
import { connection } from '@kit.NetworkKit'

PersistentStorage.persistProp('secondDisplayDeviceId', '')

interface ReceiverWorkerStatus {
  type: string
  code: string
}

interface ReceiverConnectCommand {
  type: string
  host: string
  controlPort: number
  videoPort: number
  caPem: string
  displayWidth: number
  displayHeight: number
  maxFps: number
  deviceId: string
  orientation: string
  codecs: string[]
}

@Entry
@Component
struct Index {
  @StorageLink('secondDisplayDeviceId') private receiverDeviceId: string = ''
  @State private decoderCode: string = 'WAITING_SURFACE'
  @State private decoderRunning: boolean = false
  @State private testFrames: number = 0
  @State private networkFrames: number = 0
  @State private decodedFrames: number = 0
  @State private renderedFrames: number = 0
  @State private staleOutputDrops: number = 0
  @State private decoderInFlight: number = 0
  @State private inputQueueLatencyMs: number = 0
  @State private decodeLatencyMs: number = 0
  @State private outputLatencyMs: number = 0
  @State private decoderRecoveries: number = 0
  @State private keyFrameRequests: number = 0
  @State private lowLatencyEnabled: boolean = false
  @State private immediateRenderingEnabled: boolean = true
  @State private realTimeFps: number = 0
  @State private systemDisplayWidth: number = 0
  @State private systemDisplayHeight: number = 0
  @State private systemMaxFps: number = 60
  @State private connectionCode: string = 'NOT_CONNECTED'
  @State private overlayVisible: boolean = true
  @State private recognizedGestureCount: number = 0
  @State private lastGestureCode: string = 'NONE'
  private statusTimer: number = -1
  private previousFrameCount: number = 0
  private previousFrameSampleAtMs: number = 0
  private receiverWorker: worker.ThreadWorker | undefined = undefined
  private workerGeneration: number = 0
  private pointerDown: boolean = false
  private pendingPointerDownTimer: number = -1
  private reconnectTimer: number = -1
  private reconnectDeadlineMs: number = 0
  private hadStreamingSession: boolean = false
  private scrolling: boolean = false
  private lastNormalizedX: number = 0.5
  private lastNormalizedY: number = 0.5
  private lastScrollX: number = 0
  private lastScrollY: number = 0
  private multiTouchSuppressed: boolean = false
  private multiPinchSent: boolean = false
  private supportedCodecs: string[] = ['h264']
  private previousFeedbackAtMs: number = 0
  private orientationRecoveryPending: boolean = false

  aboutToAppear(): void {
    if (this.receiverDeviceId.length === 0) {
      this.receiverDeviceId = util.generateRandomUUID()
    }
    this.refreshSystemDisplayResolution()
    this.refreshStatus()
    this.statusTimer = setInterval(() => this.refreshStatus(), 500)
  }

  aboutToDisappear(): void {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer)
      this.statusTimer = -1
    }
    this.cancelActiveTouch()
    this.cancelFastReconnect()
    receiverNative.stopDecoder()
    this.workerGeneration += 1
    if (this.receiverWorker !== undefined) {
      try {
        this.receiverWorker.postMessage({ type: 'stop' })
      } catch (error) {
        this.applyConnectionCode('NET_PROTOCOL_MISMATCH: unable to stop receiver worker')
      }
      this.receiverWorker = undefined
    }
  }

  private connectReceiver(isRecovery: boolean = false): void {
    this.cancelActiveTouch()
    if (!isRecovery) {
      this.cancelFastReconnect()
      this.reconnectDeadlineMs = 0
    }
    this.refreshSystemDisplayResolution()
    if (this.systemDisplayWidth === 0 || this.systemDisplayHeight === 0) {
      this.applyConnectionCode('NET_PROTOCOL_MISMATCH: system display resolution is unavailable')
      return
    }
    this.applyConnectionCode('CONNECTING')
    this.workerGeneration += 1
    const activeGeneration: number = this.workerGeneration
    if (this.receiverWorker !== undefined) {
      try {
        this.receiverWorker.postMessage({ type: 'stop' })
      } catch (error) {
        this.applyConnectionCode('NET_PROTOCOL_MISMATCH: unable to replace receiver worker')
      }
    }
    const receiverWorker: worker.ThreadWorker = new worker.ThreadWorker('../workers/ReceiverWorker.ets')
    receiverWorker.onmessage = (event: MessageEvents): void => {
      if (activeGeneration !== this.workerGeneration) {
        return
      }
      const message: ReceiverWorkerStatus = event.data as ReceiverWorkerStatus
      if (message.type === 'status') {
        this.applyConnectionCode(message.code)
      }
    }
    receiverWorker.onAllErrors = (error: ErrorEvent): void => {
      if (activeGeneration === this.workerGeneration) {
        this.applyConnectionCode(`NET_PROTOCOL_MISMATCH: ${error.message}`)
      }
    }
    receiverWorker.onexit = (code: number): void => {
      if (activeGeneration === this.workerGeneration && code !== 0) {
        this.applyConnectionCode('NET_PROTOCOL_MISMATCH: receiver worker exited')
      }
    }
    this.receiverWorker = receiverWorker
    const command: ReceiverConnectCommand = {
      type: 'connect',
      host: '192.168.43.9',
      controlPort: 52340,
      videoPort: 52341,
      caPem: receiverNative.getPocCACertificate(),
      displayWidth: this.systemDisplayWidth,
      displayHeight: this.systemDisplayHeight,
      maxFps: this.systemMaxFps,
      deviceId: this.receiverDeviceId,
      orientation: this.systemDisplayWidth >= this.systemDisplayHeight ? 'landscape' : 'portrait',
      codecs: this.supportedCodecs
    }
    try {
      receiverWorker.postMessage(command)
    } catch (error) {
      this.applyConnectionCode('NET_PROTOCOL_MISMATCH: unable to start receiver worker')
    }
  }

  private applyConnectionCode(code: string): void {
    if (code !== 'STREAM_READY' && this.connectionCode === 'STREAM_READY') {
      this.cancelActiveTouch()
    }
    this.connectionCode = code
    this.overlayVisible = code !== 'STREAM_READY'
    if (code === 'STREAM_READY') {
      this.orientationRecoveryPending = false
      this.hadStreamingSession = true
      this.cancelFastReconnect()
      this.reconnectDeadlineMs = 0
    } else if (this.hadStreamingSession &&
      (code === 'DISCONNECTED' || code.startsWith('NET_'))) {
      this.scheduleFastReconnect()
    }
    if (code !== 'STREAM_READY') {
      this.resetFrameRateSampling(this.renderedFrames)
    }
  }

  private scheduleFastReconnect(): void {
    const nowMs: number = Date.now()
    if (this.reconnectDeadlineMs === 0) {
      this.reconnectDeadlineMs = nowMs + 10000
    }
    if (nowMs >= this.reconnectDeadlineMs) {
      this.cancelFastReconnect()
      this.reconnectDeadlineMs = 0
      return
    }
    if (this.reconnectTimer >= 0) return
    this.connectionCode = 'RECONNECTING'
    this.overlayVisible = true
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1
      if (Date.now() < this.reconnectDeadlineMs) {
        this.connectReceiver(true)
      }
    }, 500)
  }

  private cancelFastReconnect(): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = -1
    }
  }

  private isStreamReady(): boolean {
    return this.connectionCode === 'STREAM_READY'
  }

  private postInputEvent(
    eventType: string,
    normalizedX?: number,
    normalizedY?: number,
    deltaX: number = 0,
    deltaY: number = 0
  ): void {
    if (!this.isStreamReady() || this.receiverWorker === undefined) return
    try {
      this.receiverWorker.postMessage({
        type: 'inputEvent',
        eventType: eventType,
        normalizedX: normalizedX,
        normalizedY: normalizedY,
        deltaX: deltaX,
        deltaY: deltaY
      })
    } catch (error) {
      this.applyConnectionCode('NET_PROTOCOL_MISMATCH: unable to send input event')
    }
  }

  private cancelActiveTouch(): void {
    this.cancelPendingPointerDown()
    if (this.pointerDown) {
      this.postInputEvent('leftUp', this.lastNormalizedX, this.lastNormalizedY)
    }
    this.pointerDown = false
    this.scrolling = false
    this.multiTouchSuppressed = false
    this.resetMultiGestureRecognition()
  }

  private cancelPendingPointerDown(): void {
    if (this.pendingPointerDownTimer >= 0) {
      clearTimeout(this.pendingPointerDownTimer)
      this.pendingPointerDownTimer = -1
    }
  }

  private schedulePointerDown(): void {
    this.cancelPendingPointerDown()
    this.pendingPointerDownTimer = setTimeout(() => {
      this.pendingPointerDownTimer = -1
      if (!this.isStreamReady() || this.overlayVisible || this.scrolling || this.multiTouchSuppressed) return
      this.pointerDown = true
      this.postInputEvent('leftDown', this.lastNormalizedX, this.lastNormalizedY)
    }, 70)
  }

  private postGestureEvent(
    fingerCount: number,
    gestureType: string,
    direction: string,
    magnitude: number
  ): void {
    if (!this.isStreamReady() || this.receiverWorker === undefined) return
    this.recognizedGestureCount += 1
    this.lastGestureCode = `${fingerCount}F_${gestureType}_${direction}`
    try {
      this.receiverWorker.postMessage({
        type: 'gestureEvent',
        fingerCount: fingerCount,
        gestureType: gestureType,
        direction: direction,
        magnitude: magnitude
      })
    } catch (error) {
      this.applyConnectionCode('NET_PROTOCOL_MISMATCH: unable to send gesture event')
    }
  }

  private resetMultiGestureRecognition(): void {
    this.multiPinchSent = false
  }

  private handleSwipeGesture(fingerCount: number, event: GestureEvent): void {
    if (!Number.isFinite(event.angle)) return
    const radians: number = event.angle * Math.PI / 180
    const dx: number = Math.cos(radians)
    const dy: number = Math.sin(radians)
    let direction: string
    if (Math.abs(dx) >= Math.abs(dy)) {
      direction = dx < 0 ? 'left' : 'right'
    } else {
      direction = dy < 0 ? 'up' : 'down'
    }
    const displayShortEdge: number = Math.max(
      Math.min(this.systemDisplayWidth, this.systemDisplayHeight), 1
    )
    const speed: number = Number.isFinite(event.speed) ? event.speed : 0
    this.postGestureEvent(
      fingerCount, 'swipe', direction, Math.max(speed / displayShortEdge, 0)
    )
  }

  private beginPinchGesture(fingerCount: number, event: GestureEvent): void {
    this.multiPinchSent = false
    this.handlePinchGesture(fingerCount, event)
  }

  private handlePinchGesture(fingerCount: number, event: GestureEvent): void {
    if (this.multiPinchSent || !Number.isFinite(event.scale) || event.scale <= 0) return
    const scaleChange: number = Math.abs(event.scale - 1)
    if (scaleChange < 0.10) return
    this.postGestureEvent(fingerCount, 'pinch', event.scale < 1 ? 'in' : 'out', scaleChange)
    this.multiPinchSent = true
  }

  private endPinchGesture(fingerCount: number, event: GestureEvent): void {
    this.handlePinchGesture(fingerCount, event)
    this.multiPinchSent = false
  }

  private handleTouch(event?: TouchEvent): void {
    if (event === undefined || !this.isStreamReady() || this.overlayVisible) return
    const width: number = Number(event.target.area.width)
    const height: number = Number(event.target.area.height)
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return
    if (event.type === TouchType.Cancel) {
      this.cancelActiveTouch()
      return
    }

    if (event.touches.length >= 3) {
      this.multiTouchSuppressed = true
      this.cancelPendingPointerDown()
      if (this.pointerDown) {
        this.postInputEvent('leftUp', this.lastNormalizedX, this.lastNormalizedY)
        this.pointerDown = false
      }
      this.scrolling = false
      return
    }

    if (this.multiTouchSuppressed) {
      if (event.type === TouchType.Down && event.touches.length <= 1) {
        this.multiTouchSuppressed = false
      } else {
        return
      }
    }

    if (event.touches.length >= 2) {
      this.cancelPendingPointerDown()
      if (this.pointerDown) {
        this.postInputEvent('leftUp', this.lastNormalizedX, this.lastNormalizedY)
        this.pointerDown = false
      }
      const centerX: number = (event.touches[0].x + event.touches[1].x) / 2
      const centerY: number = (event.touches[0].y + event.touches[1].y) / 2
      if (!this.scrolling || event.type === TouchType.Down) {
        this.scrolling = true
        this.lastScrollX = centerX
        this.lastScrollY = centerY
        return
      }
      if (event.type === TouchType.Move) {
        this.postInputEvent(
          'scroll',
          Math.min(Math.max(centerX / width, 0), 1),
          Math.min(Math.max(centerY / height, 0), 1),
          this.lastScrollX - centerX,
          this.lastScrollY - centerY
        )
        this.lastScrollX = centerX
        this.lastScrollY = centerY
      }
      return
    }

    const touch = event.changedTouches.length > 0 ? event.changedTouches[0]
      : (event.touches.length > 0 ? event.touches[0] : undefined)
    if (touch === undefined) {
      if (event.type === TouchType.Up) this.cancelActiveTouch()
      return
    }
    const normalizedX: number = Math.min(Math.max(touch.x / width, 0), 1)
    const normalizedY: number = Math.min(Math.max(touch.y / height, 0), 1)
    this.lastNormalizedX = normalizedX
    this.lastNormalizedY = normalizedY
    if (event.type === TouchType.Down) {
      this.scrolling = false
      this.schedulePointerDown()
    } else if (event.type === TouchType.Move) {
      if (this.pendingPointerDownTimer < 0) {
        this.postInputEvent(this.pointerDown ? 'drag' : 'move', normalizedX, normalizedY)
      }
    } else if (event.type === TouchType.Up) {
      if (this.pendingPointerDownTimer >= 0) {
        this.cancelPendingPointerDown()
        this.postInputEvent('leftDown', normalizedX, normalizedY)
        this.postInputEvent('leftUp', normalizedX, normalizedY)
      } else if (this.pointerDown) {
        this.postInputEvent('leftUp', normalizedX, normalizedY)
      }
      this.pointerDown = false
      this.scrolling = false
    }
  }

  private connectionTitle(): string {
    if (this.connectionCode === 'CONNECTING' || this.connectionCode === 'RECONNECTING') {
      return '正在连接 Mac…'
    }
    if (this.connectionCode === 'TLS_CONNECTED') {
      return '安全连接已建立'
    }
    if (this.connectionCode === 'DISCONNECTED' || this.connectionCode === 'STOPPED') {
      return '连接已断开'
    }
    if (this.connectionCode.startsWith('NET_')) {
      return '暂时无法连接'
    }
    return '等待连接 Mac'
  }

  private connectionHint(): string {
    if (this.connectionCode === 'RECONNECTING') {
      return '连接短暂中断，正在自动恢复扩展屏幕'
    }
    if (this.connectionCode === 'CONNECTING') {
      return '正在查找 Second Display 服务，请稍候'
    }
    if (this.connectionCode === 'TLS_CONNECTED') {
      return '正在创建扩展屏幕并准备画面'
    }
    if (this.connectionCode === 'DISCONNECTED' || this.connectionCode === 'STOPPED') {
      return '请确认 Mac 服务仍在运行，然后重新连接'
    }
    if (this.connectionCode.startsWith('NET_')) {
      return '请确认两台设备处于同一网络，并检查 Mac 端显示的 IP'
    }
    return '请先在 Mac 打开 Second Display，然后点击“Start Service”'
  }

  private refreshSystemDisplayResolution(): boolean {
    const previousWidth: number = this.systemDisplayWidth
    const previousHeight: number = this.systemDisplayHeight
    try {
      const displayInfo: display.Display = display.getDefaultDisplaySync()
      let width: number = Math.floor(displayInfo.width)
      let height: number = Math.floor(displayInfo.height)
      width -= width % 2
      height -= height % 2
      if (Math.min(width, height) < 600 || Math.max(width, height) < 800
        || width > 8192 || height > 8192) {
        this.systemDisplayWidth = 0
        this.systemDisplayHeight = 0
        this.systemMaxFps = 60
        this.supportedCodecs = ['h264']
        return previousWidth !== 0 || previousHeight !== 0
      }
      this.systemDisplayWidth = width
      this.systemDisplayHeight = height
      const h264MaxFps: number = receiverNative.getH264DecoderMaxFps(width, height)
      const hevcMaxFps: number = receiverNative.getHEVCDecoderMaxFps(width, height)
      this.supportedCodecs = hevcMaxFps > 0 ? ['hevc', 'h264'] : ['h264']
      let displayMaxFps: number = Math.floor(displayInfo.refreshRate)
      if (displayInfo.supportedRefreshRates !== undefined && displayInfo.supportedRefreshRates.length > 0) {
        for (const refreshRate of displayInfo.supportedRefreshRates) {
          displayMaxFps = Math.max(displayMaxFps, Math.floor(refreshRate))
        }
      }
      const decoderMaxFps: number = hevcMaxFps > 0
        ? Math.min(h264MaxFps > 0 ? h264MaxFps : 60, hevcMaxFps)
        : (h264MaxFps > 0 ? h264MaxFps : 60)
      const capabilityMaxFps: number = Math.min(displayMaxFps, decoderMaxFps)
      this.systemMaxFps = capabilityMaxFps >= 120 ? 120 : capabilityMaxFps >= 90 ? 90 : 60
      return previousWidth !== width || previousHeight !== height
    } catch (error) {
      this.systemDisplayWidth = 0
      this.systemDisplayHeight = 0
      this.systemMaxFps = 60
      this.supportedCodecs = ['h264']
      return previousWidth !== 0 || previousHeight !== 0
    }
  }

  private refreshStatus(): void {
    const displayChanged: boolean = this.refreshSystemDisplayResolution()
    if (displayChanged && this.isStreamReady() && !this.orientationRecoveryPending
      && this.systemDisplayWidth > 0 && this.systemDisplayHeight > 0) {
      this.orientationRecoveryPending = true
      this.connectReceiver(true)
      return
    }
    const status: DecoderStatus = receiverNative.getDecoderStatus()
    this.refreshFrameRate(status)
    this.decoderCode = status.code
    this.decoderRunning = status.running
    this.testFrames = status.testFrames
    this.networkFrames = status.networkFrames
    this.decodedFrames = status.decodedFrames
    this.renderedFrames = status.renderedFrames
    this.staleOutputDrops = status.staleOutputDrops
    this.decoderInFlight = status.decoderInFlight
    this.inputQueueLatencyMs = Math.round(status.inputQueueLatencyUs / 100) / 10
    this.decodeLatencyMs = Math.round(status.decodeLatencyUs / 100) / 10
    this.outputLatencyMs = Math.round(status.outputLatencyUs / 100) / 10
    this.decoderRecoveries = status.decoderRecoveries
    this.keyFrameRequests = status.keyFrameRequests
    this.lowLatencyEnabled = status.lowLatencyEnabled
    this.immediateRenderingEnabled = status.immediateRenderingEnabled
    this.postReceiverFeedback(status)
  }

  private currentNetworkType(): string {
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync()
      const capabilities: connection.NetCapabilities = connection.getNetCapabilitiesSync(handle)
      if (capabilities.bearerTypes.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0) {
        return 'usbOrEthernet'
      }
      if (capabilities.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0) return 'wifi'
      if (capabilities.bearerTypes.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0) return 'cellular'
    } catch (error) {
      return 'unknown'
    }
    return 'other'
  }

  private postReceiverFeedback(status: DecoderStatus): void {
    const nowMs: number = Date.now()
    if (!this.isStreamReady() || this.receiverWorker === undefined
      || nowMs - this.previousFeedbackAtMs < 1000) return
    this.previousFeedbackAtMs = nowMs
    try {
      this.receiverWorker.postMessage({
        type: 'receiverFeedback',
        decoderQueueDepth: status.decoderInFlight,
        droppedFrames: status.droppedFrames,
        renderedFramesPerSecond: this.realTimeFps,
        networkType: this.currentNetworkType()
      })
    } catch (error) {
      this.applyConnectionCode('NET_PROTOCOL_MISMATCH: unable to send receiver feedback')
    }
  }

  private refreshFrameRate(status: DecoderStatus): void {
    const nowMs: number = Date.now()
    if (!status.running || !this.isStreamReady() || status.renderedFrames < this.previousFrameCount) {
      this.previousFrameCount = status.renderedFrames
      this.previousFrameSampleAtMs = nowMs
      this.realTimeFps = 0
      return
    }
    if (this.previousFrameSampleAtMs === 0) {
      this.previousFrameCount = status.renderedFrames
      this.previousFrameSampleAtMs = nowMs
      return
    }
    const elapsedMs: number = nowMs - this.previousFrameSampleAtMs
    if (elapsedMs < 1000) {
      return
    }
    const frameDelta: number = status.renderedFrames - this.previousFrameCount
    this.realTimeFps = Math.round(frameDelta * 10000 / elapsedMs) / 10
    this.previousFrameCount = status.renderedFrames
    this.previousFrameSampleAtMs = nowMs
  }

  private resetFrameRateSampling(frameCount: number): void {
    this.previousFrameCount = frameCount
    this.previousFrameSampleAtMs = Date.now()
    this.realTimeFps = 0
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({
        id: 'secondDisplaySurface',
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .width('100%')
        .height('100%')

      if (!this.isStreamReady()) {
        Column({ space: 12 }) {
          Text('Second Display')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          Text(this.connectionTitle())
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F6FF')
          Text(this.connectionHint())
            .fontSize(14)
            .fontColor('#D7DFEA')
            .textAlign(TextAlign.Center)
          Text(
            `系统分辨率 ${this.systemDisplayWidth}×${this.systemDisplayHeight} · 最高 ${this.systemMaxFps} FPS · Mac 192.168.43.9 · TLS`
          )
            .fontSize(12)
            .fontColor('#AFC4DC')

          Button(this.connectionCode === 'NOT_CONNECTED' ? '连接 Mac' : '重新连接')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor('#5B8DEF')
            .enabled(this.connectionCode !== 'CONNECTING' && this.connectionCode !== 'TLS_CONNECTED')
            .onClick(() => this.connectReceiver())

          if (this.connectionCode.startsWith('NET_')) {
            Text(this.connectionCode)
              .fontSize(10)
              .fontColor('#FFB9B9')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Center)
        .width('52%')
        .padding({ left: 28, right: 28, top: 22, bottom: 22 })
        .backgroundColor('#42000000')
        .borderRadius(18)
      }

      if (this.isStreamReady() && !this.overlayVisible) {
        Row() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#01000000')
        .onTouch((event?: TouchEvent) => this.handleTouch(event))
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            SwipeGesture({
              fingers: 3,
              direction: SwipeDirection.All,
              speed: 60,
              isFingerCountLimited: true
            }).onAction((event: GestureEvent) => this.handleSwipeGesture(3, event)),
            PinchGesture({ fingers: 3, distance: 10, isFingerCountLimited: true })
              .onActionStart((event: GestureEvent) => this.beginPinchGesture(3, event))
              .onActionUpdate((event: GestureEvent) => this.handlePinchGesture(3, event))
              .onActionEnd((event: GestureEvent) => this.endPinchGesture(3, event))
              .onActionCancel(() => this.resetMultiGestureRecognition()),
            SwipeGesture({
              fingers: 4,
              direction: SwipeDirection.All,
              speed: 60,
              isFingerCountLimited: true
            }).onAction((event: GestureEvent) => this.handleSwipeGesture(4, event)),
            PinchGesture({ fingers: 4, distance: 10, isFingerCountLimited: true })
              .onActionStart((event: GestureEvent) => this.beginPinchGesture(4, event))
              .onActionUpdate((event: GestureEvent) => this.handlePinchGesture(4, event))
              .onActionEnd((event: GestureEvent) => this.endPinchGesture(4, event))
              .onActionCancel(() => this.resetMultiGestureRecognition()),
            SwipeGesture({
              fingers: 5,
              direction: SwipeDirection.All,
              speed: 60,
              isFingerCountLimited: true
            }).onAction((event: GestureEvent) => this.handleSwipeGesture(5, event)),
            PinchGesture({ fingers: 5, distance: 10, isFingerCountLimited: true })
              .onActionStart((event: GestureEvent) => this.beginPinchGesture(5, event))
              .onActionUpdate((event: GestureEvent) => this.handlePinchGesture(5, event))
              .onActionEnd((event: GestureEvent) => this.endPinchGesture(5, event))
              .onActionCancel(() => this.resetMultiGestureRecognition())
          )
        )

        Button('状态')
          .fontSize(9)
          .fontColor('#80FFFFFF')
          .width(54)
          .height(30)
          .backgroundColor('#18000000')
          .position({ x: '96%', y: '2%' })
          .onClick(() => this.overlayVisible = true)
      }

      if (this.isStreamReady() && this.overlayVisible) {
        Column() {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('已连接 · Second Display')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
              Text(
                `${this.decoderCode} · 总接收帧 ${this.networkFrames} · 实时渲染 ${this.realTimeFps.toFixed(1)} FPS`
              )
                .fontSize(10)
                .fontColor('#DCE7F5')
              Text(
                `解码 ${this.decodedFrames} · in-flight ${this.decoderInFlight} · 排队/解码/接收 ${this.inputQueueLatencyMs.toFixed(1)}/${this.decodeLatencyMs.toFixed(1)}/${this.outputLatencyMs.toFixed(1)} ms · 低延迟 ${this.lowLatencyEnabled ? '开' : '关'} · ${this.immediateRenderingEnabled ? '立即呈现' : '定时呈现'} · 过期丢弃 ${this.staleOutputDrops} · IDR请求 ${this.keyFrameRequests} · 恢复 ${this.decoderRecoveries}`
              )
                .fontSize(9)
                .fontColor('#BFCDE0')
              Text(`手势已发送 ${this.recognizedGestureCount} · 最近 ${this.lastGestureCode}`)
                .fontSize(9)
                .fontColor('#BFCDE0')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button('30 分钟稳定性测试')
              .fontSize(11)
              .fontColor(Color.White)
              .backgroundColor('#38000000')
              .onClick(() => {
                receiverNative.startDecoderSoak(30 * 60)
                this.refreshStatus()
              })
            Button('重启解码器')
              .fontSize(11)
              .fontColor(Color.White)
              .backgroundColor('#38000000')
              .onClick(() => {
                receiverNative.restartDecoder()
                this.refreshStatus()
              })
            Button('隐藏')
              .fontSize(11)
              .fontColor(Color.White)
              .backgroundColor('#38000000')
              .onClick(() => this.overlayVisible = false)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor('#26000000')

          Blank()
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }
}
