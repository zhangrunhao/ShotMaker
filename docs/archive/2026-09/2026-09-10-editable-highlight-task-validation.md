# 可编辑集锦任务验证记录

- 日期：2026-09-10
- 执行方式：按用户要求在当前任务 inline 实施、测试及自审，没有派发子代理。
- 分支：`codex/editable-highlight-tasks`；代码提交 `1975784`
- 工程：1.3（Build 3）；Xcode 26.6，Swift 6.3.3，Swift 5 语言模式。
- 平台下限未调整：iOS 26.4、watchOS 26.2。

## 变更范围

已实现进入审核即创建独立任务、不可变训练快照、任务 revision 配置事务、全量审核持久化、视频变化协调、不可变生成执行、串行调度、停止/后台/启动中断处理、安全输出替换、任务文件清理及 iPhone/Watch 数据世代切割。

正式业务组装不再实例化旧 HighlightJobManager 或组合级确认 Store。旧类型及兼容测试保留作为既有契约回归，不进行旧数据读取或迁移。没有新 Analytics 事件、后台生成声明或 Privacy Manifest 数据类别。

## 自动测试与构建

最终结果来自 xcresult 汇总与实际构建日志：

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| iPhone 完整 scheme | 392 通过，0 失败，0 跳过，含 13 项 UI 测试 | `/tmp/shotmarker-editable-complete.xcresult` |
| Watch 完整 scheme | 31 通过，0 失败，0 跳过 | `/tmp/shotmarker-editable-watch-final.xcresult` |
| 干净 Release 构建 | 成功；主 App/Watch 1.3（3），dSYM UUID 对应 | `/tmp/shotmarker-editable-verified-release.log` |
| 产物边界 | 三个 DEBUG 入口均不在二进制；Privacy Manifest 存在，Tracking=false，无后台生成模式 | `/tmp/shotmarker-editable-release-verification.json` |
| Git 文本检查 | 通过 | `git diff --check` |

本地临时结果包供本机复查，可能随系统清理消失；长期回归测试已保存在仓库。失败的先导测试不算作通过证据。

使用以下环境：

- iPhone 17 Pro / iOS 26.5 Simulator，专用设备名 ShotMarker Editable Tasks QA。
- Apple Watch Series 11（46mm）/ watchOS 26.5 Simulator；显式选择设备避免 Xcode 把配对手机与 Watch 名称同时匹配。
- Release：generic iOS Simulator，新建 DerivedData 目录。

关键命令：

```sh
xcodebuild test -project ShotMarker.xcodeproj -scheme ShotMarker \
  -destination 'platform=iOS Simulator,name=ShotMarker Editable Tasks QA' \
  -derivedDataPath /tmp/shotmarker-editable-tasks-dd \
  -resultBundlePath /tmp/shotmarker-editable-complete.xcresult
xcodebuild test -project ShotMarker.xcodeproj -scheme ShotMarkerWatchApp \
  -destination "platform=watchOS Simulator,id=$WATCH_SIMULATOR_ID" \
  -derivedDataPath /tmp/shotmarker-editable-watch-dd \
  -resultBundlePath /tmp/shotmarker-editable-watch-final.xcresult
xcodebuild build -project ShotMarker.xcodeproj -scheme ShotMarker \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/shotmarker-editable-verified-release-dd
git diff --check
```

`WATCH_SIMULATOR_ID` 是本机从 simctl 可用设备列表选择的上述 Watch；记录不保存设备标识符。

新增自动覆盖：

- 手机/Watch 清理顺序、固定 journal、失败重试、业务服务初始化门槛、旧载荷 ACK 丢弃及新载荷导入。
- JSON 往返、独立身份和稳定 sourceOrder、revision 无操作/多字段/过期冲突、写入失败不发布、损坏和未来 schema 保护。
- 文件输入复制、相册引用、路径与符号链接边界、同文件补回缺失副本、创建/修改回滚、孤立文件清理。
- 视频换序、默认时长保留确认、默认基线、样式不重排、全量重置、短于一秒视频完整范围。
- 不合作导出取消后的串行槽、迟到结果、后台及前后台校验竞态、运行中刷新与启动恢复分离。
- 新输出移动、JSON 提交及旧输出清理失败；旧成片保留、新成片提交、相册失败/实际成功及后续本地状态失败的事件语义。
- 工作副本确认、过期提交、连续导航、64 项缩略图上限和退出后 AVAsset/帧数据释放。
- 任务行在排队/运行时只暴露停止，停止后可编辑/重试，配置入口、删除确认和最大字号旧成片提示。
- AVAssetWriter 生成两段 40 秒横/竖 H.264 源文件，实际导出 41 秒成片；排除首组后重新导出 26 秒，验证旧文件删除、重载完成状态和删除任务不影响外部源文件。

## 真实媒体 Simulator 验收

专用 iPhone 17 Pro / iOS 26.5 Simulator，使用正式业务入口及隔离的合成训练/媒体。四个打点相对训练开始为 10、12、32、55 秒，训练 70 秒。源 A 起点为训练开始，源 B 晚 30 秒，覆盖有重叠：

| 来源 | 时长 | 画面 / 帧率 | 编码 / 音轨 |
| --- | --- | --- | --- |
| A | 40 秒 | 640×360，24 fps | H.264，AAC 48 kHz |
| B | 40 秒 | 360×640，24 fps | H.264，无音轨 |
| 额外来源 | 40 秒 | 3840×2160，30 fps | H.264，无音轨 |

A、B 来自生成的测试图样；额外来源用于实际导出停止场景。照片选择、审核、播放和保存使用模拟器真实 PhotoKit/AVFoundation。没有使用私人训练、用户照片或真实用户标识。

| 规格验收项 | 实际证据与结果 |
| --- | --- |
| 1 创建任务 | 原生照片选择 A/B，点击下一步后持久文档立即出现 revision 1；图集形成一个双打点合并卡片及两个普通卡片。单来源创建与样式模型由自动测试补充。 |
| 2 退出恢复 | 不生成退出首页任务存在；重新进入配置与审核，确认排除状态恢复。 |
| 3 相同输入独立任务 | 同一训练、同序 B/A 再次发起后首页出现两条不同创建时间任务，审核均可单独恢复。 |
| 4 确认隔离 | 第二任务确认一个片段，第一任务配置与旧成片状态保持不变；删除核验亦逐值比较保留任务。 |
| 5 增加视频 | 给第二任务增加额外来源并调整优先顺序，视频数变为 3；精确保留条件及重置数量由规划自动测试覆盖。 |
| 6 顺序改变 | B/A 改为 A/B 后，原确认的第 3 打点更换来源；界面显示 1 个确认项重置，总时长从 34 秒改为 41 秒。 |
| 7 默认时长 | 前置 9 改为 8 秒后，已确认排除组仍为 15 秒；默认卡片变化，保留部分总时长从 19 改为 18 秒。 |
| 8 重置全部 | 显示取消及破坏性确认；确认后四个打点全部保留、确认态清空，使用 14/6/12 秒新默认值。 |
| 9 样式 | 配置页展开静态预览并把横向位置从 15% 调到 20%，随配置持久化；样式单独变化不改片段由规划测试覆盖。 |
| 10 媒体释放 | 多片段预览与退出流程完成；自动测试用弱引用确认 AVAsset 释放，帧/缩略图缓存清空，真实导出没有逐片段视频文件。 |
| 11 运行操作 | 实际生成中显示进度及停止；有旧成片的排队/生成辅助功能操作集合由 UI 测试验证。 |
| 12 主动停止 | 实际重新生成时立即停止，任务显示已停止，仍可编辑、播放旧成片和重新生成。 |
| 13 后台停止 | 生成中按模拟器 Home，持久结果为 stopped、活动执行为空、旧成片保留、执行临时目录为 0；回到前台仍为已停止。 |
| 14 进程中断 | 测试驱动检测到 running 后通过 simctl 终止进程，磁盘仍保存 running；重启后界面已停止，旧成片保留且不自动继续。 |
| 15 修改旧成片 | 第一任务修改后显示“有未生成修改”和旧成片提示，播放/保存入口保留，没有直接重新生成入口。 |
| 16 再生成失败 | 自动故障注入覆盖来源、输出移动与 JSON 提交失败，旧输出引用及文件保留，不发送生成成功事件。未通过删除模拟器相册来源制造失败。 |
| 17 替换输出 | 原生媒体实际生成并播放；真实文件集成测试精确核对 41→26 秒替换及旧 App 文件清理。 |
| 18 删除边界 | 原生 UI 二次确认删除第一任务；其目录消失，第二任务 JSON 逐值不变，训练文档不变，相册资源计数不变。文件副本/外部源边界由真实文件集成测试补充。 |
| 19 数据世代升级 | 停止模拟器后清除 epoch 并植入旧任务/确认、偏好、缓存、临时文件；启动后旧训练/任务/成片等全部消失，epoch 1 与固定 cutover 已写入，相册资源计数不变。第二次启动保留新训练及同一 cutover。 |
| 20 Watch 与旧载荷 | Watch 自动测试使用真实临时目录验证旧 outbox 清空且第二次保留新 outbox；手机同步测试验证旧/等于 cutover 载荷只 ACK，无训练导入/Analytics，新载荷正常。没有声称真机 Watch 联机升级已验收。 |

表中明确区分原生交互、进程/文件核验和自动测试补充；没有把自动验证表述为全套人工操作已执行。

## 自审修正与回归

- 开始前已完成一次原有 342 项 iPhone 基线回归。
- 前后台在来源校验期间切换、运行中重新加载、缺失私有副本后重选同文件均先通过测试复现，再修复并回归。
- 导出/相册错误日志先用带伪来源信息的 NSError 复现泄露，再改为封闭错误类型；本地逐片段起止日志已删除。
- 短于 1 秒的源视频在最终校验中保留精确媒体尾部，不被十分之一秒规则误拒绝。
- 原生重置发现相同范围卡片不重新加载缩略图；请求身份纳入审核 ViewModel 身份后，在同一媒体场景复验三张缩略图均恢复。
- 首轮新增 UI 测试的一处失败来自把组合辅助功能元素查询为 StaticText；修正为实际可访问元素后，完整 UI 回归通过。

## 验证边界

- Release Simulator App 和 dSYM 仅验证构建产物，不能替代正式签名 Archive。
- 没有执行真机、VoiceOver、TestFlight、App Store Connect、Release Analytics 生产链路或 GlitchTip 生产符号化/告警验收。
- 没有新增快照测试、XCTest Plan 或仓库内 CI。
- 构建仍有既有播放观察者 Sendable 警告及无 AppIntents 依赖的 metadata 提取提示；未声明 warning-free。
- SwiftLint 最近记录仍为 2026-08-18 的非绿色基线，本次没有重新运行 SwiftLint。
