import { MessageEvents, ThreadWorkerGlobalScope, util, worker } from '@kit.ArkTS'
import { socket } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import receiverNative, { DecoderStatus } from 'libentry.so'

interface ConnectCommand {
  type: string
  host: string
  family: number
  controlPort: number
  videoPort: number
  pinnedFingerprint: string
  displayWidth: number
  displayHeight: number
  maxFps: number
  deviceId: string
  orientation: string
  codecs: string[]
}

interface WorkerStatus {
  type: string
  code: string
}

interface InputCommand {
  type: string
  eventType: string
  normalizedX?: number
  normalizedY?: number
  deltaX?: number
  deltaY?: number
  fingerCount?: number
  gestureType?: string
  direction?: string
  magnitude?: number
}

interface ReceiverFeedbackCommand {
  type: string
  decoderQueueDepth: number
  droppedFrames: number
  renderedFramesPerSecond: number
  networkType: string
}

interface WorkerCursorPosition {
  type: string
  sessionId: string
  sequence: number
  normalizedX: number
  normalizedY: number
  visible: boolean
}

interface ControlEnvelope {
  type: string
  protocolVersion: number
  sessionId: string
  sequence: number
  sentAtUs: number
  stream?: StreamConfiguration
  normalizedX?: number
  normalizedY?: number
  visible?: boolean
}

interface StreamConfiguration {
  codec: string
  width: number
  height: number
  fps: number
  transport?: string
}

const workerPort: ThreadWorkerGlobalScope = worker.workerPort
const encoder: util.TextEncoder = new util.TextEncoder()
const decoder: util.TextDecoder = new util.TextDecoder()
let controlSocket: socket.TLSSocket | undefined = undefined
let videoSocket: socket.TLSSocket | undefined = undefined
let controlBuffer: Uint8Array = new Uint8Array(0)
let sessionId: string = ''
// 每次连接或停止都推进 generation；Socket Promise 和事件回调只处理创建它们的那一代。
let generation: number = 0
let keyFrameRequestSequence: number = 0
let observedKeyFrameRequests: number = 0
let sendingKeyFrameRequestCount: number = 0
let lastCursorSequence: number = -1
let inputSequence: number = 0
let feedbackSequence: number = 0

function normalizeFingerprint(value: string): string {
  const normalized: string = value.replace(/:/g, '').replace(/-/g, '').trim().toLowerCase()
  if (normalized.length !== 64 || !/^[0-9a-f]+$/.test(normalized)) return ''
  return normalized
}

async function fingerprintBytes(bytes: Uint8Array): Promise<string> {
  try {
    const digest = cryptoFramework.createMd('SHA256')
    await digest.update({ data: bytes })
    const result = await digest.digest()
    return Array.from(result.data)
      .map((byte: number) => byte.toString(16).padStart(2, '0'))
      .join('')
  } catch (error) {
    throw new Error('certificate fingerprint calculation failed')
  }
}

async function verifyPinnedCertificates(
  control: socket.TLSSocket,
  video: socket.TLSSocket,
  command: ConnectCommand,
  activeGeneration: number
): Promise<void> {
  if (activeGeneration !== generation) throw new Error('stale connection generation')
  const pairedFingerprint: string = normalizeFingerprint(command.pinnedFingerprint)
  if (pairedFingerprint.length !== 64) throw new Error('paired certificate fingerprint is invalid')
  let certificates: socket.X509CertRawData[]
  try {
    certificates = await Promise.all([
      control.getRemoteCertificate(),
      video.getRemoteCertificate()
    ])
  } catch (error) {
    throw new Error('unable to read remote TLS certificate')
  }
  if (activeGeneration !== generation) throw new Error('stale connection generation')
  const fingerprints: string[] = await Promise.all([
    fingerprintBytes(certificates[0].data),
    fingerprintBytes(certificates[1].data)
  ])
  if (fingerprints[0] !== fingerprints[1]
    || fingerprints[0] !== pairedFingerprint) {
    throw new Error('remote certificate fingerprint does not match paired Mac')
  }
}

function postStatus(code: string): void {
  const status: WorkerStatus = { type: 'status', code: code }
  try {
    workerPort.postMessage(status)
  } catch (error) {
    return
  }
}

function concatenate(first: Uint8Array, second: Uint8Array): Uint8Array {
  const combined: Uint8Array = new Uint8Array(first.length + second.length)
  combined.set(first, 0)
  combined.set(second, first.length)
  return combined
}

function frameControlMessage(value: string): ArrayBuffer {
  // 控制通道采用 4 字节大端长度前缀，接收侧同样在解析前执行 64 KiB 上限检查。
  const payload: Uint8Array = encoder.encodeInto(value)
  const framed: Uint8Array = new Uint8Array(payload.length + 4)
  framed[0] = (payload.length >>> 24) & 0xFF
  framed[1] = (payload.length >>> 16) & 0xFF
  framed[2] = (payload.length >>> 8) & 0xFF
  framed[3] = payload.length & 0xFF
  framed.set(payload, 4)
  return framed.buffer
}

function sendClientHello(command: ConnectCommand, activeGeneration: number): void {
  if (activeGeneration !== generation || controlSocket === undefined) {
    return
  }
  const hello: string = JSON.stringify({
    type: 'clientHello',
    protocolVersion: 1,
    deviceId: command.deviceId,
    deviceName: 'HarmonyOS Receiver',
    nativeWidth: command.displayWidth,
    nativeHeight: command.displayHeight,
    deviceScale: 2,
    maxFps: command.maxFps,
    codecs: command.codecs,
    maxDecodeWidth: command.displayWidth,
    maxDecodeHeight: command.displayHeight,
    orientation: command.orientation,
    // 不声明 cursorSideChannelV1，让原始 macOS 光标随视频编码，避免双光标和位置不同步。
    features: ['dynamicStreamV1', 'networkMigrationV1', 'multiDisplayV1'],
    videoTransports: ['tlsTcp']
  })
  controlSocket.send(frameControlMessage(hello)).catch(() => postStatus('NET_PROTOCOL_MISMATCH: hello send failed'))
}

function postCursorPosition(message: ControlEnvelope, activeGeneration: number): void {
  if (activeGeneration !== generation || message.sessionId !== sessionId
    || !Number.isSafeInteger(message.sequence) || message.sequence <= lastCursorSequence
    || message.normalizedX === undefined || message.normalizedY === undefined
    || !Number.isFinite(message.normalizedX) || !Number.isFinite(message.normalizedY)
    || message.normalizedX < 0 || message.normalizedX > 1
    || message.normalizedY < 0 || message.normalizedY > 1
    || message.visible === undefined) {
    return
  }
  lastCursorSequence = message.sequence
  const cursor: WorkerCursorPosition = {
    type: 'cursorPosition',
    sessionId: sessionId,
    sequence: message.sequence,
    normalizedX: message.normalizedX,
    normalizedY: message.normalizedY,
    visible: message.visible
  }
  try {
    workerPort.postMessage(cursor)
  } catch (error) {
    return
  }
}

function sendHeartbeatAck(message: ControlEnvelope, activeGeneration: number): void {
  if (activeGeneration !== generation || controlSocket === undefined || message.sessionId !== sessionId) {
    return
  }
  const acknowledgement: string = JSON.stringify({
    type: 'heartbeatAck',
    protocolVersion: 1,
    sessionId: sessionId,
    sequence: message.sequence,
    sentAtUs: message.sentAtUs,
    receivedAtUs: Date.now() * 1000
  })
  controlSocket.send(frameControlMessage(acknowledgement))
    .catch(() => postStatus('NET_PROTOCOL_MISMATCH: heartbeat acknowledgement failed'))
}

function sendInputEvent(command: InputCommand, activeGeneration: number): void {
  if (activeGeneration !== generation || controlSocket === undefined || sessionId.length === 0) {
    return
  }
  const allowed: boolean = command.eventType === 'move' || command.eventType === 'leftDown'
    || command.eventType === 'leftUp' || command.eventType === 'drag' || command.eventType === 'scroll'
  if (!allowed) return
  const hasPosition: boolean = command.normalizedX !== undefined && command.normalizedY !== undefined
    && Number.isFinite(command.normalizedX) && Number.isFinite(command.normalizedY)
  if (command.eventType !== 'scroll' && !hasPosition) return
  const normalizedX: number | undefined = hasPosition
    ? Math.min(Math.max(command.normalizedX as number, 0), 1) : undefined
  const normalizedY: number | undefined = hasPosition
    ? Math.min(Math.max(command.normalizedY as number, 0), 1) : undefined
  const deltaX: number = command.deltaX !== undefined && Number.isFinite(command.deltaX) ? command.deltaX : 0
  const deltaY: number = command.deltaY !== undefined && Number.isFinite(command.deltaY) ? command.deltaY : 0
  inputSequence += 1
  const message: string = JSON.stringify({
    type: 'inputEvent',
    protocolVersion: 1,
    sessionId: sessionId,
    sequence: inputSequence,
    eventType: command.eventType,
    normalizedX: normalizedX,
    normalizedY: normalizedY,
    deltaX: deltaX,
    deltaY: deltaY
  })
  controlSocket.send(frameControlMessage(message))
    .catch(() => postStatus('NET_PROTOCOL_MISMATCH: input event send failed'))
}

function sendGestureEvent(command: InputCommand, activeGeneration: number): void {
  if (activeGeneration !== generation || controlSocket === undefined || sessionId.length === 0
    || command.fingerCount === undefined || command.fingerCount < 3 || command.fingerCount > 5
    || !Number.isSafeInteger(command.fingerCount)
    || (command.gestureType !== 'swipe' && command.gestureType !== 'pinch')
    || command.direction === undefined
    || command.magnitude === undefined || !Number.isFinite(command.magnitude) || command.magnitude < 0) {
    return
  }
  const swipeDirection: boolean = command.direction === 'up' || command.direction === 'down'
    || command.direction === 'left' || command.direction === 'right'
  const pinchDirection: boolean = command.direction === 'in' || command.direction === 'out'
  if ((command.gestureType === 'swipe' && !swipeDirection)
    || (command.gestureType === 'pinch' && !pinchDirection)) return
  inputSequence += 1
  const message: string = JSON.stringify({
    type: 'gestureEvent',
    protocolVersion: 1,
    sessionId: sessionId,
    sequence: inputSequence,
    fingerCount: command.fingerCount,
    gestureType: command.gestureType,
    direction: command.direction,
    magnitude: command.magnitude
  })
  controlSocket.send(frameControlMessage(message)).catch(() => {
    if (activeGeneration === generation) postStatus('NET_PROTOCOL_MISMATCH: gesture event send failed')
  })
}

function sendKeyFrameRequest(activeGeneration: number, nativeRequestCount: number): void {
  if (activeGeneration !== generation || controlSocket === undefined || sessionId.length === 0
    || nativeRequestCount <= observedKeyFrameRequests || nativeRequestCount <= sendingKeyFrameRequestCount) {
    return
  }
  sendingKeyFrameRequestCount = nativeRequestCount
  keyFrameRequestSequence += 1
  const request: string = JSON.stringify({
    type: 'requestKeyFrame',
    protocolVersion: 1,
    sessionId: sessionId,
    sequence: keyFrameRequestSequence,
    reason: 'decoderRecovery'
  })
  controlSocket.send(frameControlMessage(request)).then(() => {
    if (activeGeneration !== generation) return
    observedKeyFrameRequests = Math.max(observedKeyFrameRequests, nativeRequestCount)
    sendingKeyFrameRequestCount = observedKeyFrameRequests
  }).catch(() => {
    if (activeGeneration !== generation) return
    sendingKeyFrameRequestCount = observedKeyFrameRequests
    postStatus('NET_PROTOCOL_MISMATCH: key frame request failed')
  })
}

function sendReceiverFeedback(command: ReceiverFeedbackCommand, activeGeneration: number): void {
  if (activeGeneration !== generation || controlSocket === undefined || sessionId.length === 0) return
  feedbackSequence += 1
  const feedback: string = JSON.stringify({
    type: 'receiverFeedback',
    protocolVersion: 1,
    sessionId: sessionId,
    sequence: feedbackSequence,
    decoderQueueDepth: Math.max(0, Math.min(Math.floor(command.decoderQueueDepth), 64)),
    droppedFrames: Math.max(0, Math.floor(command.droppedFrames)),
    renderedFramesPerSecond: Math.max(0, Math.min(command.renderedFramesPerSecond, 240)),
    networkType: command.networkType.length > 0 ? command.networkType : 'unknown'
  })
  controlSocket.send(frameControlMessage(feedback)).catch(() => {
    if (activeGeneration === generation) {
      postStatus('NET_PROTOCOL_MISMATCH: receiver feedback send failed')
    }
  })
}

function handleControlPayload(payload: Uint8Array, activeGeneration: number): void {
  if (activeGeneration !== generation) {
    return
  }
  const json: string = decoder.decodeToString(payload)
  const message: ControlEnvelope = JSON.parse(json) as ControlEnvelope
  if (message.protocolVersion !== 1) {
    postStatus('NET_PROTOCOL_MISMATCH: unsupported protocol version')
    return
  }
  if (message.type === 'serverReady') {
    if (message.sessionId.length === 0 || message.stream === undefined
      || message.stream.width < 1 || message.stream.height < 1 || message.stream.fps < 1
      || (message.stream.codec !== 'h264' && message.stream.codec !== 'hevc')
      || (message.stream.transport !== undefined && message.stream.transport !== 'tlsTcp')) {
      postStatus('NET_PROTOCOL_MISMATCH: invalid server ready configuration')
      return
    }
    sessionId = message.sessionId
    const status: DecoderStatus = receiverNative.beginVideoSession(
      sessionId,
      message.stream.width,
      message.stream.height,
      message.stream.fps,
      message.stream.codec
    )
    observedKeyFrameRequests = status.keyFrameRequests
    sendingKeyFrameRequestCount = status.keyFrameRequests
    keyFrameRequestSequence = 0
    inputSequence = 0
    lastCursorSequence = -1
    postStatus(status.running ? 'STREAM_READY' : status.code)
  } else if (message.type === 'cursorPosition') {
    postCursorPosition(message, activeGeneration)
  } else if (message.type === 'heartbeat') {
    sendHeartbeatAck(message, activeGeneration)
  } else if (message.type === 'error') {
    postStatus('NET_PROTOCOL_MISMATCH: server rejected session')
  }
}

function receiveControl(bytes: ArrayBuffer, activeGeneration: number): void {
  if (activeGeneration !== generation) {
    return
  }
  controlBuffer = concatenate(controlBuffer, new Uint8Array(bytes))
  while (controlBuffer.length >= 4) {
    const length: number = ((controlBuffer[0] << 24) >>> 0)
      + (controlBuffer[1] << 16) + (controlBuffer[2] << 8) + controlBuffer[3]
    if (length > 64 * 1024) {
      postStatus('NET_PROTOCOL_MISMATCH: control message exceeds 64 KiB')
      return
    }
    if (controlBuffer.length < length + 4) {
      return
    }
    const payload: Uint8Array = controlBuffer.slice(4, length + 4)
    controlBuffer = controlBuffer.slice(length + 4)
    try {
      handleControlPayload(payload, activeGeneration)
    } catch (error) {
      postStatus('NET_PROTOCOL_MISMATCH: invalid control JSON')
      return
    }
  }
}

async function closeSockets(activeGeneration: number): Promise<void> {
  if (activeGeneration !== generation) {
    return
  }
  const oldControl: socket.TLSSocket | undefined = controlSocket
  const oldVideo: socket.TLSSocket | undefined = videoSocket
  // 先摘除全局引用和事件监听，再异步关闭 Socket，迟到事件无法影响下一次连接。
  controlSocket = undefined
  videoSocket = undefined
  if (sessionId.length > 0) {
    receiverNative.finishVideoSession(sessionId)
  }
  sessionId = ''
  observedKeyFrameRequests = 0
  sendingKeyFrameRequestCount = 0
  keyFrameRequestSequence = 0
  feedbackSequence = 0
  inputSequence = 0
  lastCursorSequence = -1
  controlBuffer = new Uint8Array(0)
  if (oldControl !== undefined) {
    oldControl.off('message')
    oldControl.off('close')
    oldControl.off('error')
    await oldControl.close().catch(() => {})
  }
  if (oldVideo !== undefined) {
    oldVideo.off('message')
    oldVideo.off('close')
    oldVideo.off('error')
    await oldVideo.close().catch(() => {})
  }
}

async function connect(command: ConnectCommand): Promise<void> {
  // 新连接先使上一代失效；后续每个 Promise continuation 都用 activeGeneration 自证身份。
  generation += 1
  const activeGeneration: number = generation
  await closeSockets(activeGeneration)
  if (normalizeFingerprint(command.pinnedFingerprint).length !== 64) {
    postStatus('NET_PROTOCOL_MISMATCH: paired certificate fingerprint is unavailable')
    return
  }
  if (command.family !== 1 && command.family !== 2) {
    postStatus('NET_PROTOCOL_MISMATCH: invalid network address family')
    return
  }
  if (Math.min(command.displayWidth, command.displayHeight) < 600
    || Math.max(command.displayWidth, command.displayHeight) < 800
    || command.displayWidth > 8192 || command.displayHeight > 8192
    || command.displayWidth % 2 !== 0 || command.displayHeight % 2 !== 0) {
    postStatus('NET_PROTOCOL_MISMATCH: invalid system display resolution')
    return
  }
  const control: socket.TLSSocket = socket.constructTLSSocketInstance()
  const video: socket.TLSSocket = socket.constructTLSSocketInstance()
  controlSocket = control
  videoSocket = video
  try {
    const localAddress: string = command.family === 2 ? '::' : '0.0.0.0'
    await Promise.all([
      control.bind({ address: localAddress, family: command.family, port: 0 }),
      video.bind({ address: localAddress, family: command.family, port: 0 })
    ])
    const secureOptions: socket.TLSSecureOptions = {
      protocols: socket.Protocol.TLSv13
    }
    await Promise.all([
      control.connect({
        address: { address: command.host, family: command.family, port: command.controlPort },
        secureOptions: secureOptions,
        // 动态地址可能不在旧证书 SAN 中；连接后、发送任何协议数据前执行精确证书固定。
        skipRemoteValidation: true
      }),
      video.connect({
        address: { address: command.host, family: command.family, port: command.videoPort },
        secureOptions: secureOptions,
        skipRemoteValidation: true
      })
    ])
    await verifyPinnedCertificates(control, video, command, activeGeneration)
    // 控制与视频分离，视频突发或拥塞时不会阻塞输入、心跳和关键帧请求。
    await Promise.all([
      control.setExtraOptions({ TCPNoDelay: true, keepAlive: true }),
      video.setExtraOptions({ TCPNoDelay: true, keepAlive: true })
    ])
    control.on('message', (info: socket.SocketMessageInfo) => receiveControl(info.message, activeGeneration))
    control.on('close', () => {
      if (activeGeneration === generation) postStatus('DISCONNECTED')
    })
    control.on('error', () => {
      if (activeGeneration === generation) postStatus('NET_PROTOCOL_MISMATCH: control TLS error')
    })
    video.on('message', (info: socket.SocketMessageInfo) => {
      if (activeGeneration === generation && sessionId.length > 0) {
        const status: DecoderStatus = receiverNative.feedVideoBytes(sessionId, new Uint8Array(info.message))
        sendKeyFrameRequest(activeGeneration, status.keyFrameRequests)
      }
    })
    video.on('close', () => {
      if (activeGeneration === generation) postStatus('DISCONNECTED')
    })
    video.on('error', () => {
      if (activeGeneration === generation) postStatus('NET_PROTOCOL_MISMATCH: video TLS error')
    })
    if (activeGeneration !== generation) {
      return
    }
    postStatus('TLS_CONNECTED')
    sendClientHello(command, activeGeneration)
  } catch (error) {
    if (activeGeneration === generation) {
      const failure: BusinessError = error as BusinessError
      postStatus(`NET_PROTOCOL_MISMATCH: TLS connect failed (${failure.code}: ${failure.message})`)
      await closeSockets(activeGeneration)
    }
  }
}

workerPort.onmessage = (event: MessageEvents): void => {
  const type: string = (event.data as InputCommand).type
  if (type === 'connect') {
    connect(event.data as ConnectCommand)
  } else if (type === 'inputEvent') {
    sendInputEvent(event.data as InputCommand, generation)
  } else if (type === 'gestureEvent') {
    sendGestureEvent(event.data as InputCommand, generation)
  } else if (type === 'receiverFeedback') {
    sendReceiverFeedback(event.data as ReceiverFeedbackCommand, generation)
  } else if (type === 'stop') {
    generation += 1
    const activeGeneration: number = generation
    closeSockets(activeGeneration).then(() => {
      postStatus('STOPPED')
      workerPort.close()
    })
  }
}
