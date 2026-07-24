import { describe, expect, it } from '@ohos/hypium'
import {
  canPromoteSurfaceReady,
  isConnectionAttemptPending
} from '../../../main/ets/services/ConnectionRecoveryPolicy'

export default function connectionRecoveryPolicyTest(): void {
  describe('ConnectionRecoveryPolicy', () => {
    it('protectsEveryConnectionStageWithTimeout', 0, () => {
      expect(isConnectionAttemptPending('CONNECTING')).assertTrue()
      expect(isConnectionAttemptPending('TLS_CONNECTED')).assertTrue()
      expect(isConnectionAttemptPending('WAITING_SURFACE')).assertTrue()
      expect(isConnectionAttemptPending('STREAM_READY')).assertFalse()
    })

    it('promotesOnlyTheCurrentSurfaceWaitingSession', 0, () => {
      expect(canPromoteSurfaceReady('WAITING_SURFACE', true, 'READY')).assertTrue()
      expect(canPromoteSurfaceReady('WAITING_SURFACE', true, 'STREAM_READY')).assertTrue()
      expect(canPromoteSurfaceReady('CONNECTING', true, 'READY')).assertFalse()
      expect(canPromoteSurfaceReady('WAITING_SURFACE', false, 'READY')).assertFalse()
    })
  })
}
