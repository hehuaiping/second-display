# Tag-Driven Release 发布流程

GitHub Release 由语义化版本标签驱动。流水线不会自动创建标签，也不会在普通分支推送或
Pull Request 上发布制品。

## 发布内容

- 默认执行 macOS Debug/Release 测试、共享协议向量检查和 HarmonyOS C++ 协议测试。
- macOS 产物使用 ad-hoc 签名并执行签名结构、Bundle ID、DMG 完整性和持久化辅助程序
  残留检查；当前发布策略不执行 Apple 公证，也不声明通过 Gatekeeper。
- 发布 DMG、构建信息、SHA-256 校验和，并生成 GitHub Artifact Attestation。
- 自动生成 Release Notes。`v1.2.3-beta.1` 等标签会发布为 prerelease。
- HarmonyOS 仅执行 debug HAP 编译验证，不签名、不上传制品，也不加入 GitHub
  Release。完整编译门禁可通过自托管 Runner 启用。

## 版本规则

正式版本标签：

```text
v1.2.3
```

兼容使用大写前缀的已有标签，例如 `V1.2.3`；新版本仍建议统一使用小写 `v`。

预发布标签：

```text
v1.2.3-beta.1
v1.2.3-rc.1
```

创建标签前必须先更新 `harmony/AppScope/app.json5`：

- `versionName` 必须与标签的 `MAJOR.MINOR.PATCH` 一致。
- `versionCode` 必须按 AppGallery Connect 要求单调递增。

标签不符合规则、`versionName` 不匹配，或标签提交不在 `main` 历史中时，流水线会在
任何签名操作前终止。

## macOS ad-hoc 发布策略

当前公开 DMG 使用 `codesign --sign -` 生成 ad-hoc 签名，不需要 Developer ID、证书私钥、
App Store Connect API Key 或 GitHub Environment secrets。`release` Environment 可以
继续用于 required reviewers 等人工发布保护，但不承载签名材料。

ad-hoc 签名只能校验应用内容在构建后没有被修改，不能建立 Apple 开发者身份信任，也不能
通过标准 Gatekeeper 或 Apple 公证。Release 页面、`BUILD-INFO.json` 和流水线日志都会
明确记录 `macosSigning=ad-hoc`、`notarized=false`。用户应只从本仓库 Release 下载，并
核对 `SHA256SUMS.txt` 与 GitHub Artifact Attestation。

## 可选的 HarmonyOS 编译 Runner

GitHub 托管 Runner 不预装 DevEco Studio/HarmonyOS SDK。若需要在标签发布前执行完整
HarmonyOS 应用编译验证：

1. 准备受控的自托管 Runner，并添加 `harmonyos-build` 标签。
2. 安装匹配项目的 HarmonyOS SDK、Node.js、ohpm 和 hvigorw，并确保 `hvigorw` 在
   `PATH`。
3. 流水线会用仓库内不含签名字段的 `harmony/build-profile.ci.json5` 覆盖本地
   `build-profile.json5`，不得向 CI 模板加入证书、Profile 或密钥字段。
4. 设置 Repository variable `ENABLE_HARMONY_BUILD=true`。

该作业运行 `assembleHap` 的 debug 编译并确认生成 `.hap`，随后丢弃工作区，不上传
HarmonyOS 制品。HarmonyOS 正式签名与上架继续在 DevEco Studio/AppGallery Connect
流程中完成。

## 创建发布

确保目标提交已经在 `main`，工作区干净，CI 全部通过：

```sh
git switch main
git pull --ff-only
git tag -s v1.2.3 -m "Second Display 1.2.3"
git push origin v1.2.3
```

推送标签后：

1. 标签与版本校验。
2. 双端质量门禁。
3. macOS ad-hoc 签名、DMG 打包和分发结构验证。
4. 可选的 HarmonyOS debug HAP 编译验证。
5. 创建 Draft Release、上传全部制品和校验和。
6. 所有上传成功后才发布 Release。

若标签已经存在但没有触发流水线，或需要在修复流水线后重试，可在 GitHub Actions 的
`Release` 工作流中选择 `Run workflow`，输入完整标签名。手动运行仍会校验标签存在、
版本匹配且标签提交位于 `main`，并且所有作业都会检出该标签对应的同一个提交。

如签名、打包或任一质量门禁失败，不会生成公开 Release。重新运行失败作业时，只允许
继续更新尚未发布的 Draft Release；已发布 Release 不会被自动覆盖。

## 验证下载制品

```sh
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify SecondDisplay-1.2.3-macos-ARM64.dmg \
  --repo hehuaiping/second-display
```

不要在流水线日志、Release 附件或 Issue 中上传证书、私钥、密码或本地
`build-profile.json5`。虽然当前 ad-hoc 流水线不使用签名 Secret，这条安全约束仍适用。
