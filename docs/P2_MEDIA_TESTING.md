# P2 采集与编码验证

P2 的自动化测试覆盖 ScreenCaptureKit displayID 绑定、权限错误、generation 取消、VideoToolbox H.264 编码、Annex B 转换、SPS/PPS、两级背压和媒体向量完整性。

## 常规验证

```bash
swift build -c debug
swift test -c debug
swift test -c release
python3 tools/validate_shared_vectors.py
```

## 真实虚拟显示器采集

运行测试的宿主需要在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中获得权限：

```bash
RUN_CAPTURE_INTEGRATION=1 swift test -c debug \
  --filter MediaPipelineTests/testRealVirtualDisplayCaptureProducesNV12Frame
```

该测试创建虚拟显示器，仅按 `CGDirectDisplayID` 等待对应的 `SCDisplay`，采集一帧 1280×800 NV12，然后幂等停止采集并销毁显示器。

## 媒体向量

重新生成受控大小的向量：

```bash
swift run -c release MediaVectorGenerator --output shared/test-vectors/media
```

使用标准解码器验证：

```bash
for file in shared/test-vectors/media/*.h264; do
  ffmpeg -v error -f h264 -i "$file" -f null -
done
```

`shared/test-vectors/media/media_vectors.json` 记录 codec、profile、尺寸、帧率、帧数、文件大小和 SHA-256。Mac 回归测试直接读取该清单；HarmonyOS 解码测试在 T304 接入同一路径，不复制向量。
