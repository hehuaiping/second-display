export interface DecoderStatus {
  code: string;
  running: boolean;
  generation: number;
  testFrames: number;
  droppedFrames: number;
  networkFrames: number;
  decodedFrames: number;
  renderedFrames: number;
  staleOutputDrops: number;
  inputQueueLatencyUs: number;
  decodeLatencyUs: number;
  outputLatencyUs: number;
  decodeOutputP95Us: number;
  decoderInFlight: number;
  displayFrames: number;
  displayFramesPerSecond: number;
  displayIntervalP95Us: number;
  keyFrameRequests: number;
  decoderRecoveries: number;
  lowLatencyEnabled: boolean;
  immediateRenderingEnabled: boolean;
  timedRenderingEnabled: boolean;
  boundedBufferCountsEnabled: boolean;
  displayFrameSamplingEnabled: boolean;
  expectedFrameRateApplied: boolean;
}

interface ReceiverNative {
  getDecoderStatus(): DecoderStatus;
  restartDecoder(): DecoderStatus;
  stopDecoder(): DecoderStatus;
  beginVideoSession(
    sessionId: string,
    width: number,
    height: number,
    framesPerSecond: number,
    codec?: string
  ): DecoderStatus;
  feedVideoBytes(sessionId: string, bytes: Uint8Array): DecoderStatus;
  finishVideoSession(sessionId: string): DecoderStatus;
  getH264DecoderMaxFps(width: number, height: number): number;
  getHEVCDecoderMaxFps(width: number, height: number): number;
}

declare const receiverNative: ReceiverNative;
export default receiverNative;
