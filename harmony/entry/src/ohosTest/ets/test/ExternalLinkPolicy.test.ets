import { describe, expect, it } from '@ohos/hypium'
import {
  APP_LINK_OPEN_FAILED,
  canOpenMacServerWebsite,
  isCurrentExternalLinkOperation,
  MAC_SERVER_WEBSITE
} from '../../../main/ets/services/ExternalLinkPolicy'

export default function externalLinkPolicyTest(): void {
  describe('ExternalLinkPolicy', () => {
    it('usesTheCanonicalSecureMacDownloadAddress', 0, () => {
      expect(MAC_SERVER_WEBSITE).assertEqual('https://second-display.cuihua.cloud')
      expect(APP_LINK_OPEN_FAILED).assertEqual('APP_LINK_OPEN_FAILED')
    })

    it('requiresPrivacyConsentAndRejectsRepeatedTaps', 0, () => {
      expect(canOpenMacServerWebsite(false, false)).assertFalse()
      expect(canOpenMacServerWebsite(true, true)).assertFalse()
      expect(canOpenMacServerWebsite(true, false)).assertTrue()
    })

    it('ignoresStaleOrInactivePageCallbacks', 0, () => {
      expect(isCurrentExternalLinkOperation(3, 3, true)).assertTrue()
      expect(isCurrentExternalLinkOperation(2, 3, true)).assertFalse()
      expect(isCurrentExternalLinkOperation(3, 3, false)).assertFalse()
    })
  })
}
