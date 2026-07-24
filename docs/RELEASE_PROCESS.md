# Tag-Driven Release 发布流程

GitHub Release 由语义化版本标签驱动。流水线不会自动创建标签，也不会在普通分支推送或
Pull Request 上发布制品。

## 发布内容

- 默认执行 macOS Debug/Release 测试、共享协议向量检查和 HarmonyOS C++ 协议测试。
- macOS 产物使用 Developer ID 签名、Apple 公证并执行 Gatekeeper、staple 和 DMG
  完整性验证。
- 发布 DMG、构建信息、SHA-256 校验和，并生成 GitHub Artifact Attestation。
- 自动生成 Release Notes。`v1.2.3-beta.1` 等标签会发布为 prerelease。
- HarmonyOS Release APP 可由受保护的自托管 Runner 构建；默认关闭，避免将签名材料
  放入公共 GitHub Runner。

## 版本规则

正式版本标签：

```text
v1.2.3
```

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

## GitHub Environment 与 Secrets

在仓库 `Settings > Environments` 创建 `release` Environment。建议开启 required
reviewers，确保正式签名和公证作业需要人工批准。

配置以下 Environment secrets：

| Secret | 内容 |
|---|---|
| `MACOS_DEVELOPER_ID_P12_BASE64` | Developer ID Application 证书和私钥导出的 `.p12`，Base64 编码 |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | `.p12` 密码 |
| `MACOS_SIGN_IDENTITY` | 完整签名名称，例如 `Developer ID Application: Name (TEAMID)` |
| `APPLE_NOTARY_KEY_P8_BASE64` | App Store Connect API Key `.p8`，Base64 编码 |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API Key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect Issuer ID |

Base64 文件可以在本机生成，输出只粘贴到 GitHub Secret，不能写入仓库：

```sh
base64 -i DeveloperID.p12 | pbcopy
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

## 可选的 HarmonyOS Release Runner

GitHub 托管 Runner 不预装 DevEco Studio/HarmonyOS SDK。若需要把签名后的 `.app` 同时
附加到 GitHub Release：

1. 准备仅用于发布的自托管 Runner，并添加 `harmonyos-release` 标签。
2. 安装匹配项目的 HarmonyOS SDK、Node.js、ohpm 和 hvigorw，并确保 `hvigorw` 在
   `PATH`。
3. 将 Release `build-profile.json5` 和它引用的 `.p12`、`.cer`、`.p7b` 保存在 Runner
   的受保护目录，禁止其他仓库或普通用户读取。
4. 设置 Repository variable `HARMONY_BUILD_PROFILE_PATH` 为该配置文件的绝对路径。
5. 设置 Repository variable `ENABLE_HARMONY_RELEASE=true`。

签名配置只会复制进被 Git 忽略的工作区文件，作业结束后会删除。HarmonyOS APP 仍应
通过 AppGallery Connect 完成正式上架；GitHub Release 附件适合留档和受控测试分发。

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
3. macOS 签名、公证和分发验证。
4. 可选的 HarmonyOS Release 构建。
5. 创建 Draft Release、上传全部制品和校验和。
6. 所有上传成功后才发布 Release。

如签名、公证或任一质量门禁失败，不会生成公开 Release。重新运行失败作业时，只允许
继续更新尚未发布的 Draft Release；已发布 Release 不会被自动覆盖。

## 验证下载制品

```sh
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify SecondDisplay-1.2.3-macos-ARM64.dmg \
  --repo hehuaiping/second-display
```

不要在流水线日志、Release 附件或 Issue 中上传 `.p12`、`.p8`、`.p7b`、密码或本地
`build-profile.json5`。
