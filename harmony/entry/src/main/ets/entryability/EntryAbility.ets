import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'SecondDisplay', 'EntryAbility created');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(0x0000, 'SecondDisplay', 'Unable to load page: %{public}d', error.code);
        return;
      }
      this.configureImmersiveWindow(windowStage);
    });
  }

  onForeground(): void {
    if (this.mainWindow !== undefined) {
      this.applyImmersiveMode(this.mainWindow);
    }
  }

  private configureImmersiveWindow(windowStage: window.WindowStage): void {
    try {
      this.mainWindow = windowStage.getMainWindowSync();
      this.applyImmersiveMode(this.mainWindow);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      hilog.error(
        0x0000,
        'SecondDisplay',
        'Unable to access main window: %{public}d %{public}s',
        failure.code,
        failure.message
      );
    }
  }

  private async applyImmersiveMode(mainWindow: window.Window): Promise<void> {
    try {
      await mainWindow.setWindowLayoutFullScreen(true);
      await mainWindow.setWindowSystemBarEnable([]);
      await mainWindow.setSpecificSystemBarEnabled('status', false, false);
      await mainWindow.setSpecificSystemBarEnabled('navigation', false, false);
      await mainWindow.setSpecificSystemBarEnabled('navigationIndicator', false, false);
      // 清单保证首帧横屏；Surface 就绪后允许传感器横竖屏旋转，
      // 方向变化会触发 P6 的 generation 安全显示重建流程。
      await mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      hilog.error(
        0x0000,
        'SecondDisplay',
        'Unable to enable immersive window: %{public}d %{public}s',
        failure.code,
        failure.message
      );
    }
  }
}
