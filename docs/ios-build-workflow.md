# iOS 构建验证流程

这份文档用于固定“三句”项目的本地 iOS 构建验证方式，避免再次把“沙箱内 Xcode 构建失败”误判成工程问题。

更新时间：2026-05-13

## 结论

- 这个项目的 `xcodebuild` 在 Codex 沙箱内可能会因为 `CoreSimulatorService connection became invalid` 失败。
- 同一工程在沙箱外可以正常 `BUILD SUCCEEDED`。
- 因此，今后只要是“验证 iOS 工程是否真能编过”，默认使用沙箱外构建。

## 默认命令

仓库内统一使用脚本：

```bash
bash scripts/build-ios.sh simulator
```

如果要验证面向真机的目标：

```bash
bash scripts/build-ios.sh device
```

脚本会固定：

- `project = 三句.xcodeproj`
- `scheme = 三句`
- `configuration = Debug`
- `CODE_SIGNING_ALLOWED = NO`
- `derivedDataPath = .codex-derived-data` 或 `.codex-derived-data-device`

## 什么时候必须用沙箱外

以下场景都默认用沙箱外构建：

- 修改了 SwiftUI 页面或业务代码后，想确认 App 还能编译。
- 修改了 `Assets.xcassets`、`Info.plist`、`PrivacyInfo.xcprivacy`、小组件、App Intents。
- 修改了工程配置、target、bundle 相关设置。
- 出现 `CompileAssetCatalogVariant`、`CoreSimulatorService`、`simdiskimaged`、`Connection invalid` 这类报错。

## 怎么判断是沙箱问题，不是工程问题

如果在沙箱内构建看到这些特征，优先怀疑环境，而不是代码：

- `CoreSimulatorService connection became invalid`
- `Unable to discover any Simulator runtimes`
- `simdiskimaged crashed or is not responding`
- 失败点是 `CompileAssetCatalogVariant thinned ... Assets.xcassets`

这类情况下，先用沙箱外重跑同一条构建命令。如果沙箱外成功，就不要为了“修 build”去改项目工程。

## 这套流程当前验证结果

2026-05-13 已验证：

- `xcodebuild -list -project 三句.xcodeproj` 正常。
- 沙箱内 build 可能失败，主因是模拟器服务链路不可用。
- 沙箱外执行以下命令可以成功：

```bash
xcodebuild -project 三句.xcodeproj -scheme 三句 -destination 'generic/platform=iOS Simulator' -derivedDataPath .codex-derived-data CODE_SIGNING_ALLOWED=NO build
```

## Provisioning Profile 噪音处理

曾经发现本机目录：

`~/Library/Developer/Xcode/UserData/Provisioning Profiles/`

里有一批损坏的 `.mobileprovision`，会导致 Xcode 日志反复打印：

- `Failed to load profile`
- `Profile is missing the required UUID property`

这些不是本项目构建失败的主因，但会污染日志。2026-05-13 已经把 10 个异常 profile 移到桌面备份目录：

`~/Desktop/bad-provisioning-profiles-backup-20260513-092740`

如果以后又出现同类日志，可以先检查这个目录下是否又有新的异常 profile。

## 推荐习惯

- 平时读代码、改代码、扫静态问题：沙箱内即可。
- 真正要确认 iOS 工程能否编过：默认跑 `bash scripts/build-ios.sh simulator`，并使用沙箱外执行。
- 不要把沙箱内的模拟器服务错误，误当成项目本身损坏。
