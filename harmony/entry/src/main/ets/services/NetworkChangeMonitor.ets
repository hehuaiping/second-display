import { connection } from '@kit.NetworkKit'

type NetworkChangedCallback = () => void

/// 将系统网络事件合并成一次重发现请求，并用 generation 屏蔽 stop 后的迟到回调。
export class NetworkChangeMonitor {
  private generation: number = 0
  private netConnection: connection.NetConnection | undefined = undefined
  private debounceTimer: number = -1
  private onAvailable: ((value: connection.NetHandle) => void) | undefined = undefined
  private onLost: ((value: connection.NetHandle) => void) | undefined = undefined
  private onCapabilitiesChanged:
    ((value: connection.NetCapabilityInfo) => void) | undefined = undefined

  start(callback: NetworkChangedCallback): void {
    this.stop()
    const activeGeneration: number = this.generation
    const netConnection: connection.NetConnection = connection.createNetConnection()
    this.netConnection = netConnection
    const schedule = (): void => {
      if (activeGeneration !== this.generation) return
      if (this.debounceTimer >= 0) clearTimeout(this.debounceTimer)
      this.debounceTimer = setTimeout(() => {
        this.debounceTimer = -1
        if (activeGeneration === this.generation) callback()
      }, 350)
    }
    this.onAvailable = (): void => schedule()
    this.onLost = (): void => schedule()
    this.onCapabilitiesChanged = (): void => schedule()
    netConnection.on('netAvailable', this.onAvailable)
    netConnection.on('netLost', this.onLost)
    netConnection.on('netCapabilitiesChange', this.onCapabilitiesChanged)
    netConnection.register((error): void => {
      if (error !== undefined && activeGeneration === this.generation) {
        // mDNS 自身仍可工作，网络监听失败不阻断手动发现。
      }
    })
  }

  stop(): void {
    this.generation += 1
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer)
      this.debounceTimer = -1
    }
    const netConnection: connection.NetConnection | undefined = this.netConnection
    this.netConnection = undefined
    if (netConnection === undefined) return
    try {
      // NetConnection 没有单事件 off；unregister 会一次性注销此实例的全部网络回调。
      netConnection.unregister((): void => {})
    } catch (error) {
      // unregister 是幂等清理路径，旧回调已由 generation 隔离。
    }
    this.onAvailable = undefined
    this.onLost = undefined
    this.onCapabilitiesChanged = undefined
  }
}
