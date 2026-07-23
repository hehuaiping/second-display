import { common } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'

export interface TrustedMac {
  fingerprint: string
  name: string
  pairedAtMs: number
}

interface StoredTrustDocument {
  version: number
  devices: TrustedMac[]
}

export interface PairingPayload {
  type: string
  version: number
  fingerprint: string
  name: string
}

const STORE_NAME: string = 'second_display_pairing'
const TRUST_DOCUMENT_KEY: string = 'trusted_macs'
const TRUST_SCHEMA_VERSION_KEY: string = 'schema_version'
const TRUST_SCHEMA_VERSION: number = 2
const MAX_TRUSTED_MACS: number = 32

export function normalizePairingFingerprint(value: string): string {
  const normalized: string = value.replace(/:/g, '').replace(/-/g, '').trim().toLowerCase()
  if (normalized.length !== 64 || !/^[0-9a-f]+$/.test(normalized)) return ''
  return normalized
}

/// 校验码来自完整证书指纹，只用于人工核对；二维码仍携带完整 256 位信任锚。
export function pairingVerificationCode(fingerprint: string): string {
  const normalized: string = normalizePairingFingerprint(fingerprint)
  if (normalized.length !== 64) return ''
  return `${normalized.slice(0, 4)}-${normalized.slice(4, 8)}-${normalized.slice(8, 12)}`.toUpperCase()
}

export function parsePairingPayload(value: string): PairingPayload | undefined {
  try {
    const parsed: PairingPayload = JSON.parse(value) as PairingPayload
    const fingerprint: string = normalizePairingFingerprint(parsed.fingerprint)
    if (parsed.type !== 'second-display-pairing' || parsed.version !== 1
      || fingerprint.length !== 64 || typeof parsed.name !== 'string') {
      return undefined
    }
    return {
      type: parsed.type,
      version: parsed.version,
      fingerprint: fingerprint,
      name: parsed.name.trim().slice(0, 63)
    }
  } catch (error) {
    return undefined
  }
}

/// 仅保存公开证书指纹，不保存私钥或会话密钥；应用沙箱内 Preferences 足以承载该信任清单。
export class PairingTrustStore {
  async load(context: common.UIAbilityContext): Promise<TrustedMac[]> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(
        context,
        { name: STORE_NAME }
      )
      const schemaValue: preferences.ValueType = await store.get(TRUST_SCHEMA_VERSION_KEY, 0)
      const schemaVersion: number = typeof schemaValue === 'number' ? schemaValue : 0
      if (schemaVersion !== TRUST_SCHEMA_VERSION) {
        // 版本 1 曾自动信任内置 POC 证书。发行版升级时必须撤销该信任，要求用户重新配对。
        await this.write(store, [])
        await store.put(TRUST_SCHEMA_VERSION_KEY, TRUST_SCHEMA_VERSION)
        await store.flush()
        return []
      }
      const encodedValue: preferences.ValueType = await store.get(TRUST_DOCUMENT_KEY, '')
      if (typeof encodedValue !== 'string') return []
      return this.decode(encodedValue)
    } catch (error) {
      throw new Error('NET_PROTOCOL_MISMATCH: unable to load paired Macs')
    }
  }

  async trust(
    context: common.UIAbilityContext,
    current: TrustedMac[],
    fingerprintValue: string,
    nameValue: string
  ): Promise<TrustedMac[]> {
    const fingerprint: string = normalizePairingFingerprint(fingerprintValue)
    if (fingerprint.length !== 64) {
      throw new Error('NET_PROTOCOL_MISMATCH: pairing fingerprint is invalid')
    }
    const name: string = nameValue.trim().length > 0 ? nameValue.trim().slice(0, 63) : 'Second Display Mac'
    const next: TrustedMac[] = current
      .filter((value: TrustedMac) => value.fingerprint !== fingerprint)
      .concat([{ fingerprint: fingerprint, name: name, pairedAtMs: Date.now() }])
      .sort((lhs: TrustedMac, rhs: TrustedMac) => rhs.pairedAtMs - lhs.pairedAtMs)
      .slice(0, MAX_TRUSTED_MACS)
    try {
      const store: preferences.Preferences = await preferences.getPreferences(
        context,
        { name: STORE_NAME }
      )
      await this.write(store, next)
      await store.put(TRUST_SCHEMA_VERSION_KEY, TRUST_SCHEMA_VERSION)
      await store.flush()
      return next
    } catch (error) {
      throw new Error('NET_PROTOCOL_MISMATCH: unable to save paired Mac')
    }
  }

  async remove(
    context: common.UIAbilityContext,
    current: TrustedMac[],
    fingerprintValue: string
  ): Promise<TrustedMac[]> {
    const fingerprint: string = normalizePairingFingerprint(fingerprintValue)
    const next: TrustedMac[] = current.filter(
      (value: TrustedMac) => value.fingerprint !== fingerprint
    )
    try {
      const store: preferences.Preferences = await preferences.getPreferences(
        context,
        { name: STORE_NAME }
      )
      await this.write(store, next)
      await store.put(TRUST_SCHEMA_VERSION_KEY, TRUST_SCHEMA_VERSION)
      await store.flush()
      return next
    } catch (error) {
      throw new Error('NET_PROTOCOL_MISMATCH: unable to remove paired Mac')
    }
  }

  private async write(store: preferences.Preferences, devices: TrustedMac[]): Promise<void> {
    try {
      const document: StoredTrustDocument = { version: TRUST_SCHEMA_VERSION, devices: devices }
      await store.put(TRUST_DOCUMENT_KEY, JSON.stringify(document))
    } catch (error) {
      throw new Error('NET_PROTOCOL_MISMATCH: unable to encode pairing trust')
    }
  }

  private decode(value: string): TrustedMac[] {
    if (value.length === 0 || value.length > 64 * 1024) return []
    try {
      const document: StoredTrustDocument = JSON.parse(value) as StoredTrustDocument
      if (document.version !== TRUST_SCHEMA_VERSION || !Array.isArray(document.devices)) return []
      const result: TrustedMac[] = []
      for (const candidate of document.devices.slice(0, MAX_TRUSTED_MACS)) {
        const fingerprint: string = normalizePairingFingerprint(candidate.fingerprint)
        if (fingerprint.length !== 64 || typeof candidate.name !== 'string'
          || typeof candidate.pairedAtMs !== 'number' || !Number.isFinite(candidate.pairedAtMs)) {
          continue
        }
        if (result.some((value: TrustedMac) => value.fingerprint === fingerprint)) continue
        result.push({
          fingerprint: fingerprint,
          name: candidate.name.trim().slice(0, 63),
          pairedAtMs: candidate.pairedAtMs
        })
      }
      return result
    } catch (error) {
      return []
    }
  }
}
