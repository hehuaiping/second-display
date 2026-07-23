import { common } from '@kit.AbilityKit'
import { mdns } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'

export interface DiscoveredSecondDisplayService {
  id: string
  sourceName: string
  name: string
  host: string
  family: number
  controlPort: number
  videoPort: number
  fingerprint: string
  capabilities: string
  paired: boolean
}

type ServiceListCallback = (services: DiscoveredSecondDisplayService[]) => void
type DiscoveryStatusCallback = (status: string) => void
type LocalServiceCallback = (serviceInfo: mdns.LocalServiceInfo) => void
type DiscoveryEventCallback = (eventInfo: mdns.DiscoveryEventInfo) => void

const SERVICE_TYPE: string = '_seconddisplay._tcp'

function normalizeFingerprint(value: string): string {
  const normalized: string = value.replace(/:/g, '').replace(/-/g, '').trim().toLowerCase()
  if (normalized.length !== 64 || !/^[0-9a-f]+$/.test(normalized)) return ''
  return normalized
}

/// 管理一次可取消的 mDNS 搜索；所有异步解析结果都必须匹配创建它的 generation。
export class ServiceDiscoveryController {
  private generation: number = 0
  private discovery: mdns.DiscoveryService | undefined = undefined
  private context: common.UIAbilityContext | undefined = undefined
  private services: DiscoveredSecondDisplayService[] = []
  private pairedFingerprints: Set<string> = new Set<string>()
  private onUpdate: ServiceListCallback | undefined = undefined
  private onStatus: DiscoveryStatusCallback | undefined = undefined
  private onFound: LocalServiceCallback | undefined = undefined
  private onLost: LocalServiceCallback | undefined = undefined
  private onStarted: DiscoveryEventCallback | undefined = undefined
  private onStopped: DiscoveryEventCallback | undefined = undefined

  isActive(): boolean {
    return this.discovery !== undefined
  }

  start(
    context: common.UIAbilityContext,
    pairedFingerprints: string[],
    onUpdate: ServiceListCallback,
    onStatus: DiscoveryStatusCallback
  ): void {
    this.stop()
    this.context = context
    this.pairedFingerprints = new Set<string>(
      pairedFingerprints.map((value: string) => normalizeFingerprint(value))
        .filter((value: string) => value.length === 64)
    )
    this.onUpdate = onUpdate
    this.onStatus = onStatus
    this.services = []
    const activeGeneration: number = this.generation
    try {
      const discovery: mdns.DiscoveryService = mdns.createDiscoveryService(context, SERVICE_TYPE)
      this.discovery = discovery
      this.onFound = (serviceInfo: mdns.LocalServiceInfo): void => {
        this.resolve(serviceInfo, activeGeneration)
      }
      this.onLost = (serviceInfo: mdns.LocalServiceInfo): void => {
        this.remove(serviceInfo, activeGeneration)
      }
      this.onStarted = (eventInfo: mdns.DiscoveryEventInfo): void => {
        if (activeGeneration !== this.generation) return
        if (eventInfo.errorCode !== undefined) {
          this.publishStatus('NET_PROTOCOL_MISMATCH: LAN discovery failed to start')
        } else {
          this.publishStatus('DISCOVERY_SEARCHING')
        }
      }
      this.onStopped = (eventInfo: mdns.DiscoveryEventInfo): void => {
        if (activeGeneration !== this.generation || eventInfo.errorCode === undefined) return
        this.publishStatus('NET_PROTOCOL_MISMATCH: LAN discovery stopped unexpectedly')
      }
      discovery.on('serviceFound', this.onFound)
      discovery.on('serviceLost', this.onLost)
      discovery.on('discoveryStart', this.onStarted)
      discovery.on('discoveryStop', this.onStopped)
      discovery.startSearchingMDNS()
      this.publish()
    } catch (error) {
      if (activeGeneration === this.generation) {
        this.publishStatus('NET_PROTOCOL_MISMATCH: unable to start LAN discovery')
      }
      this.stop()
    }
  }

  stop(): void {
    this.generation += 1
    const discovery: mdns.DiscoveryService | undefined = this.discovery
    this.discovery = undefined
    if (discovery !== undefined) {
      try {
        if (this.onFound !== undefined) discovery.off('serviceFound', this.onFound)
        if (this.onLost !== undefined) discovery.off('serviceLost', this.onLost)
        if (this.onStarted !== undefined) discovery.off('discoveryStart', this.onStarted)
        if (this.onStopped !== undefined) discovery.off('discoveryStop', this.onStopped)
        discovery.stopSearchingMDNS()
      } catch (error) {
        // stop 是幂等清理路径；系统已停止搜索时无需让旧回调影响新一代。
      }
    }
    this.context = undefined
    this.onFound = undefined
    this.onLost = undefined
    this.onStarted = undefined
    this.onStopped = undefined
  }

  private resolve(serviceInfo: mdns.LocalServiceInfo, activeGeneration: number): void {
    const context: common.UIAbilityContext | undefined = this.context
    if (context === undefined || activeGeneration !== this.generation) return
    mdns.resolveLocalService(context, serviceInfo).then((resolved: mdns.LocalServiceInfo) => {
      if (activeGeneration !== this.generation) return
      const candidate: DiscoveredSecondDisplayService | undefined = this.parse(resolved)
      if (candidate === undefined) return
      const replacementIndex: number = this.services.findIndex(
        (value: DiscoveredSecondDisplayService) => value.id === candidate.id
          || value.fingerprint === candidate.fingerprint
          || (value.host === candidate.host && value.controlPort === candidate.controlPort)
      )
      if (replacementIndex >= 0) {
        this.services[replacementIndex] = candidate
      } else {
        this.services.push(candidate)
      }
      this.services.sort(
        (lhs: DiscoveredSecondDisplayService, rhs: DiscoveredSecondDisplayService) => {
          const nameOrder: number = lhs.name.localeCompare(rhs.name)
          return nameOrder !== 0 ? nameOrder : lhs.fingerprint.localeCompare(rhs.fingerprint)
        }
      )
      this.publish()
    }).catch(() => {
      if (activeGeneration === this.generation) {
        this.publishStatus('NET_PROTOCOL_MISMATCH: unable to resolve a discovered service')
      }
    })
  }

  private remove(serviceInfo: mdns.LocalServiceInfo, activeGeneration: number): void {
    if (activeGeneration !== this.generation) return
    const previousCount: number = this.services.length
    this.services = this.services.filter(
      (value: DiscoveredSecondDisplayService) =>
        value.sourceName !== serviceInfo.serviceName
        || (serviceInfo.host !== undefined && value.host !== serviceInfo.host.address)
    )
    if (this.services.length !== previousCount) this.publish()
  }

  private parse(info: mdns.LocalServiceInfo): DiscoveredSecondDisplayService | undefined {
    if (info.serviceType !== SERVICE_TYPE || info.host === undefined || info.port === undefined
      || !Number.isSafeInteger(info.port) || info.port < 1 || info.port > 65535) return undefined
    const host: string = info.host.address.trim()
    const family: number = info.host.family === 2 ? 2 : 1
    if (host.length === 0 || host.length > 255 || /\s/.test(host)) return undefined
    const protocolVersion: string = this.attribute(info, 'pv')
    const tls: string = this.attribute(info, 'tls')
    const videoPortValue: number = Number(this.attribute(info, 'vp'))
    const fingerprint: string = normalizeFingerprint(this.attribute(info, 'fp'))
    const state: string = this.attribute(info, 'state')
    const capabilities: string = this.attribute(info, 'caps')
    if (protocolVersion !== '1' || tls !== '1' || state !== 'ready' || fingerprint.length === 0
      || !Number.isSafeInteger(videoPortValue) || videoPortValue < 1 || videoPortValue > 65535) {
      return undefined
    }
    const name: string = info.serviceName.trim().length > 0 ? info.serviceName.trim() : host
    return {
      id: `${fingerprint}-${host}-${info.port}`,
      sourceName: info.serviceName,
      name: name,
      host: host,
      family: family,
      controlPort: info.port,
      videoPort: videoPortValue,
      fingerprint: fingerprint,
      capabilities: capabilities,
      paired: this.pairedFingerprints.has(fingerprint)
    }
  }

  private attribute(info: mdns.LocalServiceInfo, key: string): string {
    if (info.serviceAttribute === undefined) return ''
    const decoder: util.TextDecoder = new util.TextDecoder()
    for (const attribute of info.serviceAttribute) {
      if (attribute.key === key) {
        return decoder.decodeToString(new Uint8Array(attribute.value))
      }
    }
    return ''
  }

  private publish(): void {
    if (this.onUpdate !== undefined) this.onUpdate(this.services.slice())
  }

  private publishStatus(status: string): void {
    if (this.onStatus !== undefined) this.onStatus(status)
  }
}
