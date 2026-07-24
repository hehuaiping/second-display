/// 连接建立阶段需要由超时看门狗保护，避免 TLS 或 Surface 回调缺失后界面永久停留。
export function isConnectionAttemptPending(code: string): boolean {
  return code === 'CONNECTING' || code === 'TLS_CONNECTED' || code === 'WAITING_SURFACE'
}

/// serverReady 可能先于旋转后的 SurfaceCreated 到达；Surface 后续就绪时允许状态收敛。
export function canPromoteSurfaceReady(
  connectionCode: string,
  decoderRunning: boolean,
  decoderCode: string
): boolean {
  return connectionCode === 'WAITING_SURFACE' && decoderRunning
    && (decoderCode === 'READY' || decoderCode === 'STREAM_READY')
}
