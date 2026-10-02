# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **`PlayerBackend.valueStream` 契约按现状修正**：文档此前写"订阅必须立即
  发出当前值（replay-latest）"，但三个实现从来都是普通 broadcast、controller
  也依赖"先订阅后 initialize"的顺序而非 replay。现在契约明确为**不 replay**，
  订阅时刻的快照用 `value` 同步读取——replay 反而会在换 backend 时把半成品
  初始值打进 `value`。
- **source middleware 计入 `initTimeout` 预算**：`initialize()` / `load()` /
  `switchLine()` 的 middleware 流水线此前无界，卡死的 middleware 会让调用方
  future 永远悬着、候选登记永不注销。超时按既有语义视作该次拉起失败
  （可重试 / 触发 failover）。

- 仓库地址统一为 `github.com/doubledog789/niuma_player`（pubspec 的
  homepage / repository / issue_tracker / documentation、podspec、文档）。
- **Android `PlayerSession`**：每个 `notify*` 入口加主线程守卫——不在主线程
  即打 warning 并转投主线程。当前 IJK 回调经其 `EventHandler` 本就落在主线程，
  守卫是防线而非修复：内核换成工作线程回调的实现时不会静默产生
  phase / position 竞态。
- **工程治理**：
  - CI 的 analyze + test 改为矩阵：`3.27.0`（pubspec 声明的下限，此前从未被验证）
    与浮动 stable 各跑一遍；新增 podspec 版本与 pubspec 一致性校验；
    build-android 新增 vendored IJK aar 的 SHA-256 校验（事实源
    `VERSIONS.lock` 新增 `AAR_SHA256`）。
  - `ios/niuma_player.podspec` 从模板值（0.0.1 / example.com / Your Company）
    改为真实元数据，并通过 `resource_bundles` 把 `PrivacyInfo.xcprivacy`
    打进 pod（此前该行被注释，清单从未随包发布）。
- **IJK 产物说明统一到现状**：`CLAUDE.md` / `README.md` / `pubspec.yaml` /
  `android/build.gradle` 注释 / `CONTRIBUTING.md` / `android/scripts/compile/`
  （README、`VERSIONS.lock` 的 `AAR_VERSION`、ff8 模块脚本头注释、POM 描述、
  `build.sh` / `Dockerfile` 废弃标记）此前仍写着 GSY 官方 FFmpeg 4.3 或自编
  7.1.1，现统一为自编 FFmpeg 8.1 `0.8.8-ff8.1-static-20260727`——目前唯一能
  正确播 H.265 fMP4 分片 HLS 的产物，并明确不要换回 GSY / FFmpeg 4.x。

### Deprecated

- `MultiSourcePolicy` 与 `AutoFailoverOrchestrator`：两者从未被
  `NiumaPlayerController` 消费，且 orchestrator 的语义（仅 network / terminal
  错误才 failover、有预算）与 controller 实际行为不一致。首播 failover 请用
  `NiumaPlayerOptions.autoFailoverOnInitialError`。仍导出但标 `@Deprecated`，
  下个 minor 版本移除。

### Added

- **`NiumaPlayerValue.structuralRevision` + `structurallyEquals`**（kit
  的 `structuralRevision` 下沉）：controller 在 value setter 单点盖章的
  结构版号——除 `position` / `bufferedPosition` 外任意字段变化时递增，
  播放 tick 不递增。上层判断"骨架 UI 要不要重建"只需比较版号，不必自己
  维护逐字段清单（kit 此前手工维护 8 字段列表，内核加字段就会漏通知）；
  "哪些字段算结构"的唯一事实源是 `structurallyEquals`，逐字段矩阵单测
  兜底。backend 自产 value 版号恒为 0，仅经 controller 流出的携带有效版号。
- **内核结构化错误分类**（kit ROADMAP 2.4 "分类形同虚设"）：
  - IJK 路径：Kotlin `PlayerSession` 本就回传结构化 `errorCategory`，但
    `NativeBackend` 的 initialize 失败路径把它重新包成裸
    `PlatformException`（分类只剩 message 文本里的 `category=network`
    字样）——现在直接以携带分类的 `PlayerError` 失败，`_categorize` 的
    duck-typing 现成吃到；prepare 无进度超时同样归 network（对齐
    initTimeout → TimeoutException 的可重试语义，此前落 unknown 不重试）。
  - vp 主路径：新增内核统一的平台错误模式表
    （`platform_error_classifier`，配真机串样本单测）——Exo
    `Source error` / HTTP 栈 / DNS / 超时与 iOS `NSURLErrorDomain`
    归 network，解码器失败归 codecUnsupported（优先匹配）；作用于
    `value.error.category` 与 initialize 失败的 `_categorize` 两条路。
    Android 真机断网实测串此前双双落 unknown：**断网连重试都不触发**，
    kit 分类文案退化为通用兜底。kit / 业务侧不要再做文本嗅探。
  - `FallbackTriggered.errorCategory` 开始携带归类结果（此前字段恒 null）。
  - `PlayerError` 现在 `implements Exception`（可作为异常抛出的语义显式化）。
- `PipStartFailed(reason)` 事件：iOS PiP 启动失败（AVKit `failedToStart` 或
  等 `isPictureInPicturePossible` 5s 超时）时原生侧推送，controller 据此把
  `enterPictureInPicture()` 乐观置位的 `isInPictureInPicture` 翻回 false
  （不触发退出 PiP 的默认暂停）。此前失败只在原生侧 teardown、不通知 Dart，
  `isInPip` 会一直卡 true 直到下次回前台。

### Fixed

- **Web 原生全屏控件**：进入 Safari/标准元素全屏时自动开启可交互控件，
  退出、ESC 与进入失败时恢复调用方的控件设置；按实例处理全屏归属，
  取消/销毁后丢弃迟到请求，全屏内主动暂停后退出不强制续播。

- 修复 IJK 创建返回前销毁导致的原生会话与事件订阅泄漏。
- 切线初始化中 `load()` 不再复用半初始化 backend；快速切回原线路会取消在途切线。
- Web 原生控件开启时恢复点击命中，并尊重控件暂停；关闭后恢复 Flutter 手势穿透。
- Android IJK 正确解析 Flutter asset key，通过支持随机读取的资源流播放打包视频。
- Android 默认 video_player 后端同步 PiP 播放/暂停按钮状态。

- **`bufferedPosition` 取「包含当前位置的那段」缓冲区间的末尾，不再取最后
  一段**：浏览器 / AVPlayer 会保留 seek 前后的多段区间，拖到后面再拖回开头后，
  web 与 video_player 后端此前都取末段末尾，播到 16 秒进度条的缓冲段却铺到
  8 分钟。现改为取包含当前位置的那段（相接的小缝隙视为连续），没有一段包含
  当前位置时等于当前位置。web 后端另外监听 `progress`，暂停期间缓冲值也会
  跟着增长，不再等恢复播放才更新。
- **并发竞态第四轮收口（复审跟进）。**
  - **PiP 能力查询不再阻塞 `initialize()` 完成**（best-effort，`unawaited`，
    查询自带 backend 身份复查）：此前查询挡在 complete 之前，`dispose()` /
    `switchLine()` 打断查询后旧 initialize 反而在其后"完成为成功"（dispose
    不清 completer、switchLine 不换 completer，单查 completer 身份盖不住）。
    另在完成前按 initialize 入口捕获的 epoch 复查 `_disposed || epoch` ——
    拉起成功到 complete 之间的窗口也封死。
  - **PiP 中重建 backend 后新 backend 收养会话归属**：PiP 中 `load()` 换源 /
    `switchLine` / IJK 兜底会 dispose 旧 backend（归属成 tombstone），
    Activity 级 PiP 会话还在继续，此前遥控与 `pipStopped` 全被丢弃。新增
    `adoptOrphanedPipSession`：仅当当前 owner 已注销时把会话交给新
    backend（活 owner 不可被抢），controller 在拉起成功且自认在 PiP 中时
    调用。
  - **无 owner 的广播兜底收紧为"恰好一个订阅者才投递"**：宿主绕过 SDK 自行
    进 PiP 时，单实例兼容行为保留；多实例下无主会话归属不明，广播会把所有
    实例翻进 PiP 态、遥控让全体一起播放/暂停，现改为丢弃（onResume 兜底
    纠正状态）。
  - **失败候选的清理错误不再顶掉原始初始化错误**：`_bringUp` 失败路径的
    dispose 改为 best-effort（吞掉清理异常后按原 stack rethrow）——此前
    清理抛错会把网络/超时错误替换成清理错误，改变 `_categorize` 分类进而
    带偏 retry / IJK 兜底 / failover。
  - 手势初始亮度兜底：`initBrightness()` 在 backend 挂载前调用会永久跳过
    采集（示例的 `initState` 时序即如此），现以首次亮度手势"改动前的基准"
    补作恢复初值。
  - `NiumaPlayerPool.keyFor` 的 header 值哈希从 `String.hashCode` 换成双轮
    FNV-1a 32（64-bit 摘要，纯 Dart、VM/web 结果一致）：跨进程稳定、碰撞
    ~2^-64，池按 key 复用 controller 的正确性可依赖。
  - `NiumaDataSource.toString()` 对 uri 的 query 段脱敏（签名 URL 的 token
    通常在 query 里），替换为参数个数提示；`uri` 字段本身保留原文。
  - **Android lint 清零（存量 NewApi）**：`createPlayPauseRemoteAction`
    （`RemoteAction` 需 API 26、`Icon.createWithResource` 需 API 23，调用方
    均有运行时守卫）补 `@RequiresApi(O)`；`FEATURE_PICTURE_IN_PICTURE`
    内联常量豁免 InlinedApi。`:niuma_player:lintDebug` 此前 2 errors 直接
    构建失败。
- **并发竞态第三轮收口（复审跟进）。**
  - **初始化失败/超时的候选立即摘除销毁**：`Future.timeout` 不取消底层
    初始化，此前终局失败后失败候选仍挂在 controller 上——平台侧还在后台
    加载，迟到的 `ready` 会把已写入的 `error` 覆盖掉。现在 `_bringUp` 内
    初始化异常时按 `identical` 校验后就地 dispose（覆盖 initialize /
    switchLine / 回滚全部拉起路径）。
  - **池持有计数的二次 ABA（上一轮修复引入的回归）**：acquire 失败路径的
    无条件 `_unhold(key)` 会在 entry 已被 evict 换代后扣到**新 entry 持有
    者**的计数，让正在使用的播放器被 LRU/stale 误回收。换代路径本就整体
    清过 `_holds`，该补偿本不需要——已移除，失败清理仅走 `identical`
    校验的 `_remove`。
  - **PiP owner 注销不再回退广播串台**：backend dispose（feed 划走 PiP 中
    的播放器 / PiP 中 `load()` 重建）此前立即释放归属，系统会话未结束时
    后续 `playPauseToggle` / `pipStarted` 广播给所有实例。现在归属保留为
    tombstone（死 owner 的事件丢弃），`pipStopped` / `pipFailed` 清场；
    顶替 claim 走一格交接窗口：第一条 `pipStopped` 归前任、`pipStarted`
    关窗并给前任补退出事件、顶替者进入失败时归属还给前任。controller 侧
    `PipRemoteAction` 补"本实例在 PiP 中"守卫。
  - **PiP 能力查询期间被 `load()` 压倒**：旧 backend 的查询结果不再写进
    新媒体的 value（按 backend `identical` 复查）；查询期间被压倒的旧
    `initialize()` 按契约以 superseded `StateError` 结束，不再事后宣布成功。
  - stale 清理跳过 init 还在途的条目（与 LRU 的 pending 豁免同理），慢
    preload 不再被 sweep 中途销毁。
- **Android PiP 遥控 receiver 在 API ≤32 上隐式导出**：动态注册未带保护，
  任何应用广播 `ACTION_PIP_PLAY_PAUSE` 即可控制播放。改用
  `ContextCompat.registerReceiver(..., RECEIVER_NOT_EXPORTED)`（androidx.core
  在旧版本用应用私有签名权限背书），android 模块新增 `androidx.core:core`
  依赖。
- **凭据脱敏**：`NiumaDataSource.toString()` 不再回显 header 值（只回显
  header 名）——toString 会进异常链与日志；`NiumaPlayerPool.keyFor` 的
  header 值改进哈希、name 加长度前缀（key 会被调用方持有、还会出现在池的
  异常信息里），同时修复 `k=v;` 裸拼接的键值碰撞。带 headers 的 key 格式
  因此变更（无 headers 的裸 URL key 不变）。
- **手势初始亮度读回前 dispose 丢恢复**：`initBrightness` 的读数迟到时，
  若手势已动过亮度，现在补一次恢复到初值（此前 restore 因初值为 null 被
  跳过，亮度停在手势改过的值上）；读失败不再是潜在的 unhandled error。
- **Web `<video>` 过期 error 事件**：元素 `error` 属性为 null（`load()`
  换源已重置）时收到的 error 事件视为过期直接忽略，不再合成
  "unknown video error" 打断新源；补"旧 DOM 事件在 load 后到达"的浏览器
  回归测试。
- **过期链醒来后的收尾不再伤及新链（并发竞态第二轮收口）。**
  - `initialize()` / `switchLine()` 的 vp 失败兜底 catch 现在先做代际检查：
    被 `load()` / 新 `switchLine()` 压倒后才浮出的失败属于旧链自身（多半是
    压倒者销毁了它的 backend），不再 `dispose` 当前 backend（此前会**误杀
    新链刚挂上的 backend**，`_backend` 置空、play/pause 全部空操作）、不再
    为旧源拉起 IJK、不再上报 `FallbackTriggered` / `LineSwitchFailed`。
  - `_detachBackend` / `_disposeCurrentBackend` 改为**先同步摘共享字段再
    await cancel/dispose 快照对象**：旧链在 cancel 的 await 期间醒来不会再
    清掉甚至 cancel 掉新链的订阅。
  - 候选拉起的 error 抑制与稳定快照冻结从全局计数改为**按代际登记**
    （`Set<int>`）：卡死在 middleware / 平台 Future 里的旧链不再永久吞掉
    新链 backend 的真实 error、不再永久冻结切换快照。middleware 现在计入
    `initTimeout` 预算（此前无界，可让 `load()` future 永远悬着）。
  - `load()` 原地换源在 `backend.load` 之后、`switchLine` 在恢复播放的
    `play()` 之后补上代际复查：被压倒的 `load()` 不再"明明输了还宣布成功"
    （屏幕是 A、`source` 是 B），被压倒的 `switchLine` 不再事后补发
    `LineSwitched`。
  - `test/controller_concurrency_test.dart` 新增 4 个交错序列用例。
- **PiP 事件多实例串台**：所有 backend 共用同一条 PiP EventChannel，事件不带
  播放器身份，一个播放器退出 PiP 时**其他正在播的 controller 也会收到
  `pipStopped` 被自动暂停**（播放器池 / feed 多实例必现）。现在归属在 Dart
  侧维护：backend 发起进入 PiP 时 claim owner，`pipStopped` / `pipFailed`
  结束会话自动释放；有 owner 时事件只投给 owner，无 owner（宿主绕过 SDK
  自行进 PiP）保持广播兼容单实例旧行为。controller 侧再加一道防线：本实例
  从未进过 PiP 时收到的"退出"事件不暂停、不透传。新增
  `test/data/pip_event_bus_test.dart`。
- **`NiumaPlayerPool` 同 key 换代（ABA）竞态**：`_remove(key)` 不校验条目
  身份，被 evict 淘汰的旧 preload 的失败回调迟到时，会把同 key 的**新**
  entry 连人带持有计数一起删掉并 dispose（acquire 方拿到已释放的
  controller）。现在移除按 `identical` 校验预期条目，失败路径只归还自己的
  持有计数；init 还在途的 preload 不再被选为 LRU victim（中途 dispose 白干
  一次拉起还触发上述 ABA）。
- **`NiumaGestureController.dispose()` 后在途异步回调触碰已释放的 notifier**：
  拖动中页面销毁时，亮度 / 音量基准值经 method channel 的读数回来后仍会
  `_showHud` 写已 dispose 的 `feedback` ValueNotifier（debug 断言崩溃）；
  dispose 后 `onPanEnd` 还会新建 HUD 隐藏 Timer 再撞一次。现在 dispose 置位
  并幂等，所有手势入口与在途回调（读数、Timer）此后全部安全空操作。
- **`WebVideoBackend` 构造期设 src 的缓存命中可让 `initialize()` 永挂**：
  极快就绪的媒体在 `initialize()` 之前触发 metadata 会提前消耗 once-only 的
  就绪标记（彼时还没有 completer 可完成），之后 `initialize()` 一直挂到
  `initTimeout` 被误判成超时失败。现在 `initialize()` 重置该标记。
- **CI 覆盖率 artifact 重名**：analyze+test 矩阵两条腿都上传 `name: coverage`，
  upload-artifact@v4 对重名直接报错（v3 才是合并），后完成的腿必红。改为
  `coverage-${{ matrix.label }}`。
- **`switchLine` 失败时候选线路的 `phase=error` 不再泄漏进 `value`；切换前
  快照取自稳定状态。** 模拟器验收抓到：用户切到不可用线路，候选 backend 初始化
  阶段推出的 error 进了 `value`，上层"播放中途自动容灾"据此抢先又发起一次
  `switchLine` 压倒了用户那次，且其位置 / 播放快照取自半成品（0:00、未播放），
  回滚后播放器停在 0:00 暂停。现在：切换进行中候选的 error 不写 `value`
  （"切换失败 = 什么都没发生"，失败由 `LineSwitchFailed` 通知）；禁用回滚或回滚
  也失败时才显式把 `value` 落到 error（此前这条路径 `value` 会一直停在
  `playing`）；`switchLine` 的位置 / 播放快照改取最近一次稳定状态，并发切换时
  不受候选半成品影响。同一规则也覆盖 `initialize()` / `load()` 的候选遍历
  （多线路 failover、IJK 兜底）：此前默认线路候选失败、下一条还在加载的窗口里
  `value` 已是 error，UI 会先闪错误层再"自愈"（网络慢时在模拟器上复现）。
  切换前的"是否在播"改用 `effectivelyPlaying`（含 buffering）：此前原线路正在
  缓冲时发起切换，失败回滚后会停在暂停态等用户再点一次。
  新增 `test/switch_line_snapshot_test.dart`。
- **手势亮度 / 音量基准值读回期间松手会抛 `Null check operator`**：
  `onPanEnd()` 清掉 `_lockedKind` 后，异步读回的 `onPanUpdate` 续体仍
  `_lockedKind!`。现在按手势序号校验，已结束 / 已换手势的读数直接丢弃——
  也不会再用上一手势迟到的读数覆盖新手势的基准。
- **Controller 并发操作竞态：`load()` / `switchLine()` 现在是"最后一次说了算"。**
  此前代际守卫只在 bring-up 的第一个 await 之前检查一次，且 `switchLine()`
  根本不递增代际；`load()` 打断卡在 middleware（签名 URL 等）里的
  `initialize()`、或两次 `switchLine()` 交错时，先发的旧链醒来后会把自己的
  backend 挂回去、拆掉新链的订阅，造成**画面是旧源 / `activeLineId` 与实际
  播放线路不一致 / 平台播放器泄漏 / `BackendSelected` 重复**。现在每个
  破坏性操作开始时递增代际，在途链在每个 await 之后复查，过期链在造 backend
  之前退出（造了也自行销毁）。
  - 被压倒的 `initialize()` / `load()` / `switchLine()` future 以
    `StateError("… superseded or disposed")` 结束；被压倒的 `switchLine()`
    不回滚、不发 `LineSwitchFailed`；生命周期取消不再写 `value.error`。
  - web 原地换源：`initialize()` 还在途时 `load()` 改走重建，不再对半初始化
    的 `<video>` 调 `load()`。
  - 新增 `test/controller_concurrency_test.dart` 覆盖上述交错序列；
    测试替身抽到 `test/helpers/fakes.dart` 共享。
- **多线路契约与实现对齐。**
  - 首播顺序：`defaultLineId` 线路永远先试；`autoFailoverOnInitialError` 只决定
    失败后是否把**其余**线路按 priority 升序再试（此前是全部线路按 priority
    排序，默认线路可能不是第一个——与文档不符）。
  - `activeLineId` / `dataSource` 现在指向**实际在播**的线路：failover 落到
    备线路、`switchLine` 成功后跟着更新；切换进行中仍是原线路（此前
    `dataSource` 恒为默认线路，`activeLineId` 在拉起之前就改了）。
  - Android：`switchLine()` 与首播同一套规则——目标线路 vp 起不来时当次会话
    内 IJK 兜底，而不是切线失败；本会话回退过 IJK 后，同一媒体的后续切线 /
    回滚直接走 IJK，`load()` 换媒体时清除该记忆（此前回退后切线会重新尝试
    vp，失败 + 回滚失败后播放器直接不可播）。
  - `NiumaMediaSource.lines` 构造时拒绝重复的线路 id，并复制成不可变列表，
    调用方之后改动传入的 List 不再影响已构造的 source。
  - 新增 `test/multi_line_contract_test.dart`。
- **`WebVideoBackend` 换源 / 直播 / headers 三处契约缺口。**
  - 直播 HLS（`<video>.duration = Infinity`，Safari / iOS 原生 HLS 必现）此前
    因"duration 必须有限且 > 0"永远初始化不完，等到 `initTimeout` 后被当成网络
    错误 failover；现在拿到元数据（`HAVE_METADATA`）即就绪，`value.duration`
    上报 0。判定抽成纯函数 `isWebMediaReady` / `webDurationToValue`。
  - `load()` 引入源代际：快速连续 `load()` 时旧的 completer 立刻以
    `StateError("… superseded")` 结束（不再等 30s 超时），跨 hls.js 脚本加载
    的 await 回来的旧 load 不再用新源 uri 多建一个无人持有的 `Hls`；hls.js
    错误回调绑定到实例，换源后旧实例迟到的 fatal 错误不会把新源打成 error。
    `initialize()` / `load()` 改为同步返回 future。
  - 不再在传了 headers 时把 `<video>.crossOrigin` 设成 `anonymous`：原生媒体
    请求本来就带不上自定义 header，anonymous 只会让没配 CORS 的服务器拒掉
    本来能播的 mp4、并丢掉 cookie。`NiumaDataSource.headers` dartdoc 与
    README 写明 web 上 headers 只在 hls.js 路径生效。
  - 新增构造参数 `WebVideoBackend(hlsJsLoader:)` 与 `htmlVideoElement` getter。
  - 新增 `test/web/web_video_backend_test.dart`（真浏览器，
    `flutter test --platform chrome test/web`，CI 已接入）与
    `test/web_media_readiness_test.dart`。
- **`NiumaPlayerPool` 持有模型收紧。**
  - 持有改为**计数**：同一 key 被多个消费者 `acquire` 时，一个 `release`
    不再让另一个仍在用的 controller 变成 LRU / stale 的回收对象；所有持有者
    都 `release` 后才可回收（此前是 Set，任一 release 即可回收）。多余的
    `release` 不会把计数打负。**调用方须保证 `acquire` 与 `release` 次数配对。**
  - 默认 key（`keyFor`）改为复合：network 且无 headers 时仍是裸 URL（向后
    兼容），非 network 类型追加 `|type=…`，带 headers 追加排序后的
    `|h=k=v;…`——同 URL 不同鉴权信息不再错误复用同一个 controller。
  - 新增构造参数 `keyBuilder` 与实例方法 `keyOf(source)`，可自定义 key
    策略（自定义后 release / evict / holds 的 key 请用 `keyOf` 计算）。
  - `dispose()` 之后 `acquire` / `preload` 抛 `StateError`（此前会静默建出
    永远无人回收的 controller）；`release` / `evict` / `holds` 为安全空操作。

## [0.5.2] - 2026-07-27

### Changed

- **IJK 产物改用 `c++_static` 链接**：不再随包分发 `libc++_shared.so`。
  实测五个 ijk `.so` 里只有 `libijksoundtouch` 真用 C++ 运行时（0.1 → 0.4 MB），
  其余体积不变，不存在「每个 so 各带一份 libc++」的膨胀。
  装机体积 arm64-v8a 9.9 → **8.5 MB**、armeabi-v7a 7.5 → **6.4 MB**，
  aar 7.7 → 6.9 MB。相对 GSY 官方产物的净增从 +2.7 MB 压到 +1.3 MB。

### Fixed

- example 的默认测试流误提交成了内部签名地址（0.5.1 随包发出），
  改回公开示例源。

## [0.5.1] - 2026-07-27

### Fixed

- **Android IJK 软解兜底重建：改用自编 FFmpeg 8.1，修好 fMP4 分片 HLS 的三处硬伤。**
  产物从 GSY 官方（FFmpeg 4.x）换回自编 `ijkplayer-0.8.8-ff8.1-20260727`
  （arm64-v8a + armeabi-v7a，minSdk 保持 21）。fork 自带的私货与旧假设逐条修掉：
  - **fMP4 位置恒 0 / seek 后永久卡 buffering**：`ffp_get_current_position_l()`
    对 `ic->start_time` 的假设不适用于 fMP4（`start_time` 取自分片的
    `baseMediaDecodeTime`，是个很大的值，而 master clock 不含此偏移），
    `pos < start_diff` 恒成立直接返回 0。画面其实一直在正常播，坏的只是位置上报。
  - **起播黑屏 2.4~5.7 秒**：fork 在 `ffp_check_buffering_l()` 里为「逼出首帧」
    做 `seek_to(0)`，而 `show_first_frame` 只有首帧显示后才清零、缓冲期间又
    显示不出来 → 每轮缓冲检查都 seek 回 0 → 分片反复重拉。实测起播要读
    23~26 个分片（约 140 秒内容）；移除后降到 1~2 片。
  - **H.264 有声无画**：fork 在 `stream_component_open()` 里无条件优先取
    `*_mediacodec` 解码器，**无视 `mediacodec` 选项**。niuma 显式设了
    `mediacodec=0` 仍会走硬解 wrapper，H.264 上 `avcodec_open2` 失败
    （EINVAL）导致视频组件根本没打开。改为尊重选项。
  - `PlayerSession` 心跳补一道 buffering 出口兜底：位置在推进即视为帧在流，
    snap 回 playing——不再依赖 `BUFFERING_END` 事件（fMP4 上它不发）。
  - 编译链、补丁（`patches/0001~0003`）、`VERSIONS.lock`、
    `module-niuma-ff8-slim.sh` 全部回归本仓；踩坑记录见
    `doc/ijk-fmp4-hls.md`。
- **播完后拖回进度可能永远转圈**：video_player 在 completed 事件里调的是
  自己的 `pause()`，绕过 `VideoPlayerBackend.pause()`，播放意图停在 true；
  而拖动进度会把 `isCompleted` 翻回 false，底层重新缓冲就被推导成
  `buffering`——spinner 不灭、按钮显示正在播、实际没播。现在观察到
  completed 即作废播放意图。触发要求 seek 目标处发生重缓冲，真机上表现为
  间歇（HLS / 长视频 / 弱网更易命中）。

## [0.5.0] - 2026-07-25

### Changed

- **Android 主内核切换为官方 `video_player`**（2.0 架构）：三端主路径统一走
  官方 video_player（iOS AVPlayer / Android ExoPlayer / Web `<video>`），由
  Flutter 官方维护、可随意升级；niuma 退居「编排壳」——多线路 failover /
  retry / middleware / 手势 / 全屏 / wakelock / PiP 编排 + **Android IJK
  软解兜底**（video_player 初始化失败时当次会话自动接管，`forceIjkOnAndroid`
  可显式强制）。自研 ExoPlayer 会话（`ExoPlayerSession.kt`）与 media3 直接
  依赖删除——ExoPlayer 升级、Android 新版本适配从此归官方 video_player。
  - 多线路 auto-failover 逻辑对 Android 主路径同样生效（此前仅 iOS / Web）
  - vp 初始化 wall-clock 超时补发 `FallbackTriggered(timeout)`（对齐原
    native 路径的排障信号）
  - `BackendSelected.kind`：Android 主路径成功时为 `videoPlayer`（原为
    `native`）；IJK 兜底成功时仍为 `native`
  - `useAndroidPlatformView: true` 在主路径映射为 video_player 的
    `VideoViewType.platformView`（0.3.3 根治有声黑屏的渲染路径在 vp 主路径
    等价保留；IJK 兜底路径仍走自家 Hybrid Composition）
- **新增 Dependabot**（pub / gradle / actions）：video_player 等依赖出新版
  自动提 PR 并由 CI（analyze + test + example apk 构建）验证兼容性。
- **BREAKING：环境门槛提升**——`video_player >=2.10`（viewType）要求
  Flutter >=3.27 / Dart >=3.6，pubspec environment 同步收紧。

### Fixed

- **暂停被误报成 `buffering`**：vp 的 `pause()` 只翻 `isPlaying`、不动
  `isBuffering`，而 ExoPlayer 暂停只改 `playWhenReady`、不改 `playbackState`
  （收不到 `bufferingEnd`）——在缓冲窗口内按暂停会永久停在 `buffering`：
  `effectivelyPlaying` 恒 true 导致播放/暂停按钮不翻转，spinner 也不灭。
  `VideoPlayerBackend` 现在自己记录播放意图，`derivePhaseFor` 据此推导，
  不变量是**无播放意图时永不产出 `buffering`**——与 `PlayerPhase.buffering`
  的既有文档契约（「播放意图为真但解码器拿不到数据」）一致，也与 1.x
  native 路径的 `PlayerSession.userWantsPlay` 同语义。web 路径按 `<video>`
  的 `paused` 真值推导，本就不受影响。
- **Android platformView 退出全屏后画面冻结**：`useAndroidPlatformView: true`
  时 vp 的平台视图构造即 `setVideoSurfaceView(自己)` 抢走 ExoPlayer 的独占
  输出 surface，销毁时只释放自己的 surface 不归还。宿主用共享 controller
  实现无缝全屏（inline 那份全屏期间仍挂在树上）时，退全屏后 player 绑在已
  释放的 surface 上——声音和进度正常，画面停在最后一帧。现在同一 controller
  下只有最后 mount 的 `NiumaPlayerView` 构造 vp 渲染 widget，它 unmount 时
  所有权回退给仍存活的上一个并重建，绑定自然恢复（与 1.x 自研 native 路径
  `PlayerSession.surfaceStack` 同语义）。接入方零改动；texture 路径与 iOS
  不受影响。
- **Android 9（API 28）上 vp 主路径自动降级 textureView**：该版本 video_player
  的平台视图走 `setupSurfaceWithCallback`——`surfaceCreated` 里无条件
  `seekTo(1)`（surface 每次重建都跳回开头，切后台再回来也会）、
  `surfaceDestroyed` 里无条件 `setVideoSurface(null)`（不判断当前绑的是不是
  自己）。多 surface 交接必然黑屏，`useAndroidPlatformView` 在 API 28 上因此
  自动失效。IJK 兜底路径走自家 `PlayerSession.surfaceStack`，不受此限。
- **倍速状态不再被打回 1.0**：vp / IJK 两后端的 value 映射漏带
  `playbackSpeed`，`setPlaybackSpeed(2.0)` 后下一条底层通知会把公开
  `value.playbackSpeed` 覆盖回 1.0（实际播放仍 2x，UI 倍速指示闪回）。
- **switchLine + `forceIjkOnAndroid` 播错线路**：IJK 路径此前固定拉默认
  线路，目标线路被忽略（事件却报 LineSwitched 成功）；现按目标线路拉起。
  vp 多线路全失败落 IJK 兜底后 `activeLineId` 也同步校正为实际播放的默认线。
- **switchLine 重试改为重建式**：原实现在同一个已失败的 backend 上反复
  `initialize()`（vp 失败后不重建必然再失败）；现与 init 路径共用同一
  拉起序列（dispose → middleware → 重建 → init）。
- **三处生命周期竞态**：dispose 后仍在退避重试中的 init 链会把新建的平台
  播放器 attach 到已销毁的 controller 上（feed 快滑泄漏源）；init 未完成时
  `load()` 换源会出现双活 init 链互相拆台；`NativeBackend.dispose()` 不
  settle 等待中的 initialize（只能干等 initTimeout）。现分别以代际号 /
  attach 前置检查 / completeError 处理。
- **播放器池并发窗口**：`preload` 未 await 时立刻 `acquire` 会拿到未
  初始化的半成品 controller（或在 evict 窗口重复建导致泄漏）——entry
  插入与 pending 赋值改为同一同步段完成，附回归测试。
- **手势亮度/音量起手闪谷底**：锁定方向后基准值异步读回期间的指针事件
  以 0.0 为基准直接把系统亮度/音量设到谷底；现读回完成前丢弃。
  水平 seek 结束改为提交拖动中算好的目标，不再从 HUD 进度反算（丢精度）。
- **Android PlatformView 会话 id 与 texture id 可能撞号**：两套分配器
  空间重叠，混用两种渲染模式时后建会话会顶掉先建的（泄漏）；PV id 起点
  抬到 1e12 隔离。
- **web 后端**：移除必然 MissingPluginException 的 PiP 总线订阅（每会话
  一条控制台红错）；`timeupdate` 双 listener 合并为一次 value 广播。

### Removed

- **BREAKING：`PlatformBridge.deviceFingerprint()` 删除**——设备记忆策略
  （0.4.0 移除）的最后残留，SDK 内已无任何消费方；自定义 `PlatformBridge`
  实现删掉该 override 即可。native `create` 协议同步移除 `fingerprint` /
  `fromMemory` 返回字段与 `deviceFingerprint` handler。
- **BREAKING：`PlayerBackend.webFullscreenState` 删除**——从未被写入
  （恒 false）也无消费方；web 全屏状态由
  `webFullscreenRouteCountListenable` 承载。
- **BREAKING：投屏（Cast）整体移出核**——值类型（`CastDevice` /
  `CastSession` / `CastConnectionState` / `CastEndReason`）、controller 的
  `connectCast` / `disconnectCast` / `castSession`、事件 `CastStarted` /
  `CastEnded` / `CastError` 全部删除（协议实现本就在 git 历史参考皮）。
  核收敛为"干净的播放"：需要投屏的业务自持会话对象，播放侧只需
  `pause()` 本地播放器。
- **BREAKING：`danmakuVisibility` 删除**——弹幕引擎 0.1.0 已随参考皮出核，
  该遗留字段核内零消费；业务自持一个 `ValueNotifier<bool>` 即可。
- **BREAKING：`BackendFactory.createNative` 移除 `forceIjk` 参数**（2.0 起
  native 只有 IJK 会话，参数恒 true 无意义）；`NativeBackend` 构造与
  create 协议同步移除。`NiumaPlayerValue.copyWith` 移除零调用的
  `clearOpeningStage`；`GestureFeedbackState` 移除零调用的 `copyWith`。
- 全库死代码清理：backend 级 `FallbackTriggered` 发射（controller 一律
  丢弃，权威版本由 controller 自发）、native 全局 channel 的
  play/pause/seek/setSpeed/setVolume 死分支与 `forward()`、
  `NativeBackend.selectedVariant` 公开 getter、PlayerSession 的
  Exo 时代钩子（onHeartbeatTick 等）、iOS/Android 的 getPlatformVersion
  模板残留、gradle 的 no-op abiFilters / packagingOptions。

## [0.4.0] - 2026-07-22

### Changed

- **Android IJK 产物切换为 GSY 官方 MavenCentral 分发**
  （`io.github.carguo:gsyvideoplayer-java/-ex_so:11.3.0`，bilibili ijkplayer
  0.8.8 血统 + FFmpeg 4.3 全量：h264 / h265 / mp4 / HLS 全支持，minSdk 21）。
  替换原自编 ShikinChen ff7.1 slim aar——后者存在 fork 私货（缓冲期反复
  `seek(0)` 的 show_first_frame hack）与高码率流软解不出帧的问题，真机表现
  为「有声无画 / 无限 buffering」。换装后同一条 2568×1440 加密 HLS 在 IJK
  软解下正常出画（OPPO 真机验证）。
- **移除设备记忆策略（Try-Fail-Remember）**：一次 ExoPlayer 失败不再被持久
  化、不再影响后续会话的内核选择——SDK / 源侧问题修复后设备立即回到硬解
  快路径。内核选择完全由 `forceIjkOnAndroid` 显式决定；会话内 Exo→IJK 的
  单次兜底重试保留（不落盘）。
  - **BREAKING**：删除 `NiumaPlayerController.clearDeviceMemory()`；
    `BackendSelected.fromMemory` 字段保留但恒为 `false`（废弃语义）。
- IJK `framedrop` 固定为 0：软解跟不上实时的临界场景下 `framedrop>0` 会把
  所有帧 early-drop 掉（有声无画黑屏）；0 的代价是可能渐进失步，两害取轻。

### Added

- **`EngineFallbackFailure`**：Android 双内核（Exo + IJK 兜底）都失败时抛出
  的组合异常，同时携带两段原始错误——修复「只报最后一环 IJK 错误、把 Exo
  的根因（如 HTTP 403）掩盖」的排障陷阱。
- example 新增「内核切换测试」页：运行时切 ExoPlayer / IJK 对比同一条流。

### Fixed

- IJK `probesize` 曾被设为 100KB「加速 prepare」——对 6Mbps+ 高码率 TS 连
  一个视频关键帧都探不齐 → 视频流缺失（`-10000` / 无限 buffering）。改回
  FFmpeg 默认（probesize 是上限而非必读量，调大零成本）。
- IJK 移除 `reconnect_streamed=1`：它把 HLS 分片的正常 EOF 当断连，无限重
  连同一分片导致播放卡死。

### Removed

- `android/localmaven/` 自编 ijkplayer aar 与 `android/scripts/` FFmpeg
  编译链整体退役（GSY 产物上线后不再需要；git 历史可寻）。

## [0.3.4] - 2026-07-21

### Fixed

- **初始化失败「无限转圈、无失败提示」**：`initialize()` 失败（如 IJK
  prepare 卡死触发 30s `initTimeout`）时，错误此前只经 `initialize()` 返回的
  future 传播，`value.phase` **从不进入 error 态**——调用方若未 catch future，
  靠 `value` 驱动的错误层永远收不到失败，用户只见无限 buffering（真机实测）。
  现失败同步落入 `value`（`phase=error` + `value.error` 按既有规则分类），
  错误 UI 自然显示，接入方零改动受益。

### Added

- **H.265 / HEVC 全链路支持**：
  - **新增 `NiumaCapabilities.supportsHevc()`** 能力检测——Android 查
    `MediaCodecList` 是否存在 `video/hevc` **硬件**解码器（纯软解不算），
    iOS 恒 `true`（系统级支持），web 走 `MediaSource.isTypeSupported` +
    `canPlayType` 双探测。典型用途：源协商——业务据此决定向服务端请求
    H.265 还是 H.264 源（协议字段业务自定，SDK 不自动附加任何请求头）。
    结果进程内缓存。
  - **IJK 软解兜底重新支持 HEVC**（撤销 0.2.1 的裁剪）：重编 ijkplayer aar
    加回 `hevc` decoder / parser / `hevc_mp4toannexb` bsf / `hevc_mediacodec`。
    此前兜底链对 H.265 是断的——硬解失败切 IJK 后彻底播不了；现在闭环。
    体积代价：aar 7.37 → 7.67 MB（arm64 `libijkplayer.so` 6.5 → 6.9 MiB）。
  - 播放侧无需任何配置：流是 h264 还是 h265 由解封装自动识别。
  - **vendored hls.js 1.5.20 → 1.6.16**：补齐 web（Chrome / Edge 等 MSE
    浏览器）的 HLS H.265——TS 分片里的 HEVC 是 hls.js 1.6.0 才支持的，
    1.5.x 下即使浏览器能解也播不了。升级后
    `NiumaCapabilities.supportsHevc()` 的检测结果与实际播放链路对齐。
    已回归：h264 TS-HLS（mux 测试流）正常；HEVC fmp4 HLS（bitmovin
    测试流）Chrome 实测出画。API 面（`isSupported` / `attachMedia` /
    `loadSource` / `destroy` / `xhrSetup` / `hlsError`）1.6 全兼容。

## [0.3.3] - 2026-06-16

### Fixed

- **Android PlatformView「有声黑屏」根治**（`useAndroidPlatformView = true`）：
  渲染从裸 `AndroidView` 改为真正的 **Hybrid Composition**（`PlatformViewLink`
  + `PlatformViewsService.initExpensiveAndroidView`）。裸 `AndroidView` 走
  TLHC / Virtual Display——靠把原生 view 拷进 Flutter 纹理再合成，而
  SurfaceView 的像素画在独立 Surface 上、纹理拷贝抓不到 → 合成出来是黑的
  （声音/状态机正常但画面全黑，进/退全屏、锁屏解锁、切后台最易触发；
  flutter#128920 / #172641 / #144219）。HC 把 SurfaceView 插进原生视图层级
  直接渲染，画面正常显示，原生缩放 / HDR 保留，Flutter 控件仍可叠层。
  - 用 `initExpensiveAndroidView`（纯 HC，**不回退 VD**），不用
    `initAndroidView` / `initSurfaceAndroidView`（不兼容场景会回退 Virtual
    Display 又黑回去，flutter#107313）
  - Kotlin 侧零改动；surface 栈 / `PlayerSurfaceView` / `PlayerSession` 全部
    保留（它们管退全屏 codec error，与黑屏正交）
  - OPPO Android 16 真机验证：进 / 退全屏画面正常
  - 注：Hybrid Composition 在多实例 + 频繁创建销毁（feed）下开销大于单
    播放器；feed 等场景如性能吃紧可继续用默认 Texture 路径

## [0.3.2] - 2026-06-14

### Fixed

- **Android IJK 软解音画失步**：`framedrop` 由 `0` 改为 `1`。被钉死走 IJK 软解
  的机型上，高码率 / 高帧率 / 倍速视频解不过实时，`framedrop=0` 让落后的视频
  帧一帧不丢 → 相对音频主钟渐进失步（画面比声音慢、对不上嘴，越看越脱节）。
  改为允许丢晚帧让视频追上音频主钟（解不动时偶尔跳帧，但保持同步）。
- **Android ExoPlayer 开启解码器回退**：`DefaultRenderersFactory
  .setEnableDecoderFallback(true)`。硬解 codec 初始化失败时同会话内自动尝试
  下一个（含软件）解码器，而非直接抛错绕 Dart 重试 → IJK（少一次错误闪）。

### Changed

- **codec 失败记忆 `NO_EXPIRY` → 7 天 TTL**：此前首帧前硬解 codec 失败会把该
  设备**永久**钉死走 IJK 软解（哪怕只是单条视频 / 单次 codec 抽风），导致本可
  硬解的视频长期走软解（卡 / 发热 / 音画失步）。改为 7 天有效期：近期重试仍直
  接走 IJK 避免反复撞坏 codec，到期后回 ExoPlayer 硬解重试。读取判定与到期清理
  Dart 侧早已就绪。

## [0.3.1] - 2026-06-12

### Added

- **播放中自动保持屏幕常亮（wakelock）**：修复「播到一半自动熄屏」。
  `NiumaPlayerController` 在 playing 边沿自动保持 / 释放亮屏（暂停、结束、
  出错、dispose 都会释放），多实例（feed / 池）以进程级计数归并——任一在播
  即亮屏，全部停了才释放。Android 走 `FLAG_KEEP_SCREEN_ON`（窗口级、无需
  权限、退后台自动失效），iOS 走 `isIdleTimerDisabled`，web 无操作（浏览器
  播 `<video>` 自身防熄屏）。
  - 新增 `NiumaPlayerOptions.manageScreenWakelock`（默认 `true`；音频类
    业务想允许熄屏可置 `false`）
  - `PlatformBridge` 接口新增 `setKeepScreenOn(bool)`——**自定义
    `PlatformBridge` 实现方需补该方法**（0.x 下随 minor 发布）

## [0.3.0] - 2026-06-12

### Added

- **Android PlatformView（SurfaceView）渲染路径（opt-in）**：
  `NiumaPlayerOptions.useAndroidPlatformView = true` 时，Android 视频改由
  PlatformView（SurfaceView **原生缩放**）渲染，替代 Flutter Texture——从根
  上解决 Texture 路径的画质模糊，且不吃 `filterQuality` 的每帧采样开销。
  默认 `false`（行为与 0.2.x 完全一致），iOS / web 忽略此选项。
  - 原生侧新增 `PlayerSurfaceView` / `PlayerSurfaceViewFactory`（viewType
    `cn.niuma/player_surface`）；`NiumaPlayerView` 自动按 backend 选
    `AndroidView` 渲染分支
  - **surface 栈**：全屏路由 push 时第二个 SurfaceView 抢绑定、销毁时自动
    回退绑定到 inline 仍存活的 surface——退全屏不再输出到 dead Surface
    导致 codec 报错（OPPO Android 16 真机验证）
  - **prepare 不等 surface**：ExoPlayer / IJK 无 surface 即可 prepare
    （音频与状态机照常推进），surface 何时到画面何时出——feed 类
    「initialize → play → 才渲染激活页」的 mount 顺序不会死锁
  - 接入建议：详情页 / 单播放器开启收益最大；feed 每滑一条重建
    SurfaceView 有黑闪，建议维持默认 Texture。`NiumaPlayerView` 外请保持
    松约束（如包 `Center`），全屏路由建议快淡/瞬切（参考 example）
- `PlayerBackend.androidPlatformViewId` getter（默认 `null`）。

### Changed

- **`BackendFactory.createNative` 增加 `useAndroidPlatformView` 可选参数**——
  自定义 `BackendFactory` 实现方需同步该签名（0.x 下随 minor 发布）。

## [0.2.3] - 2026-06-07

### Changed

- **Android Texture 路径默认提一档画质**：`NiumaPlayerView` 新增
  `filterQuality` 参数，**默认 `FilterQuality.medium`**（双三次插值），替代
  Flutter `Texture` 硬编码的默认 `FilterQuality.low`（双线性）。修复反馈
  「视频有点花、不够高清」（多见于小米15 等大屏 / 高 DPI 现代机型，原默认 low
  在拉伸时糊感明显）。medium 在 2020+ 中端机以上无可感性能开销。极致性能场景
  （feed 多实例 + 低端机）可显式传 `FilterQuality.low` 降回旧默认。
  iOS 不受影响（`VideoPlayer` widget 内走 AVPlayer 原生 scaling）；web
  同样不受影响（浏览器直接缩放）。
- **下一步预告**：长期方案是把 Android 渲染改为 PlatformView（SurfaceView
  原生缩放），从根上去掉 Texture 路径的每帧 filterQuality 开销。已起
  `feat/android-platform-view` 分支，待真机回归后发 0.3.0。

## [0.2.2] - 2026-06-07

### Fixed

- **web rapid seek 卡 buffering**（Chrome/Firefox/Edge + hls.js）：`WebVideoBackend.seekTo`
  改为合并模式（latest-wins）——已有 seek 在路上时新调用只更新目标，待 `'seeked'`
  事件后再 fire 最新值，避免反复 seek 把 hls.js 的 `SourceBuffer` 卡进
  `updating=true` 永不释放、`'playing'` 永不来。配 3s 安全 timer 兜底（极端 case
  浏览器漏发 `'seeked'` 时也能解锁）。
- **Safari + hls.js 在已 buffered 区间 seek 后 phase 卡 buffering**：新增
  `'seeked'` 事件监听，按 video 真值兜底校准 phase（仅当 phase 为 buffering
  时纠正，playing/paused/ended/error 等明确状态保持不动）。修复多次快进快退
  后 UI spinner 不消失、底栏图标错乱、点击屏幕才恢复的 quirk。
- **`load()` 换源时残留 seek 状态**：换源即作废 `_isSeeking`/`_pendingSeek`/
  `_seekSafetyTimer`，避免锁跨源残留导致换源后第一次 seek 被吞。

## [0.2.1] - 2026-06-07

### Fixed

- **web HLS：hls.js xhrSetup 跳过浏览器 forbidden request headers**：
  `WebVideoBackend` 给 hls.js 配 `xhrSetup` 时把 `dataSource.headers` 里的
  `referer` / `host` / `origin` / `user-agent` / `cookie` 等浏览器禁止 JS 设置
  的请求头跳过，避免 hls.js 抛 `Refused to set unsafe header "referer"`
  并中断 HLS 加载。鉴权 token 等正常 header 仍透传。

### Changed

- **Android ijkplayer aar 砍掉 HEVC（H.265）软解兜底**，进一步精简：
  `libijkplayer.so` arm64 6.9→6.5 MiB / armv7 5.5→5.1 MiB，aar 7.6→7.0 MiB，
  对应 APK 单 arm64 ABI 省 ~400KB。decoder 仅留 `h264 / aac / aac_latm / mp3* +
  h264_mediacodec / mp3_mediacodec`；HEVC 解封装/parser/bsf 同步移除。
  **影响**：IJK 软解兜底路径不再支持 H.265；Android ExoPlayer 主路径仍可硬解
  H.265，仅在「ExoPlayer 翻车 + 视频是 H.265」双重场景才会播不了。点播
  mp4+HLS（主流 H.264 编码）不受影响。编译配置见
  `android/scripts/compile/modules/module-niuma-ff7-slim.sh`。

## [0.2.0] - 2026-06-05

### Added

- **`NiumaPlayerController.load(NiumaMediaSource)`** 原地换源（+ `PlayerBackend`
  的 `supportsSourceSwap` / `load`）：复用当前 backend 换到新源。web 后端复用
  同一个 `<video>` 元素换 src（`supportsSourceSwap=true`），**保住 iOS Safari 的
  有声播放激活**——"滑到才知道下一条 URL"的 feed 可用一个 controller 反复换源，
  而非每条新建 controller、每条丢激活导致只能静音。backend 不支持换源时自动
  dispose + 重建兜底。
- **web 全屏分流原语**（`NiumaWebFullscreenMode` / `webFullscreenMode` /
  `requestBrowserFullscreen` / `exitBrowserFullscreen` / `onBrowserFullscreenChange`，
  自 `web_fullscreen_coordination`）：把「浏览器全屏能力检测（安全读
  `fullscreenEnabled`、绕开 iOS Safari `undefined` 抛 `TypeError`）+ 画布真全屏
  进出 + 全屏状态监听」收进核，接入方据 `webFullscreenMode` 分流即可、不必碰
  DOM：`nativeVideoElement`（iOS Safari，走系统 player 全屏）/ `browserElement`
  （Chrome 等，走画布真全屏 + 自家全屏页）/ `notWeb`。
- **`NiumaPlayerController.setWebNativeControls(bool)`**（+ `PlayerBackend` 同名
  方法）：web-only，开 / 关底层 `<video>` 的浏览器原生控件。iOS Safari 上 Flutter
  自定义控件叠在 `<video>` 上会被浏览器吞、点不动，接入方可开原生控件兜底
  （播放 / 进度 / 全屏交给浏览器）。非 web backend 为空操作。

### Fixed

- **web video 被 DOM reparent 后自动续播**：`WebVideoBackend` 维护「播放意图」，
  video 因全屏搬迁等被浏览器自发暂停时，只要意图仍在播就自动续播——修复
  「Chrome 进全屏 / 退全屏后视频卡停」。用户主动 `pause()` 不受影响。
- **iOS Safari 退出原生全屏后自动恢复播放**：`WebVideoBackend.enterNativeFullscreen()`
  走 `webkitEnterFullscreen` 时记住进全屏前的播放态，监听 `webkitendfullscreen`，
  退出系统 player 后自动 `play()`（iOS 退出系统 player 默认会把 video 暂停）。
- **web `enterNativeFullscreen` 回归「浏览器原生全屏」语义**：`WebVideoBackend`
  此前把 `enterNativeFullscreen()` 实现成只翻一个 `NiumaPlayerView` 并不读取的
  内部 flag（等于 web 上调用它没有任何可见效果）；现在按 `PlayerBackend` 接口
  文档契约真正调用 `<video>.webkitEnterFullscreen()`（iOS Safari，进系统原生
  video player UI）/ `requestFullscreen()`（桌面 Safari / Chrome / Firefox /
  Android Chrome）。`exitNativeFullscreen()` 同步走 `webkitExitFullscreen` /
  `document.exitFullscreen()`。

## [0.1.0]

### BREAKING CHANGE: 重定位为 headless 播放内核

`niuma_player` 现在是**纯 headless 视频播放内核**——只导出
`NiumaPlayerController` + `NiumaPlayerView`（无样式渲染面）+ 全部纯 Dart 编排
逻辑（多线路 / auto-failover / retry policy / source middleware）+ 手势 / 全屏
的 **headless controller**（`NiumaGestureController` /
`NiumaFullscreenController`）+ cast 值类型。接入方监听
`controller.value`（`ValueNotifier<NiumaPlayerValue>`）自己拼 UI，或让 AI 按需
生成。

**所有 UI 全部出核，移入 git 历史**（曾经的 88 文件 niuma_ui 参考皮）：

- 一体化播放器壳 `NiumaPlayer` + 22 个原子控件 + 控件条（`NiumaControlBar` /
  `ControlBarConfig` / `ButtonOverride`）+ 全屏页 `NiumaFullscreenPage` + 三态
  反馈 UI + 主题 `NiumaPlayerTheme`。
- 弹幕引擎与 UI（`NiumaDanmakuController` / overlay / painter /
  settings panel / `DanmakuTrackAllocator`）。
- 广告调度（`NiumaAdSchedule` / `AdSchedulerOrchestrator` /
  `NiumaAdOverlay` + analytics 事件模型）。
- 缩略图取帧逻辑与 widget（`ThumbnailFrame` / `WebVttParser` /
  `ThumbnailResolver` / `NiumaThumbnailView` / `NiumaScrubPreview`）。
- 投屏协议实现与 UI（DLNA SSDP/SOAP、AirPlay RoutePicker、
  `NiumaCastRegistry` / `CastService` SPI、cast 按钮 / picker 面板）。
- 短视频整套（5 个 `NiumaShortVideo*` widget + `NiumaShortVideoTheme`）。
- 本地续播（resume position）。

需要参考实现：`git log --all -- 'example/lib/niuma_ui/**'` 定位 commit，
`git show <sha>:example/lib/niuma_ui/...` 取文件，或喂给 AI 当参考。

**核仍保留的 cast 值类型**：`CastDevice` / `CastSession` /
`CastConnectionState` / `CastEndReason`——`controller.connectCast(session)` /
`disconnectCast(...)` + `castSession` getter + `CastStarted` / `CastEnded`
事件依赖它们。具体协议由接入方实现 `CastService` 产出 `CastSession` 交给核。

### Removed (依赖瘦身)

- 三方依赖从重定位前的一大堆砍到 5 个。移除 `shared_preferences`
  （Android 设备记忆改走 Kotlin 侧 `SharedPreferences`，Dart 不再依赖）/
  `flutter_svg`（UI 出核）/ `http`（核不再 fetch VTT，缩略图取帧出核）。

### Changed (平台引擎)

- **Web** 后端从已废弃的 `dart:html` 迁到 `package:web` + `dart:js_interop`，
  **wasm-ready**——可随 `flutter build web --wasm` 编译。
- **Android** IJK 升级到 **FFmpeg 7.1.1** slim 重编（vendored `.aar`），
  ExoPlayer ↔ IJK 自动回退路径不变。

### Changed (example)

- `example/` 精简为 **100 行最小 demo**（`example/lib/main.dart`）：
  `NiumaPlayerController.dataSource` + `NiumaPlayerView` +
  `ValueListenableBuilder<NiumaPlayerValue>` 自拼 play/pause + 进度 + 时间。
  原 8 个 demo 页随参考皮移入 git 历史。

## [0.0.4] - 2026-05-25

### Fixed

- Vendored the custom-compiled `ijkplayer` `.aar` (13 MB) into git and the
  published package. It was previously git-ignored and fetched by a download
  script whose release URL no longer exists, so neither git nor pub.dev
  consumers received the binary and every Android build failed to resolve
  `tv.danmaku.ijk:ijkplayer`. The aar now ships under `android/localmaven/`,
  so Android builds work out of the box. Removed the dead download script.

## [0.0.3] - 2026-05-09

### Fixed

- Bumped `video_player` lower bound to `>=2.10.0`. The 2.8.0 lower bound
  failed pana downgrade analysis because `VideoPlayerController.playerId`
  (used by the iOS PiP bridge to map a Flutter texture id to its native
  AVPlayer instance) was only added in `video_player 2.10.0`.
- Declared web platform support in `pubspec.yaml` plugin manifest with a
  no-op `NiumaPlayerWebRegistrar` stub. Web behavior is implemented in pure
  Dart via conditional imports (`WebVideoBackend`); the stub exists only so
  Flutter's web plugin discovery can satisfy the platform declaration.
- Trimmed `CHANGELOG.md` to public 0.0.x entries only. The full
  internal-preview history (0.1.0 through 0.9.1) — which is mostly Chinese
  prose and was tripping pub.dev's non-ASCII content check — moved to
  [`doc/CHANGELOG_zh_internal_preview.md`](doc/CHANGELOG_zh_internal_preview.md).

## [0.0.2] - 2026-05-09

### Fixed

- Replaced `dart:js_util` (removed in Dart SDK 3.11) with `dart:js_interop` /
  `dart:js_interop_unsafe` in `web_video_backend.dart`. Fixes pub.dev pana
  static analysis failure that previously zeroed out platform support score.
- Shortened pubspec.yaml description to fit pub.dev 60-180 char limit.
- Added English-language summaries to `CHANGELOG.md`.

## [0.0.1] - 2026-05-09

**First public pub.dev release.** Version reset from internal-preview 0.9.x
to 0.0.1 as the inaugural public SDK version. Feature set equivalent to
internal 0.9.1, including:

- 3-tier backend abstraction (VideoPlayerBackend for iOS/Web, NativeBackend
  for Android) plus Android Try-Fail-Remember device memory.
- Orchestration layer (multi-line, retry policy, source middleware, resume
  position, WebVTT thumbnails, danmaku bucket loader, auto-failover).
- All-in-one `NiumaPlayer` widget plus 22 atomic control widgets and a
  configurable `NiumaControlBar`.
- Picture-in-Picture (iOS via reflection bridge, Android native).
- Cast: DLNA and AirPlay auto-registration via `NiumaCastRegistry`.
- Feedback UI builder slots: `loadingBuilder`, `errorBuilder`, `endedBuilder`.
- Short-video player with TikTok-style gestures, scrubber, speed control.
- Web fullscreen, cross-backend swap coordination, iOS Safari quirk fixes.

For the detailed history of internal-preview iterations leading up to this
release (0.1.x through 0.9.1), see
[`doc/CHANGELOG_zh_internal_preview.md`](doc/CHANGELOG_zh_internal_preview.md)
(Chinese).
