# ShotMarker 发布状态

- 最后复核：2026-09-10
- 工程版本：1.3（Build 3）
- Bundle ID：com.heji.ShotMarker
- Watch Bundle ID：com.heji.ShotMarker.watchkitapp

## 当前结论

仓库当前 iPhone App 与随包 Watch App 配置为 1.3（Build 3），Release Simulator 构建已于 2026-09-10 通过。签名 Archive 与 Organizer Validate 的最近证据仍属于 1.2（Build 1）和 2026-08-19；2026-08-20 的 App Store Connect 网页复核也不证明 1.3 的 TestFlight、审核或 App Store 可用状态。

## 构建与平台

- iOS 部署下限：26.4。
- watchOS 部署下限：26.2。
- 产品发布与验证范围为 iPhone + Apple Watch；主 App 工程仍保留未验收的 iPad destination，不配置 macOS、Mac Catalyst 或 visionOS destination。
- 自动签名已配置。
- Release 使用 DWARF with dSYM。
- iPhone target 从官方 `sentry-cocoa` 以源码产品 `SentrySPM` 链接 Sentry 9.26.0；Watch target 不链接。
- 可编辑任务代码的 1.3（Build 3）Release Simulator 构建已于 2026-09-10 使用全新 DerivedData 通过；App/Watch dSYM 对应且 DEBUG 入口不进入产物。
- 2026-08-19 已生成自动签名的正式 iOS Archive 1.2（Build 1）；主 App 与 Watch App 的二进制 UUID 均有匹配 dSYM，Archive 不再嵌入独立 `Sentry.framework`。
- 同日 Xcode Organizer Validate 成功，没有 warning/error 或 `Upload Symbols Failed`；该次验证未执行上传。
- 尚未为 1.3（Build 3）执行正式签名 Archive、Organizer Validate 或上传。

## 当前审核事实

- 核心使用不需要登录、账号或演示账户。
- App 需要照片读取/添加权限；Watch 使用 HealthKit workout session。

## 有效用户披露要求

- ShotMarker 不向自建服务器上传训练记录、打点、源视频或生成视频；系统照片库及 iCloud 是否保存或同步视频由用户设置决定。
- Release iPhone 会联网发送产品 Analytics 和 GlitchTip 错误/崩溃信息，因此审核说明和隐私披露不得声称“完全不联网”或“所有数据都不离开设备”。
- Analytics 只发送 project、event、device_id；不发送训练记录、视频、文件名、照片、语音、用户身份或自由文本。完整契约见 [产品埋点](analytics.md)。
- GlitchTip 不配置默认 PII 或用户身份，也不上传训练记录、视频、截图和本地日志文件。

## 本地数据升级影响

- 当前数据世代为 1。缺失或旧 epoch 的 iPhone 与 Watch 首次启动会清空旧训练、旧审核、旧任务、App 内输入/成片、日志、缓存、outbox 和完整偏好设置，不提供迁移。
- iPhone 固定切割时间并在失败重试时复用；切割前结束的旧 Watch 载荷正常 ACK 后丢弃，防止旧训练重新进入本地。
- 系统照片库、已保存到相册的成片、HealthKit、沙盒外导出和远端历史不删除；成功后的后续启动保留新数据。
- 发布说明和升级披露必须明确此本地清理行为。该代码变更尚未执行正式签名 Archive 或分发。

## 外部状态

- 签名 Archive 与 Organizer Validate 的最近验证日期为 2026-08-19；该次验证没有执行上传。完整外部证据由私有台账维护。
- 2026-08-20 已通过 App Store Connect iPhone Media Manager 网页复核：6.9 英寸和 6.5 英寸各配置 4 张当前版本截图，顺序均为训练记录、集锦设置、集锦就绪和集锦完成。
- 截至 2026-08-20，当前 TestFlight、审核和 App Store 可用状态仍未通过网页独立复核。
- ShotMarker Analytics 四字段服务端链路和公开隐私页面最后一次生产验收日期为 2026-08-16；字段与保留边界见 [产品埋点](analytics.md)。
- 截至 2026-08-19，Analytics 和 GlitchTip 的线上状态尚未在 2026-08-16 的生产验收后重新验证。

## 发布前待验收

- 为 1.3（Build 3）生成正式签名 Archive，核验主 App、Watch App、dSYM 和 Organizer Validate，再决定上传候选 Build。
- 使用正式 Archive 或 TestFlight Build 验证四个 Analytics 事件。
- 触发真机崩溃并确认事件、符号化和 dSYM 对应关系。
- 验证 GlitchTip 告警通知。
- 复核 App Store Connect 隐私问卷与 PrivacyInfo.xcprivacy 一致。
- 使用与当前行为一致的 App Review Note，明确 Watch、HealthKit、照片权限和远端观测边界。
- 重新确认当前 TestFlight、审核与 App Store 可用状态。

正式验收结果应记录验证日期、Build、设备/系统和外部环境，并同步更新 [项目状态](status.md) 与 [质量状态](quality.md)。
