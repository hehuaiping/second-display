import receiverNative, { DecoderStatus } from 'libentry.so'
import { ErrorEvent, MessageEvents, util, worker } from '@kit.ArkTS'
import { display } from '@kit.ArkUI'
import { connection } from '@kit.NetworkKit'
import { common } from '@kit.AbilityKit'
import { scanBarcode, scanCore } from '@kit.ScanKit'
import {
  DiscoveredSecondDisplayService,
  fingerprintCertificatePEM,
  ServiceDiscoveryController
} from '../services/ServiceDiscoveryController'
import { NetworkChangeMonitor } from '../services/NetworkChangeMonitor'
import {
  PairingTrustStore,
  pairingVerificationCode,
  parsePairingPayload,
  TrustedMac
} from '../services/PairingTrustStore'

PersistentStorage.persistProp('secondDisplayDeviceId', '')

interface ReceiverWorkerStatus {
  type: string
  code: string
}

interface ReceiverConnectCommand {
  type: string
  host: string
  family: number
  controlPort: number
  videoPort: number
  caPem: string
  pinnedFingerprint: string
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
  @State private discoveredServices: DiscoveredSecondDisplayService[] = []
  @State private discoveryCode: string = 'DISCOVERY_IDLE'
  @State private manualHost: string = '192.168.43.9'
  @State private manualTrustedFingerprint: string = ''
  @State private trustedMacs: TrustedMac[] = []
  @State private pendingPairingFingerprint: string = ''
  @State private pendingPairingName: string = ''
  @State private pairingCodeInput: string = ''
  @State private pairingQrVerified: boolean = false
  @State private pairingStatus: string = ''
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
  private discoveryController: ServiceDiscoveryController = new ServiceDiscoveryController()
  private networkChangeMonitor: NetworkChangeMonitor = new NetworkChangeMonitor()
  private trustStore: PairingTrustStore = new PairingTrustStore()
  private selectedTarget: DiscoveredSecondDisplayService | undefined = undefined
  private pairedFingerprint: string = ''
  private trustGeneration: number = 0
  private pairingOperationGeneration: number = 0
  private rediscoveryFingerprint: string = ''

  aboutToAppear(): void {
    if (this.receiverDeviceId.length === 0) {
      this.receiverDeviceId = util.generateRandomUUID()
    }
    this.refreshSystemDisplayResolution()
    this.pairedFingerprint = fingerprintCertificatePEM(receiverNative.getPocCACertificate())
    this.loadTrustedMacs()
    this.networkChangeMonitor.start((): void => {
      if (!this.isStreamReady() && this.connectionCode !== 'CONNECTING'
        && this.connectionCode !== 'TLS_CONNECTED' && this.connectionCode !== 'RECONNECTING') {
        this.startDiscovery()
      }
    })
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
    this.networkChangeMonitor.stop()
    this.discoveryController.stop()
    this.trustGeneration += 1
    this.pairingOperationGeneration += 1
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

  private loadTrustedMacs(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined
    if (context === undefined) {
      this.discoveryCode = 'NET_PROTOCOL_MISMATCH: application context is unavailable'
      return
    }
    this.trustGeneration += 1
    const activeGeneration: number = this.trustGeneration
    this.trustStore.load(context, this.pairedFingerprint, 'Second Display Mac').then(
      (devices: TrustedMac[]): void => {
        if (activeGeneration !== this.trustGeneration) return
        this.trustedMacs = devices
        this.synchronizeManualTrustSelection()
        this.startDiscovery()
      }
    ).catch((): void => {
      if (activeGeneration !== this.trustGeneration) return
      // 存储异常时保留本次运行的内置证书兼容路径，但不伪装成已持久化成功。
      this.trustedMacs = this.pairedFingerprint.length === 64 ? [{
        fingerprint: this.pairedFingerprint,
        name: 'Second Display Mac',
        pairedAtMs: Date.now()
      }] : []
      this.synchronizeManualTrustSelection()
      this.discoveryCode = 'NET_PROTOCOL_MISMATCH: unable to load paired Macs'
      this.startDiscovery()
    })
  }

  private beginPairing(service: DiscoveredSecondDisplayService): void {
    this.pendingPairingFingerprint = service.fingerprint
    this.pendingPairingName = service.name
    this.pairingCodeInput = ''
    this.pairingQrVerified = false
    this.pairingStatus = '请扫描 Mac 上的二维码，或输入 Mac 显示的校验码'
  }

  private cancelPairing(): void {
    this.pairingOperationGeneration += 1
    this.pendingPairingFingerprint = ''
    this.pendingPairingName = ''
    this.pairingCodeInput = ''
    this.pairingQrVerified = false
    this.pairingStatus = ''
  }

  private scanPairingQRCode(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined
    if (context === undefined) {
      this.pairingStatus = 'NET_PROTOCOL_MISMATCH: application context is unavailable'
      return
    }
    this.pairingOperationGeneration += 1
    const activeGeneration: number = this.pairingOperationGeneration
    scanBarcode.startScanForResult(context, {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableAlbum: true
    }).then((result: scanBarcode.ScanResult): void => {
      if (activeGeneration !== this.pairingOperationGeneration) return
      const payload = parsePairingPayload(result.originalValue)
      if (payload === undefined) {
        this.pairingStatus = 'NET_PROTOCOL_MISMATCH: invalid Second Display pairing QR code'
        return
      }
      if (this.pendingPairingFingerprint.length === 64
        && payload.fingerprint !== this.pendingPairingFingerprint) {
        this.pairingStatus = 'NET_PROTOCOL_MISMATCH: QR code does not match the selected Mac'
        return
      }
      const candidate: DiscoveredSecondDisplayService | undefined = this.discoveredServices.find(
        (value: DiscoveredSecondDisplayService) => value.fingerprint === payload.fingerprint
      )
      this.pendingPairingFingerprint = payload.fingerprint
      this.pendingPairingName = candidate?.name ?? payload.name
      this.pairingQrVerified = true
      this.pairingStatus = '二维码指纹已核对，请确认信任此 Mac'
    }).catch((): void => {
      if (activeGeneration === this.pairingOperationGeneration) {
        this.pairingStatus = '扫码已取消或暂时不可用，可改用校验码'
      }
    })
  }

  private confirmPairing(): void {
    const expectedCode: string = pairingVerificationCode(this.pendingPairingFingerprint)
    const enteredCode: string = this.pairingCodeInput.replace(/[^0-9a-fA-F]/g, '').toUpperCase()
    const expectedCompact: string = expectedCode.replace(/-/g, '')
    if (!this.pairingQrVerified && (expectedCompact.length !== 12 || enteredCode !== expectedCompact)) {
      this.pairingStatus = 'NET_PROTOCOL_MISMATCH: verification code does not match this Mac'
      return
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined
    if (context === undefined) {
      this.pairingStatus = 'NET_PROTOCOL_MISMATCH: application context is unavailable'
      return
    }
    this.trustGeneration += 1
    const activeGeneration: number = this.trustGeneration
    this.trustStore.trust(
      context,
      this.trustedMacs,
      this.pendingPairingFingerprint,
      this.pendingPairingName
    ).then((devices: TrustedMac[]): void => {
      if (activeGeneration !== this.trustGeneration) return
      this.trustedMacs = devices
      this.manualTrustedFingerprint = this.pendingPairingFingerprint
      this.cancelPairing()
      this.discoveryController.stop()
      this.startDiscovery()
    }).catch((): void => {
      if (activeGeneration === this.trustGeneration) {
        this.pairingStatus = 'NET_PROTOCOL_MISMATCH: unable to save paired Mac'
      }
    })
  }

  private removePairing(service: DiscoveredSecondDisplayService): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined
    if (context === undefined) {
      this.discoveryCode = 'NET_PROTOCOL_MISMATCH: application context is unavailable'
      return
    }
    this.trustGeneration += 1
    const activeGeneration: number = this.trustGeneration
    this.trustStore.remove(context, this.trustedMacs, service.fingerprint).then(
      (devices: TrustedMac[]): void => {
        if (activeGeneration !== this.trustGeneration) return
        this.trustedMacs = devices
        this.synchronizeManualTrustSelection()
        if (this.selectedTarget?.fingerprint === service.fingerprint) {
          this.selectedTarget = undefined
        }
        this.discoveryController.stop()
        this.startDiscovery()
      }
    ).catch((): void => {
      if (activeGeneration === this.trustGeneration) {
        this.discoveryCode = 'NET_PROTOCOL_MISMATCH: unable to remove paired Mac'
      }
    })
  }

  private startDiscovery(): void {
    if (this.isStreamReady() || this.connectionCode === 'CONNECTING'
      || this.connectionCode === 'TLS_CONNECTED' || this.connectionCode === 'RECONNECTING') return
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined
    if (context === undefined) {
      this.discoveryCode = 'NET_PROTOCOL_MISMATCH: application context is unavailable'
      return
    }
    this.discoveryController.start(
      context,
      this.trustedMacs.map((value: TrustedMac) => value.fingerprint),
      (services: DiscoveredSecondDisplayService[]): void => {
        this.discoveredServices = services
        if (this.selectedTarget !== undefined && this.selectedTarget.fingerprint.length === 64) {
          const refreshed: DiscoveredSecondDisplayService | undefined = services.find(
            (value: DiscoveredSecondDisplayService) =>
              value.fingerprint === this.selectedTarget?.fingerprint
          )
          if (refreshed !== undefined) this.selectedTarget = refreshed
        }
        if (this.rediscoveryFingerprint.length === 64) {
          const recovered: DiscoveredSecondDisplayService | undefined = services.find(
            (value: DiscoveredSecondDisplayService) =>
              value.paired && value.fingerprint === this.rediscoveryFingerprint
          )
          if (recovered !== undefined) {
            this.rediscoveryFingerprint = ''
            this.selectedTarget = recovered
            this.connectReceiver(true)
          }
        }
      },
      (status: string): void => {
        this.discoveryCode = status
      }
    )
  }

  private synchronizeManualTrustSelection(): void {
    if (this.trustedMacs.some(
      (value: TrustedMac) => value.fingerprint === this.manualTrustedFingerprint
    )) return
    this.manualTrustedFingerprint = this.trustedMacs.length > 0
      ? this.trustedMacs[0].fingerprint : ''
  }

  private manualTarget(): DiscoveredSecondDisplayService | undefined {
    const host: string = this.manualHost.trim()
    if (host.length === 0 || host.length > 255 || /\s/.test(host)) {
      this.applyConnectionCode('NET_PROTOCOL_MISMATCH: manual host is invalid')
      return undefined
    }
    const trusted: TrustedMac | undefined = this.trustedMacs.find(
      (value: TrustedMac) => value.fingerprint === this.manualTrustedFingerprint
    )
    if (trusted === undefined) {
      this.applyConnectionCode(this.trustedMacs.length === 0
        ? 'NET_PROTOCOL_MISMATCH: pair a Mac before manual connection'
        : 'NET_PROTOCOL_MISMATCH: select a paired Mac identity for manual connection')
      return undefined
    }
    return {
      id: `manual-${host}`,
      sourceName: 'manual',
      name: '手动地址',
      host: host,
      family: host.indexOf(':') >= 0 ? 2 : 1,
      controlPort: 52340,
      videoPort: 52341,
      fingerprint: trusted.fingerprint,
      capabilities: '',
      paired: true
    }
  }

  private connectReceiver(
    isRecovery: boolean = false,
    target?: DiscoveredSecondDisplayService
  ): void {
    this.cancelActiveTouch()
    if (!isRecovery) {
      this.cancelFastReconnect()
      this.reconnectDeadlineMs = 0
      const requestedTarget: DiscoveredSecondDisplayService | undefined =
        target === undefined ? this.manualTarget() : target
      if (requestedTarget === undefined || !requestedTarget.paired) {
        if (requestedTarget !== undefined) {
          this.applyConnectionCode('NET_PROTOCOL_MISMATCH: discovered Mac is not paired')
        }
        return
      }
      this.selectedTarget = requestedTarget
    }
    const activeTarget: DiscoveredSecondDisplayService | undefined = this.selectedTarget
    if (activeTarget === undefined) {
      this.applyConnectionCode('NET_PROTOCOL_MISMATCH: no Mac service was selected')
      return
    }
    this.discoveryController.stop()
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
      host: activeTarget.host,
      family: activeTarget.family,
      controlPort: activeTarget.controlPort,
      videoPort: activeTarget.videoPort,
      caPem: receiverNative.getPocCACertificate(),
      pinnedFingerprint: activeTarget.fingerprint,
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
      this.rediscoveryFingerprint = this.selectedTarget?.fingerprint ?? ''
      this.connectionCode = 'DISCONNECTED'
      this.startDiscovery()
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
    if (this.discoveryCode === 'DISCOVERY_SEARCHING') {
      return '正在搜索同一局域网中的 Second Display 服务'
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
          Text(`系统分辨率 ${this.systemDisplayWidth}×${this.systemDisplayHeight} · 最高 ${this.systemMaxFps} FPS · TLS 1.3`)
            .fontSize(12)
            .fontColor('#AFC4DC')

          if (this.discoveredServices.length > 0) {
            Column({ space: 6 }) {
              ForEach(this.discoveredServices, (service: DiscoveredSecondDisplayService) => {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text(service.name)
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Color.White)
                    Text(
                      `${service.host}:${service.controlPort} · ${service.fingerprint.slice(0, 8).toUpperCase()} · ${service.capabilities.length > 0 ? service.capabilities : 'h264'}`
                    )
                      .fontSize(10)
                      .fontColor('#AFC4DC')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Text(service.paired ? '已配对' : '需要配对')
                    .fontSize(10)
                    .fontColor(service.paired ? '#7DE2A8' : '#FFC879')
                  Button(service.paired ? '连接' : '配对')
                    .fontSize(12)
                    .fontColor(Color.White)
                    .backgroundColor(service.paired ? '#5B8DEF' : '#B57B2C')
                    .enabled(this.connectionCode !== 'CONNECTING'
                      && this.connectionCode !== 'TLS_CONNECTED')
                    .onClick(() => {
                      if (service.paired) {
                        this.connectReceiver(false, service)
                      } else {
                        this.beginPairing(service)
                      }
                    })
                  if (service.paired) {
                    Button('移除')
                      .fontSize(10)
                      .fontColor('#FFD0D0')
                      .backgroundColor('#38000000')
                      .onClick(() => this.removePairing(service))
                  }
                }
                .width('100%')
                .padding({ left: 12, right: 8, top: 7, bottom: 7 })
                .backgroundColor('#24000000')
                .borderRadius(10)
              }, (service: DiscoveredSecondDisplayService) => service.id)
            }
            .width('100%')
          } else {
            Text(this.discoveryCode.startsWith('NET_') ? this.discoveryCode : '暂未发现可用 Mac 服务')
              .fontSize(11)
              .fontColor(this.discoveryCode.startsWith('NET_') ? '#FFB9B9' : '#AFC4DC')
              .maxLines(2)
          }

          if (this.pendingPairingFingerprint.length === 64) {
            Column({ space: 7 }) {
              Text(`配对 ${this.pendingPairingName}`)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
              Text(`证书指纹 ${this.pendingPairingFingerprint.slice(0, 12).toUpperCase()}…`)
                .fontSize(10)
                .fontColor('#AFC4DC')
              Row({ space: 8 }) {
                TextInput({ text: this.pairingCodeInput, placeholder: 'XXXX-XXXX-XXXX 校验码' })
                  .fontSize(12)
                  .fontColor(Color.White)
                  .layoutWeight(1)
                  .backgroundColor('#26000000')
                  .onChange((value: string) => this.pairingCodeInput = value)
                Button('扫描二维码')
                  .fontSize(11)
                  .fontColor(Color.White)
                  .backgroundColor('#5B8DEF')
                  .onClick(() => this.scanPairingQRCode())
                Button('确认信任')
                  .fontSize(11)
                  .fontColor(Color.White)
                  .backgroundColor(this.pairingQrVerified || this.pairingCodeInput.length > 0
                    ? '#3A9D66' : '#46505E')
                  .enabled(this.pairingQrVerified || this.pairingCodeInput.length > 0)
                  .onClick(() => this.confirmPairing())
                Button('取消')
                  .fontSize(11)
                  .fontColor(Color.White)
                  .backgroundColor('#38000000')
                  .onClick(() => this.cancelPairing())
              }
              .width('100%')
              Text(this.pairingStatus)
                .fontSize(10)
                .fontColor(this.pairingStatus.startsWith('NET_') ? '#FFB9B9' : '#AFC4DC')
            }
            .width('100%')
            .padding(10)
            .backgroundColor('#30000000')
            .borderRadius(10)
          }

          Row({ space: 8 }) {
            TextInput({ text: this.manualHost, placeholder: '手动输入 Mac IP 地址' })
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor('#26000000')
              .layoutWeight(1)
              .onChange((value: string) => this.manualHost = value)
            Button('手动连接')
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor('#5B8DEF')
              .enabled(this.connectionCode !== 'CONNECTING' && this.connectionCode !== 'TLS_CONNECTED')
              .onClick(() => this.connectReceiver())
            Button('刷新')
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor('#38000000')
              .onClick(() => this.startDiscovery())
            Button('扫码配对')
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor('#B57B2C')
              .onClick(() => this.scanPairingQRCode())
          }
          .width('100%')

          if (this.trustedMacs.length > 1) {
            Row({ space: 6 }) {
              Text('手动连接身份')
                .fontSize(10)
                .fontColor('#AFC4DC')
              ForEach(this.trustedMacs, (trusted: TrustedMac) => {
                Button(`${trusted.name} · ${trusted.fingerprint.slice(0, 8).toUpperCase()}`)
                  .fontSize(9)
                  .fontColor(Color.White)
                  .backgroundColor(trusted.fingerprint === this.manualTrustedFingerprint
                    ? '#5B8DEF' : '#38000000')
                  .onClick(() => this.manualTrustedFingerprint = trusted.fingerprint)
              }, (trusted: TrustedMac) => trusted.fingerprint)
            }
            .width('100%')
          }

          if (this.connectionCode.startsWith('NET_')) {
            Text(this.connectionCode)
              .fontSize(10)
              .fontColor('#FFB9B9')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Center)
        .width('68%')
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
