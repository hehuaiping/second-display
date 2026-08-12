/// Mac 服务端的唯一官方下载入口。集中定义可避免界面与隐私说明出现地址漂移。
export const MAC_SERVER_WEBSITE: string = 'https://second-display.cuihua.cloud'

/// 打开外部官网失败时使用项目级错误码，不向用户暴露系统异常详情。
export const APP_LINK_OPEN_FAILED: string = 'APP_LINK_OPEN_FAILED'

/// 首次隐私确认前不允许产生外部网络跳转；进行中的操作也不能被重复触发。
export function canOpenMacServerWebsite(
  privacyAccepted: boolean,
  operationInProgress: boolean
): boolean {
  return privacyAccepted && !operationInProgress
}

/// 仅允许当前页面、当前 generation 的异步结果更新界面。
export function isCurrentExternalLinkOperation(
  activeGeneration: number,
  currentGeneration: number,
  pageActive: boolean
): boolean {
  return pageActive && activeGeneration === currentGeneration
}
