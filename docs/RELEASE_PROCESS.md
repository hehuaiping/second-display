# Tag-Driven Release 发布流程

GitHub Release 由语义化版本标签驱动。流水线不会自动创建标签，也不会在普通分支推送或
Pull Request 上发布制品。

## 发布内容

- 默认执行 macOS Debug/Release 测试、共享协议向量检查和 HarmonyOS C++ 协议测试。
- macOS 产物使用 Developer ID 签名、Apple 公证并执行 Gatekeeper、staple 和 DMG
  完整性验证。
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

发布流水线会先执行凭据预检；任一 Secret 缺失时会直接列出缺失名称并停止，不再继续占用
macOS Runner 执行测试和打包。

Base64 文件可以在本机生成，输出只粘贴到 GitHub Secret，不能写入仓库：

```sh
base64 -i DeveloperID.p12 | pbcopy
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

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
3. macOS 签名、公证和分发验证。
4. 可选的 HarmonyOS debug HAP 编译验证。
5. 创建 Draft Release、上传全部制品和校验和。
6. 所有上传成功后才发布 Release。

若标签已经存在但没有触发流水线，或需要在修复流水线后重试，可在 GitHub Actions 的
`Release` 工作流中选择 `Run workflow`，输入完整标签名。手动运行仍会校验标签存在、
版本匹配且标签提交位于 `main`，并且所有作业都会检出该标签对应的同一个提交。

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
