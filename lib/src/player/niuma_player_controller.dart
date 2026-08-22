import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:niuma_player/src/capabilities/niuma_capabilities.dart';
import 'package:niuma_player/src/data/_pip_event_bus.dart'
    show adoptOrphanedPipSession;
import 'package:niuma_player/src/data/default_backend_factory.dart';
import 'package:niuma_player/src/data/default_platform_bridge.dart';
import 'package:niuma_player/src/domain/backend_factory.dart';
import 'package:niuma_player/src/domain/data_source.dart';
import 'package:niuma_player/src/domain/platform_bridge.dart';
import 'package:niuma_player/src/domain/player_backend.dart';
import 'package:niuma_player/src/domain/player_state.dart';
import 'package:niuma_player/src/orchestration/multi_source.dart';
import 'package:niuma_player/src/orchestration/retry_policy.dart';
import 'package:niuma_player/src/orchestration/source_middleware.dart';
import 'package:niuma_player/src/player/niuma_player_options.dart';
import 'package:niuma_player/src/player/pip_lifecycle_observer.dart';

/// 进程级「正在播放且要求亮屏的 controller 数」，归并多实例，见 `_syncWakelock`。
int _wakelockHolderCount = 0;

/// 生命周期取消（load 换代 / dispose）——不是媒体错误：不重试、不触发
/// IJK 兜底、不包装进 [EngineFallbackFailure]。
class _LifecycleCanceled extends StateError {
  _LifecycleCanceled() : super('NiumaPlayerController superseded or disposed');
}

/// 播放内核的单一公共门面：选 backend（三端主路径官方 video_player，web 走
/// 自家 WebVideoBackend，Android 失败当次会话回退 IJK 软解）、多线路编排、
/// PiP。
///
/// 注意：[events] 流和 value 监听器都是**同步** fire——build 期间直接
/// setState 会撞 framework locked，建议用 `ValueListenableBuilder` 消费。
class NiumaPlayerController extends ValueNotifier<NiumaPlayerValue> {
  /// 构造并注册 PiP lifecycle observer。
  NiumaPlayerController(
    NiumaMediaSource source, {
    this.middlewares = const [],
    this.retryPolicy = const RetryPolicy.smart(),
    NiumaPlayerOptions? options,
    PlatformBridge? platform,
    BackendFactory? backendFactory,
  })  : _source = source,
        options = options ?? const NiumaPlayerOptions(),
        _platform = platform ?? const DefaultPlatformBridge(),
        _backendFactory = backendFactory ?? const DefaultBackendFactory(),
        super(NiumaPlayerValue.uninitialized()) {
    // observer 永远注册：autoEnterPip 只控制 shouldEnter()，
    // onResume 兜底重置 stale PiP state 始终生效。
    _pipObserver = PipLifecycleObserver(
      shouldEnter: () =>
          _autoEnterPip &&
          value.phase == PlayerPhase.playing &&
          !value.isInPictureInPicture,
      enter: enterPictureInPicture,
      onResume: _resetStalePipStateOnResume,
    );
    WidgetsBinding.instance.addObserver(_pipObserver!);
  }

  /// 单 source 便捷 factory：把 [ds] 包成 [NiumaMediaSource.single]。
  factory NiumaPlayerController.dataSource(
    NiumaDataSource ds, {
    String? thumbnailVtt,
    NiumaPlayerOptions? options,
    PlatformBridge? platform,
    BackendFactory? backendFactory,
  }) =>
      NiumaPlayerController(
        NiumaMediaSource.single(ds, thumbnailVtt: thumbnailVtt),
        options: options,
        platform: platform,
        backendFactory: backendFactory,
      );

  /// 当前播放线路集的 [NiumaMediaSource]；[load] 原地换源后返回新源。
  NiumaMediaSource get source => _source;
  NiumaMediaSource _source;

  /// backend 起飞前作用于数据源的 middleware 流水线；每次 initialize /
  /// switchLine / 重试都会跑，保证 headers / signed URL 新鲜。
  final List<SourceMiddleware> middlewares;

  /// [initialize] 抛可恢复错误时的重试策略。
  /// 注意重试在 Android IJK 兜底层之内：最坏 `(maxAttempts+1) × 2` 次
  /// 初始化（默认值下约 254s 才暴露失败，autoFailover 多线路再乘线路数），
  /// 收紧上限调低 maxAttempts / initTimeout。
  final RetryPolicy retryPolicy;

  /// 向后兼容访问器：当前激活线路（[activeLineId]）的数据源——failover /
  /// [switchLine] 之后跟着实际在播的线路走，不是默认线路。
  NiumaDataSource get dataSource =>
      source.lineById(activeLineId)?.source ?? source.currentLine.source;

  /// 行为选项。
  final NiumaPlayerOptions options;

  final PlatformBridge _platform;
  final BackendFactory _backendFactory;

  PlayerBackend? _backend;
  StreamSubscription<NiumaPlayerValue>? _valueSub;
  StreamSubscription<NiumaPlayerEvent>? _eventSub;
  Completer<void>? _initCompleter;
  bool _disposed = false;

  /// 代际号：每个破坏性操作（[load] / [switchLine] / [dispose]）开始时递增，
  /// 语义是"最新的操作压倒一切在途操作"。在途链在**每个 await 之后**都用
  /// [_ensureCurrent] 复查——await 期间什么都可能发生——发现代际不符即抛
  /// [_LifecycleCanceled] 自行终止，并销毁自己刚造的 backend，防止旧链复活
  /// 旧源 / 拆掉新链的订阅 / 泄漏平台播放器。
  int _epoch = 0;

  /// 代际守卫：[epoch] 已被更晚的操作压倒或已 dispose 时抛 [_LifecycleCanceled]。
  void _ensureCurrent(int epoch) {
    if (_disposed || epoch != _epoch) throw _LifecycleCanceled();
  }

  /// 当前**实际在播**线路的 id。初始值 = `source.defaultLineId`；首播
  /// failover 落到备线路、或 [switchLine] 成功后更新——只在拉起成功后写，
  /// 切换进行中仍指向原线路。
  String get activeLineId => _activeLineId ?? source.defaultLineId;

  String? _activeLineId;

  /// 有候选拉起在途的代际集合：[switchLine] 与 [initialize] / [load] 的候选
  /// 遍历（多线路 failover、IJK 兜底）各自登记发起时的 epoch，结束（含失败）
  /// 时注销。期间候选 backend 的 `phase=error` 不写进 [value]——候选失败不
  /// 等于播放失败：切换失败会回滚（由 [LineSwitchFailed] 通知），首播会试
  /// 下一条线路 / IJK；只有最终失败才显式把 error 落到 [value]（[initialize]
  /// 的 onError、[switchLine] 的无法回滚路径）。期间 [value] 的变化也不更新
  /// 稳定快照。
  ///
  /// 用 epoch 集合而非全局计数：全局计数在旧链卡死在 middleware / 平台
  /// Future 里时永远不归零，会把**新链** backend 的真实 error 一并吞掉、
  /// 稳定快照也永久冻结。error 抑制与快照冻结只认"当前代际是否有候选在途"
  /// （[_candidateBringUpInFlight]），卡死的旧链登记的过期 epoch 不再影响新链。
  final Set<int> _candidateEpochs = <int>{};

  /// 当前代际是否有候选拉起在途。见 [_candidateEpochs]。
  bool get _candidateBringUpInFlight => _candidateEpochs.contains(_epoch);

  /// 最近一次**稳定**的播放位置 / 播放意图（含 buffering）——只在没有候选
  /// 拉起进行中时随 [value] 更新。[switchLine] 的"切换前快照"取自这里，而不是当下的 [value]：并发
  /// 切换时当下 value 可能已是候选 backend 的半成品（0:00、未播放）。
  Duration _stablePosition = Duration.zero;
  bool _stablePlaying = false;

  /// Android：本会话内 IJK 已成功接管过（vp 起不来）。之后的 [switchLine] /
  /// 回滚直接用 IJK 拉目标线路，不再让 vp 失败一次。同一媒体的各线路编码
  /// 通常一致，这个记忆才成立；[load] 换媒体时清掉，新媒体重新给 vp 机会。
  bool _sessionPrefersNative = false;

  final StreamController<NiumaPlayerEvent> _eventController =
      StreamController<NiumaPlayerEvent>.broadcast(sync: true);

  /// [BackendSelected] / [FallbackTriggered] 等事件的 broadcast stream。
  /// 在 [initialize] 之前订阅是安全的。
  Stream<NiumaPlayerEvent> get events => _eventController.stream;

  /// 当前激活的 Dart 侧 backend 类型；[initialize] 完成前的值无意义，
  /// 调用方应等 `BackendSelected`。
  PlayerBackendKind get activeBackend =>
      _backend?.kind ?? PlayerBackendKind.videoPlayer;

  /// 当前激活 backend 的 texture id；video_player 自管 widget，返回 null。
  int? get textureId => _backend?.textureId;

  /// 底层 backend 实例，供 [NiumaPlayerView] 选择渲染 widget。
  PlayerBackend? get backend => _backend;

  /// 选平台 backend 并初始化。多次调用安全：成功后复用同一 future，
  /// 失败后清缓存让"重试"能完整重跑。
  /// 错误只经 future 传播（不 rethrow，避免 unhandled）。
  Future<void> initialize() {
    if (_disposed) {
      return Future<void>.error(
        StateError('NiumaPlayerController has been disposed'),
      );
    }
    if (_initCompleter != null) return _initCompleter!.future;
    final completer = Completer<void>();
    _initCompleter = completer;
    // 完成前复查用：拉起期间被压倒的链自己会以 _LifecycleCanceled 结束，
    // 这里防的是"拉起成功之后、complete 之前"的窗口——dispose / switchLine /
    // load 在此窗口压倒时，本次 initialize 不得宣布成功（epoch 复查同时
    // 覆盖三者；单查 _initCompleter 身份盖不住 switchLine 和 dispose）。
    final epoch = _epoch;
    _runInitialize().then(
      (_) {
        // PiP 能力查询是 best-effort，**不阻塞 initialize 完成**：查询自带
        // backend 身份复查，迟到结果安全丢弃。此前查询挡在 complete 之前，
        // dispose / switchLine 打断查询后旧 initialize 反而完成为成功。
        unawaited(_queryAndUpdatePipSupport());
        if (completer.isCompleted) return;
        if (_disposed || epoch != _epoch) {
          completer.completeError(_LifecycleCanceled());
          return;
        }
        completer.complete();
      },
      onError: (Object e, StackTrace st) {
        final isCurrent = _initCompleter == completer;
        if (isCurrent) _initCompleter = null;
        // 失败必须同步落到 value（phase=error）：否则调用方没 catch future 时
        // value 驱动的 UI 永远等不到 error 态，用户只看到无限转圈。
        // 已被 load() 取代的旧链不写——避免覆盖新链的正常状态；生命周期
        // 取消也不写——它不是媒体错误，新链马上会接管 value。
        if (isCurrent && !_disposed && e is! _LifecycleCanceled) {
          value = value.copyWith(
            phase: PlayerPhase.error,
            error: PlayerError(
              category: _categorize(e),
              message: e.toString(),
            ),
          );
        }
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    );
    return completer.future;
  }

  /// 原地换到新源 [newSource]，尽量复用当前 backend。
  /// web 上复用同一 `<video>` 换 src 可保住 iOS Safari 的有声播放激活；
  /// backend 不支持换源（或初始化还在途）时自动 dispose + 重建。
  ///
  /// 并发语义：**最后一次调用说了算**。在途的 [initialize] / [load] /
  /// [switchLine] 会被这次调用压倒，它们的 future 以 [StateError]
  /// （"superseded or disposed"）结束，既不写 `value.error` 也不触发回退。
  /// feed 快滑连续 `load()` 时只需关心最后一次的结果。
  Future<void> load(NiumaMediaSource newSource) async {
    if (_disposed) {
      throw StateError('NiumaPlayerController has been disposed');
    }
    final epoch = ++_epoch; // 压倒一切在途的 initialize / load / switchLine
    _source = newSource;
    _activeLineId = newSource.defaultLineId;
    _sessionPrefersNative = false; // 新媒体重新给 vp 机会
    final backend = _backend;
    // 初始化还在途的 backend 不能原地换源（半初始化状态下 load 的结果
    // 不可预期），这种情况走重建。
    final initInFlight =
        _initCompleter != null && !_initCompleter!.isCompleted;
    if (backend != null && backend.supportsSourceSwap && !initInFlight) {
      // middleware 计入 initTimeout 预算：卡死的 middleware 不能让 load 的
      // future 永远悬着。
      final resolved =
          await runSourceMiddlewares(newSource.currentLine.source, middlewares)
              .timeout(options.initTimeout);
      _ensureCurrent(epoch); // 过期的 load 不得把旧源喂给 backend 覆盖新源
      await backend.load(resolved).timeout(options.initTimeout);
      // backend.load 的 await 期间被更晚的 load 压倒：本次调用必须按契约以
      // StateError 结束，不能明明输了还宣布成功（backend 最终会被压倒者纠正）。
      _ensureCurrent(epoch);
    } else {
      // 先作废旧 future：它已被代际压倒，其结果（含取消）不再写 value。
      _initCompleter = null;
      await _disposeCurrentBackend();
      _ensureCurrent(epoch); // dispose 期间又来了一次 load：让它去起链
      await initialize();
    }
  }

  /// 把异常分类成 [PlayerErrorCategory]；带 `.category` getter 的对象
  /// duck-typing 分类，测试类无需在生产代码可见。
  PlayerErrorCategory _categorize(Object e) {
    if (e is EngineFallbackFailure) return _categorize(e.fallback);
    if (e is TimeoutException) return PlayerErrorCategory.network;
    try {
      final dynamic d = e;
      final c = d.category;
      if (c is PlayerErrorCategory) return c;
    } catch (_) {
      // 不是带分类的异常
    }
    return PlayerErrorCategory.unknown;
  }

  /// 按 [retryPolicy] 带重试地运行 [bringUp]；不可重试时 rethrow 交给调用方。
  Future<T> _withRetry<T>(Future<T> Function() bringUp) async {
    var attempt = 1;
    while (true) {
      try {
        return await bringUp();
      } on _LifecycleCanceled {
        rethrow; // 被压倒 / 已 dispose：无论什么策略都不重试
      } catch (e) {
        final category = _categorize(e);
        if (!retryPolicy.shouldRetry(category, attempt: attempt)) rethrow;
        await Future<void>.delayed(retryPolicy.delayFor(attempt));
        attempt++;
      }
    }
  }

  Future<void> _runInitialize() async {
    // 整条 init 链（含 IJK 兜底）共用开跑时的代际：中途被 load 压倒后，
    // 兜底也不能再为旧源拉起 IJK。
    final epoch = _epoch;
    _candidateEpochs.add(epoch);
    try {
      // 三端主路径统一走官方 video_player（iOS AVPlayer / Android ExoPlayer /
      // Web <video>，由官方维护、可随意升级）。Android 额外带 IJK 软解兜底。
      if (_platform.isIOS || _platform.isWeb) {
        await _initVideoPlayer(epoch);
        return;
      }

      // Android。
      if (options.forceIjkOnAndroid) {
        await _initNative(source.currentLine.source, epoch);
        return;
      }
      try {
        await _initVideoPlayer(epoch);
      } on _LifecycleCanceled {
        rethrow; // 快滑换源 / 页面销毁的取消，不是媒体失败。
      } catch (vpError) {
        // 被压倒后才浮出的失败属于旧链自身（多半是压倒者销毁了它的
        // backend）：不 dispose（会误杀新链刚挂上的 backend）、不兜底 IJK。
        _ensureCurrent(epoch);
        // video_player 失败 → 当次会话内用 IJK 软解兜底重试（不落盘）。
        _emit(FallbackTriggered(
          FallbackReason.error,
          errorCode: vpError.toString(),
        ));
        await _disposeCurrentBackend();
        // IJK 兜底播的是默认线路。
        await _initNativeAfterVpFailure(source.currentLine.source, epoch, vpError);
        _activeLineId = source.defaultLineId;
      }
    } finally {
      _candidateEpochs.remove(epoch);
    }
  }

  /// vp 失败后的 IJK 兜底：IJK 也失败时合成双段错误一起抛，避免 IJK 的错
  /// 掩盖 vp 的根因；成功则记住本会话此后切线直接走 IJK。
  Future<void> _initNativeAfterVpFailure(
    NiumaDataSource raw,
    int epoch,
    Object vpError,
  ) async {
    try {
      await _initNative(raw, epoch);
    } on _LifecycleCanceled {
      rethrow;
    } catch (ijkError, st) {
      Error.throwWithStackTrace(
        EngineFallbackFailure(primary: vpError, fallback: ijkError),
        st,
      );
    }
    _sessionPrefersNative = true;
  }

  /// 单次拉起序列：dispose 旧 backend → 重跑 middleware（URL/headers 新鲜）
  /// → 建新 backend → attach → initialize（带 wall-clock 超时）。
  /// [_initVideoPlayer] / [_initNative] / [_doSwitchTo] 的每次 attempt 共用。
  ///
  /// 每个 await 之后都复查 [epoch]：被压倒的链在造 backend 之前就退出
  /// （无可泄漏）；造出来之后被压倒的，压倒者开跑时已把它当"当前 backend"
  /// 销毁（见 [_disposeCurrentBackend]），这里只需停止继续操作。
  Future<void> _bringUp(
    int epoch,
    NiumaDataSource raw,
    PlayerBackend Function(NiumaDataSource resolved) create,
  ) async {
    _ensureCurrent(epoch);
    await _disposeCurrentBackend();
    _ensureCurrent(epoch);
    // middleware 计入 initTimeout 预算：卡死的 middleware 会让本链的
    // finally 永不执行（候选登记悬着、调用方 future 悬着），必须有界。
    final resolved =
        await runSourceMiddlewares(raw, middlewares).timeout(options.initTimeout);
    _ensureCurrent(epoch);
    final backend = create(resolved);
    await _attachBackend(backend, epoch);
    try {
      await backend.initialize().timeout(options.initTimeout);
    } catch (e) {
      // Future.timeout 不会取消底层初始化：失败/超时的候选若继续挂在
      // controller 上，平台侧还在后台加载，迟到的 ready 会把终局失败写入
      // 的 error 覆盖掉。立即摘订阅并销毁——仅当它还是当前 backend
      // （被压倒后新链可能已挂上自己的，那不归这里管）。
      if (identical(_backend, backend)) {
        try {
          await _disposeCurrentBackend();
        } catch (_) {
          // best-effort：清理失败不得替换原始初始化错误——那会改变
          // _categorize 的结果，进而带偏 retry / IJK 兜底 / failover 决策。
        }
      }
      rethrow;
    }
    _ensureCurrent(epoch);
    // PiP 中换 backend（load 换源 / switchLine / IJK 兜底）：系统会话还在
    // 继续，旧 backend 的归属已成 tombstone，新 backend 收养它，否则遥控
    // 与 pipStopped 全被丢弃。不在 PiP 中则是空操作。
    if (value.isInPictureInPicture) {
      adoptOrphanedPipSession(backend);
    }
  }

  PlayerBackend _createVideoPlayer(
    NiumaDataSource resolved,
    bool useAndroidPlatformView,
  ) =>
      _backendFactory.createVideoPlayer(
        resolved,
        useAndroidPlatformView: useAndroidPlatformView,
      );

  /// vp 主路径实际是否用 platformView。Android 9（API 28）上 vp 的平台视图
  /// 走 `setupSurfaceWithCallback`：`surfaceCreated` 里 `seekTo(1)`、
  /// `surfaceDestroyed` 里无条件 `setVideoSurface(null)`（不判断当前绑的是
  /// 不是自己）——全屏 ↔ inline 交接必然黑屏 + 跳回开头，故降级 textureView。
  /// IJK 兜底路径走自家 `PlayerSession.surfaceStack`，不受此限。
  Future<bool> _vpUsePlatformView() async =>
      options.useAndroidPlatformView &&
      await NiumaCapabilities.androidSdkInt() != 28;

  /// video_player 主路径初始化：先试 defaultLine；autoFailover 开且多线路时
  /// 失败后把其余线路按 priority 升序逐条再试；全失败抛最后一条错误。
  Future<void> _initVideoPlayer(int epoch) async {
    final platformView = await _vpUsePlatformView();
    final defaultLine = source.currentLine;
    final candidates = <MediaLine>[defaultLine];
    if (options.autoFailoverOnInitialError && source.lines.length > 1) {
      candidates.addAll(
        source.lines.where((l) => l.id != defaultLine.id).toList()
          ..sort((a, b) => a.priority.compareTo(b.priority)),
      );
    }

    Object? lastError;
    StackTrace? lastStack;
    for (var i = 0; i < candidates.length; i++) {
      final line = candidates[i];
      try {
        await _withRetry(() => _bringUp(
            epoch, line.source, (r) => _createVideoPlayer(r, platformView)));
        _activeLineId = line.id;
        _emit(const BackendSelected(
          PlayerBackendKind.videoPlayer,
          fromMemory: false,
        ));
        return;
      } on _LifecycleCanceled {
        rethrow; // 被压倒不是线路失败：不试下一条、不发 LineSwitchFailed
      } catch (e, st) {
        // 被压倒后才浮出的失败属于旧链自身：不再发事件、不再试下一条线路。
        _ensureCurrent(epoch);
        if (e is TimeoutException) {
          // 与 IJK 路径一致：wall-clock 超时发独立信号，便于排障区分。
          _emit(const FallbackTriggered(FallbackReason.timeout));
        }
        lastError = e;
        lastStack = st;
        if (candidates.length > 1) {
          _emit(LineSwitchFailed(toId: line.id, error: e));
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
  }

  /// 单线路的 video_player 拉起（带重试；每次重试整链重建——复用同一个
  /// 失败 backend 反复 initialize 是打不活的）。[switchLine] / 回滚用。
  Future<void> _bringUpVideoPlayer(NiumaDataSource raw, int epoch) async {
    final platformView = await _vpUsePlatformView();
    await _withRetry(() =>
        _bringUp(epoch, raw, (r) => _createVideoPlayer(r, platformView)));
  }

  /// IJK 软解兜底初始化。[raw] 为目标线路的原始数据源——middleware 在每次
  /// attempt 内重跑。
  Future<void> _initNative(NiumaDataSource raw, int epoch) async {
    try {
      await _withRetry(() => _bringUp(
            epoch,
            raw,
            (resolved) => _backendFactory.createNative(
              resolved,
              useAndroidPlatformView: options.useAndroidPlatformView,
            ),
          ));
    } on TimeoutException {
      // timeout 转成 FallbackTriggered 语义再 rethrow。
      _emit(const FallbackTriggered(FallbackReason.timeout));
      rethrow;
    }
    _emit(BackendSelected(
      PlayerBackendKind.native,
      fromMemory: false,
    ));
  }

  /// 上一次推到 native PiP 的 isPlaying——只在 playing↔paused 边沿同步，
  /// 避免每次 position 更新都发 method channel。
  bool? _lastPipActionsIsPlaying;

  bool _holdsWakelock = false;

  /// playing 边沿同步屏幕常亮；进程级计数归并多实例，
  /// 避免「A 在播、B 暂停时把 A 的亮屏关掉」。
  void _syncWakelock(bool playing) {
    if (!options.manageScreenWakelock) return;
    if (playing == _holdsWakelock) return;
    _holdsWakelock = playing;
    if (playing) {
      _wakelockHolderCount++;
      if (_wakelockHolderCount == 1) {
        unawaited(_platform.setKeepScreenOn(true));
      }
    } else {
      _wakelockHolderCount--;
      if (_wakelockHolderCount == 0) {
        unawaited(_platform.setKeepScreenOn(false));
      }
    }
  }

  @override
  set value(NiumaPlayerValue newValue) {
    final wasPlaying = value.isPlaying;
    final wasInPip = value.isInPictureInPicture;
    super.value = newValue;
    if (!_candidateBringUpInFlight) {
      _stablePosition = newValue.position;
      // 用播放意图而非"正在出帧"：buffering 也是用户想播，切换 / 回滚后
      // 要续播，不能停在暂停态等用户再点一次。
      _stablePlaying = newValue.effectivelyPlaying;
    }
    final inPip = newValue.isInPictureInPicture;
    final isPlaying = newValue.isPlaying;
    if (isPlaying != wasPlaying) _syncWakelock(isPlaying);
    if (!wasInPip && inPip) {
      // 刚乐观进 PiP：只 init cache 不 push——native 马上会设完整 params，
      // 双重 setPictureInPictureParams 会让 OS PiP controls 失效。
      _lastPipActionsIsPlaying = isPlaying;
    } else if (inPip &&
        (isPlaying != wasPlaying || _lastPipActionsIsPlaying != isPlaying)) {
      _lastPipActionsIsPlaying = isPlaying;
      unawaited(
        _backend?.updatePictureInPictureActions(isPlaying: isPlaying),
      );
    } else if (!inPip && wasInPip) {
      _lastPipActionsIsPlaying = null;
    }
  }

  Future<void> _attachBackend(PlayerBackend backend, int epoch) async {
    await _detachBackend();
    // detach 的 await 之后才能赋值——这个空隙里若被 load / switchLine /
    // dispose 压倒，刚造的 backend 必须就地销毁，否则泄漏真实平台播放器，
    // 还会把压倒者的 backend 顶掉。
    if (_disposed || epoch != _epoch) {
      await backend.dispose();
      throw _LifecycleCanceled();
    }
    _backend = backend;
    _valueSub = backend.valueStream.listen((v) {
      if (_disposed) return;
      // 切换进行中，候选 backend 的 error 不进 value：切换失败要么回滚成功
      // （value 自然恢复），要么在 switchLine 的失败路径里显式落 error。
      // 否则上层会把"候选线路没起来"当成"正在播的线路挂了"去做自动容灾。
      // 只认当前代际的候选（见 _candidateEpochs）：卡死的旧链不得吞新链的 error。
      if (_candidateBringUpInFlight && v.phase == PlayerPhase.error) return;
      // backend 不知道 platform-level PiP 状态，保留 controller 自己维护的
      // PiP state，否则会被 backend 推的默认 false 覆盖。
      value = v.copyWith(isInPictureInPicture: value.isInPictureInPicture);
    });
    _eventSub = backend.eventStream.listen((e) {
      if (_disposed) return;
      // FallbackTriggered 由 controller 自己发权威版本，丢掉 backend 级的避免重复。
      if (e is FallbackTriggered) return;
      if (e is PipStartFailed) {
        // 乐观置位回滚；没进过 PiP，不走"退出 PiP 默认暂停"。
        if (value.isInPictureInPicture) {
          value = value.copyWith(isInPictureInPicture: false);
        }
        if (!_eventController.isClosed) _eventController.add(e);
        return;
      }
      if (e is PipModeChanged) {
        // 本实例从未进过 PiP 的"退出"事件不属于它（PiP bus 无 owner 时的
        // 广播兜底 / 宿主绕过 SDK 自行进的 PiP）：不暂停、不翻状态、不透传。
        // 否则多实例场景里别的播放器退 PiP 会把正在播的实例一并暂停。
        if (!e.isInPip && !value.isInPictureInPicture) return;
        value = value.copyWith(isInPictureInPicture: e.isInPip);
        // 退出 PiP 默认暂停（与 B 站 / YouTube mobile 一致）；业务想续播
        // 自己拦 PipModeChanged(isInPip:false) 调 play()。
        if (!e.isInPip && value.phase == PlayerPhase.playing) {
          unawaited(pause());
        }
        if (!_eventController.isClosed) _eventController.add(e);
        return;
      }
      if (e is PipRemoteAction) {
        // PiP 窗的遥控只属于正在 PiP 中的实例：bus 无 owner 的广播兜底 /
        // owner 已 dispose 的迟到事件不得让所有实例一起播放/暂停。
        if (!value.isInPictureInPicture) return;
        if (e.action == 'playPauseToggle') {
          if (value.phase == PlayerPhase.playing) {
            unawaited(pause());
          } else {
            unawaited(play());
          }
        }
        if (!_eventController.isClosed) _eventController.add(e);
        return;
      }
      if (!_eventController.isClosed) {
        _eventController.add(e);
      }
    });
  }

  Future<void> _detachBackend() async {
    // 先同步摘字段再 await cancel：cancel 的 await 期间新链可能已经挂上
    // 自己的订阅，旧链醒来后只允许动自己快照到的对象，不得再碰共享字段
    // （否则会清掉甚至 cancel 掉新链的订阅）。
    final valueSub = _valueSub;
    final eventSub = _eventSub;
    _valueSub = null;
    _eventSub = null;
    await valueSub?.cancel();
    await eventSub?.cancel();
  }

  Future<void> _disposeCurrentBackend() async {
    // 同步摘 _backend，理由同 _detachBackend：await 之后共享字段可能已属于新链。
    final old = _backend;
    _backend = null;
    await _detachBackend();
    await old?.dispose();
  }

  void _emit(NiumaPlayerEvent event) {
    if (_eventController.isClosed) return;
    _eventController.add(event);
  }

  Future<void> play() async {
    await _backend?.play();
    // PiP RemoteAction 同步只走 value setter；这里再主动 push 会双调
    // setPictureInPictureParams，导致 OS PiP UI 反复重置闪掉。
  }

  Future<void> pause() async {
    await _backend?.pause();
  }

  Future<void> seekTo(Duration position) async {
    await _backend?.seekTo(position);
  }

  /// Web-only：让底层 `<video>` 进浏览器原生 fullscreen（iOS Safari 走
  /// `webkitEnterFullscreen` 进系统 player，Flutter 控件不跟随）。io 平台返 false。
  Future<bool> enterNativeFullscreen() async {
    return await _backend?.enterNativeFullscreen() ?? false;
  }

  /// Web-only：退出浏览器原生 fullscreen。
  Future<bool> exitNativeFullscreen() async {
    return await _backend?.exitNativeFullscreen() ?? false;
  }

  Future<void> setPlaybackSpeed(double speed) async {
    value = value.copyWith(playbackSpeed: speed);
    await _backend?.setSpeed(speed);
  }

  Future<void> setVolume(double volume) async => _backend?.setVolume(volume);
  Future<void> setLooping(bool looping) async => _backend?.setLooping(looping);

  /// Web-only：开 / 关底层 `<video>` 的浏览器原生控件（iOS Safari 上自定义
  /// 控件点不动时的兜底）。非 web 平台为空操作。
  Future<void> setWebNativeControls(bool show) async =>
      _backend?.setWebNativeControls(show);

  /// 切换到 [lineId] 线路：重建 backend 后 seek 回原位置并恢复播放状态。
  /// 成功依次发 [LineSwitching] / [LineSwitched]，失败发 [LineSwitchFailed]
  /// 并 rethrow；未知 id 抛 [ArgumentError]，同线路静默 no-op。
  ///
  /// 并发语义：**最后一次调用说了算**。切换进行中再次 [switchLine] /
  /// [load]，先前那次被压倒——其 future 以 [StateError]（"superseded or
  /// disposed"）结束，不回滚、不发 [LineSwitchFailed]；dispose 打断则静默返回。
  Future<void> switchLine(String lineId) async {
    if (_disposed) return;
    final target = source.lineById(lineId);
    if (target == null) {
      throw ArgumentError.value(lineId, 'lineId', 'unknown line id');
    }
    final fromId = _activeLineId ?? source.defaultLineId;
    if (fromId == lineId) return;

    // 压倒在途的 initialize / load / 上一次 switchLine：并发切线"最后
    // 一次说了算"，被压倒的那次以 StateError 结束，不回滚、不上报失败。
    final epoch = ++_epoch;
    _emit(LineSwitching(fromId: fromId, toId: lineId));

    // 切换前快照取自稳定状态（不是当下 value——并发切换时它可能是候选的
    // 半成品），回滚复用同一份，保证"切失败 = 什么都没发生"。
    final savedPos = _stablePosition;
    final wasPlaying = _stablePlaying;

    _candidateEpochs.add(epoch);
    try {
      await _doSwitchTo(lineId, epoch,
          savedPos: savedPos, wasPlaying: wasPlaying);
      _emit(LineSwitched(lineId));
    } on _LifecycleCanceled {
      if (_disposed) return; // 页面销毁：静默
      rethrow; // 被更晚的操作压倒：调用方得知这次没切成
    } catch (e) {
      if (_disposed) return;
      // 被压倒后才浮出的失败属于旧链自身：不回滚、不写 value.error、
      // 不发 LineSwitchFailed，按契约以 StateError（superseded）结束。
      _ensureCurrent(epoch);
      // rollbackOnSwitchFailure：切换失败静默回滚到原线路。
      if (options.rollbackOnSwitchFailure) {
        try {
          await _doSwitchTo(fromId, epoch,
              savedPos: savedPos, wasPlaying: wasPlaying);
          // 回滚成功：发 LineSwitchFailed 供上报，但不 rethrow。
          _emit(LineSwitchFailed(toId: lineId, error: e));
          return;
        } on _LifecycleCanceled {
          if (_disposed) return;
          rethrow;
        } catch (_) {
          // 回滚也失败——掉到原始错误处理。
        }
      }
      // 没有可回滚的状态了：候选的 error 在切换期间被吞掉，这里必须显式落
      // 到 value，否则 UI 还以为原线路在播。
      value = value.copyWith(
        phase: PlayerPhase.error,
        error: PlayerError(category: _categorize(e), message: e.toString()),
      );
      _emit(LineSwitchFailed(toId: lineId, error: e));
      rethrow;
    } finally {
      _candidateEpochs.remove(epoch);
    }
  }

  /// [switchLine] 与 rollback 共用：拉起目标线路（重建式重试）→ seek + 续播。
  /// [epoch] 是发起这次切换时取得的代际，整段共用。
  Future<void> _doSwitchTo(
    String lineId,
    int epoch, {
    required Duration savedPos,
    required bool wasPlaying,
  }) async {
    final target = source.lineById(lineId);
    if (target == null) {
      throw ArgumentError.value(lineId, 'lineId', 'unknown line id');
    }
    _ensureCurrent(epoch);

    if (_platform.isIOS || _platform.isWeb) {
      await _bringUpVideoPlayer(target.source, epoch);
    } else if (options.forceIjkOnAndroid || _sessionPrefersNative) {
      // 显式强制 IJK，或本会话 vp 已证明起不来——直接用 IJK 拉目标线路。
      await _initNative(target.source, epoch);
    } else {
      // 与首播同一套规则：vp 失败 → 当次会话内 IJK 兜底，而不是让切线失败。
      try {
        await _bringUpVideoPlayer(target.source, epoch);
      } on _LifecycleCanceled {
        rethrow;
      } catch (vpError) {
        // 被压倒后才浮出的失败属于旧链自身：不 dispose（会误杀新链刚挂上
        // 的 backend）、不兜底 IJK。
        _ensureCurrent(epoch);
        _emit(FallbackTriggered(
          FallbackReason.error,
          errorCode: vpError.toString(),
        ));
        await _disposeCurrentBackend();
        await _initNativeAfterVpFailure(target.source, epoch, vpError);
      }
    }
    // 拉起成功才算切到：切换进行中 activeLineId 仍指向原线路。
    _activeLineId = lineId;

    // _bringUp 成功返回即保证代际仍然有效、_backend 就是刚拉起的那个。
    if (savedPos > Duration.zero) {
      await _backend!.seekTo(savedPos);
      _ensureCurrent(epoch);
    }
    if (wasPlaying) {
      await _backend!.play();
      // play 的 await 期间被压倒：这次切换不得再宣布 LineSwitched。
      _ensureCurrent(epoch);
    }
  }


  // ────────────── PiP（画中画） ──────────────

  bool _autoEnterPip = false;
  PipLifecycleObserver? _pipObserver;

  /// app 切后台时是否自动进 PiP（默认 false）。
  /// 触发条件：app 进 inactive + phase=playing + 不在 PiP 中。
  bool get autoEnterPictureInPictureOnBackground => _autoEnterPip;

  /// 设置 [autoEnterPictureInPictureOnBackground]。只翻 flag，
  /// observer 常驻、由 `shouldEnter` 闭包读它决定是否触发。
  set autoEnterPictureInPictureOnBackground(bool nextValue) {
    if (_autoEnterPip == nextValue) return;
    _autoEnterPip = nextValue;
  }

  /// app 回前台时兜底翻回 stale 的 isInPictureInPicture——部分设备退出 PiP
  /// 时不可靠触发 native 回调。"在前台 = 不在 PiP" 是定义保证。
  void _resetStalePipStateOnResume() {
    if (_disposed) return;
    if (value.isInPictureInPicture) {
      value = value.copyWith(isInPictureInPicture: false);
    }
  }

  /// 进入 PiP。返回 true 表示已发起请求（系统层仍可能拒绝）；
  /// 不支持 / 未 initialize / 已在 PiP → 返回 false 不抛。
  /// 先乐观置 isInPictureInPicture=true 让 UI 提前藏控件（Android 先 resize
  /// 后回调的时序会让控件在迷你窗渲染一帧溢出），失败回滚。
  Future<bool> enterPictureInPicture() async {
    final v = value;
    if (!v.initialized) return false;
    if (v.isInPictureInPicture) return false;
    final backend = _backend;
    if (backend == null) return false;
    value = v.copyWith(isInPictureInPicture: true);
    final aspect = _aspectInts(v.size);
    try {
      final ok = await backend.enterPictureInPicture(
        aspectNum: aspect.$1,
        aspectDen: aspect.$2,
        unsafeAutoBackground: options.unsafePipAutoBackgroundOnEnter,
      );
      if (!ok) {
        value = value.copyWith(isInPictureInPicture: false);
      }
      return ok;
    } catch (_) {
      value = value.copyWith(isInPictureInPicture: false);
      rethrow;
    }
  }

  /// 退出 PiP。不在 PiP 是 no-op，返回 false。
  Future<bool> exitPictureInPicture() async {
    if (!value.isInPictureInPicture) return false;
    final backend = _backend;
    if (backend == null) return false;
    return backend.exitPictureInPicture();
  }

  /// 查 backend 当前的 PiP 设备能力，把结果同步进 value。失败静默忽略。
  Future<void> _queryAndUpdatePipSupport() async {
    final backend = _backend;
    if (backend == null) return;
    try {
      final supported = await backend.queryPictureInPictureSupport();
      // 查询期间 load() 可能已换 backend：旧 backend 的能力（vp / IJK / web
      // 各不相同）不得写进新媒体的 value。
      if (_disposed || !identical(_backend, backend)) return;
      if (value.isPictureInPictureSupported != supported) {
        value = value.copyWith(isPictureInPictureSupported: supported);
      }
    } catch (_) {
      // 查询失败保持 false（默认值）
    }
  }

  /// 计算 aspect 整数 (num, den)：×1000 整数化 + GCD 约分，fallback 16:9。
  static (int, int) _aspectInts(Size size) {
    if (size.width <= 0 || size.height <= 0) return (16, 9);
    final w = (size.width * 1000).round();
    final h = (size.height * 1000).round();
    final g = _gcd(w, h);
    if (g == 0) return (16, 9);
    return (w ~/ g, h ~/ g);
  }

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _epoch++; // 作废仍在退避重试中的 init 链
    // 仍在播时直接销毁（feed 滑走等）也要退出亮屏计数，不留泄漏。
    _syncWakelock(false);
    if (_pipObserver != null) {
      WidgetsBinding.instance.removeObserver(_pipObserver!);
      _pipObserver = null;
    }
    await _disposeCurrentBackend();
    await _eventController.close();
    super.dispose();
  }
}
