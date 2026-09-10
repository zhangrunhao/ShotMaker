# 片段连续确认预览修复验证

- 日期：2026-09-10
- 修复代码：`da129c1`，基于 `2d31327`
- 环境：Xcode 26.6、iPhone 17 Pro / iOS 26.5 Simulator
- 结论：连续确认后的媒体加载与时间轴状态已修复，完整 iPhone 回归和 Release Simulator 构建通过。

## 问题与根因

用户反馈确认包含打点 1–3 的片段后，自动打开片段 4，起止范围显示 691.1–704.1 秒，但预览黑屏、胶片为空、当前位置停在 0.0 秒，起止手柄挤在时间轴右侧。

`HighlightClipReviewView` 使用 `navigationDestination(item:)` 替换当前编辑对象，却未给目标编辑器设置片段视图身份。连续导航保留了 `HighlightClipEditorView` 上一个片段的 `@State window`，而播放器任务 ID 仍为重试次数 0，胶片任务 ID 仍为旧窗口。新的播放控制器没有触发加载，新片段继续使用旧局部窗口。

原连续确认 UI 测试使用 `loadsMedia: false`，只覆盖保存后跳转和跳过已确认项，没有覆盖真实播放或帧提取。

## 修复与新增覆盖

导航目标按片段 UUID 设置 `.id(destination.id)`。切换片段时重新建立编辑器局部状态和媒体任务，旧编辑器的退出清理仍针对旧片段。持久化模型、片段范围及生成规则没有变化。

新增 DEBUG 真实媒体场景复用现有片段确认测试入口，使用真实 `HighlightTaskStore`、`HighlightTaskManager`、`HighlightReviewSession`、`AVPlayer` 和帧提取实现。夹具生成一段 720 秒横屏 H.264 与一段 40 秒竖屏 H.264 视频，训练打点构成片段 1–3、691.1–704.1 秒的片段 4，以及另一来源的片段 5。

`HighlightClipMediaNavigationUITests` 检查：

1. 首个合并片段正常加载。
2. 确认后片段 4 自动定位到 691.1 秒，提取 8 张胶片帧，起止手柄分开，实际播放时间推进。
3. 再次确认后切换到另一来源，定位、胶片、时间轴和播放正确。
4. 确认最后一个片段返回图集，重新打开片段 4 后仍正常加载。

## 验证结果

| 检查 | 结果 | 本地证据 |
| --- | --- | --- |
| 修复前真实媒体复现 | 失败：片段 4 的当前位置为 0.0 秒，10 秒内未定位到起点 | `/tmp/shotmarker-clip-navigation-red2.xcresult` |
| 修复后针对性 UI 回归 | 1 项通过，0 失败、0 跳过 | `/tmp/shotmarker-clip-navigation-green2.xcresult` |
| 完整 iPhone 测试 | 393 项通过，0 失败、0 跳过；含 14 项 UI 测试 | `/tmp/shotmarker-clip-navigation-full.xcresult` |
| Release generic iOS Simulator 构建 | 增量构建成功；App/Watch 均为 1.3（3），二进制与 dSYM 对应 | `/tmp/shotmarker-clip-navigation-release.log` |
| Release 测试入口边界 | 原三个 DEBUG 入口、新真实媒体场景及计数观测不进入 App/Watch 二进制；隐私清单 Tracking=false | `/tmp/shotmarker-editable-verified-release-dd/Build/Products/Release-iphonesimulator/ShotMarker.app` |
| 截图核验 | 片段 4 横屏画面与胶片可见，当前位置为 691.1 秒，手柄位置正常；片段 5 显示正确的竖屏来源 | `/tmp/shotmarker-clip-navigation-screenshots/manifest.json` |
| Git 文本检查 | 通过 | `git diff --check`、`git diff --cached --check` |

测试使用 `ShotMarker` scheme 和专用 `ShotMarker Editable Tasks QA` Simulator；完整测试没有 `only-testing` 过滤，针对性测试过滤 `ShotMarkerUITests/HighlightClipMediaNavigationUITests`。结果可用以下命令复查：

```sh
xcrun xcresulttool get test-results summary --path /tmp/shotmarker-clip-navigation-full.xcresult
xcrun xcresulttool get test-results summary --path /tmp/shotmarker-clip-navigation-green2.xcresult
```

## 验证边界

本次真实媒体由测试生成，用户原始视频所在真机未复测。Watch 代码未变化，其最近完整测试证据为 2026-09-10 `1975784` 的 31 项通过。本次没有执行正式签名 Archive、TestFlight、生产 Analytics 或 GlitchTip 验收。

当前事实见 [质量状态](../../current/quality.md)；此记录保存问题原因和历史验证，不替代 current。
