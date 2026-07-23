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
  decoderInFlight: number;
  keyFrameRequests: number;
  decoderRecoveries: number;
  lowLatencyEnabled: boolean;
  immediateRenderingEnabled: boolean;
}

interface ReceiverNative {
  getDecoderStatus(): DecoderStatus;
  restartDecoder(): DecoderStatus;
  stopDecoder(): DecoderStatus;
  startDecoderSoak(durationSeconds: number): DecoderStatus;
  stopDecoderSoak(): DecoderStatus;
  beginVideoSession(
    sessionId: string,
    width: number,
    height: number,
    framesPerSecond: number,
    codec?: string
  ): DecoderStatus;
  feedVideoBytes(sessionId: string, bytes: Uint8Array): DecoderStatus;
  finishVideoSession(sessionId: string): DecoderStatus;
  getPocCACertificate(): string;
  getH264DecoderMaxFps(width: number, height: number): number;
  getHEVCDecoderMaxFps(width: number, height: number): number;
}

declare const receiverNative: ReceiverNative;
export default receiverNative;
