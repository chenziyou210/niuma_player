import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:niuma_player/niuma_player.dart';

/// Simple controllable fake. Tests provide [initBlock] to drive the
/// "Try-Once-Then-Retry" state machine in [NiumaPlayerController].
class FakePlayerBackend extends PlayerBackend {
  FakePlayerBackend({
    required this.kind,
    this.initBlock,
    this.source,
    this.supportsSourceSwap = false,
    this.loadBlock,
  });

  @override
  final PlayerBackendKind kind;

  /// If non-null, [initialize] invokes this and awaits its result. Lazy
  /// (a `Function`) rather than a bare `Future` so an "errors immediately"
  /// case doesn't fire as an unhandled async error before the controller
  /// has had a chance to attach a listener via [initialize]'s await.
  final Future<void> Function()? initBlock;

  /// The (middleware-resolved) data source this backend was built for.
  /// [FakeBackendFactory] fills it in when the `make*` callback leaves it
  /// null, so concurrency tests can tell "which source is on screen".
  NiumaDataSource? source;

  /// Whether this fake claims in-place source swapping (the web path).
  @override
  final bool supportsSourceSwap;

  /// If non-null, [load] awaits it before recording the new source —
  /// lets tests hold an in-place swap open to race another call into it.
  final Future<void> Function(NiumaDataSource source)? loadBlock;

  /// Every source handed to [load], in call-completion order.
  final List<NiumaDataSource> loadedSources = <NiumaDataSource>[];

  @override
  Future<void> load(NiumaDataSource source) async {
    if (loadBlock != null) await loadBlock!(source);
    this.source = source;
    loadedSources.add(source);
  }

  final StreamController<NiumaPlayerValue> _valueController =
      StreamController<NiumaPlayerValue>.broadcast(sync: true);
  final StreamController<NiumaPlayerEvent> _eventController =
      StreamController<NiumaPlayerEvent>.broadcast(sync: true);

  NiumaPlayerValue _value = NiumaPlayerValue.uninitialized();

  bool disposed = false;

  /// Last argument passed to [seekTo]; null if seekTo was never called.
  Duration? lastSeekTarget;

  /// Number of [play] calls.
  int playCalls = 0;

  /// Push an arbitrary value through [valueStream] (and make it [value]).
  void emitValue(NiumaPlayerValue v) {
    _value = v;
    if (!_valueController.isClosed) _valueController.add(v);
  }

  /// Simulated playback position returned by [value].
  Duration _simulatedPosition = Duration.zero;

  @override
  int? get textureId => kind == PlayerBackendKind.native ? 42 : null;

  @override
  NiumaPlayerValue get value => _value;

  @override
  Stream<NiumaPlayerValue> get valueStream => _valueController.stream;

  @override
  Stream<NiumaPlayerEvent> get eventStream => _eventController.stream;

  @override
  Future<void> initialize() async {
    if (initBlock != null) {
      await initBlock!();
    }
    _value = NiumaPlayerValue(
      phase: PlayerPhase.ready,
      position: _simulatedPosition,
      duration: const Duration(seconds: 10),
      size: const Size(1280, 720),
      bufferedPosition: Duration.zero,
    );
    if (!_valueController.isClosed) {
      _valueController.add(_value);
    }
  }

  /// Sets the simulated position reflected by [value.position]. Call before
  /// [initialize] to pre-seed the position, or after to update it live.
  void simulatePosition(Duration pos) {
    _simulatedPosition = pos;
    _value = NiumaPlayerValue(
      phase: _value.phase,
      position: pos,
      duration: _value.duration,
      size: _value.size,
      bufferedPosition: _value.bufferedPosition,
    );
    if (!_valueController.isClosed) {
      _valueController.add(_value);
    }
  }

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(Duration position) async {
    lastSeekTarget = position;
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setLooping(bool looping) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await _valueController.close();
    await _eventController.close();
  }
}

/// Records every [createVideoPlayer] / [createNative] call. Tests can drive
/// a sequence of fake backends (e.g. first one errors, second one succeeds)
/// by giving a `makeNative` that picks a different fake per call index.
///
/// The no-arg [FakeBackendFactory()] constructor creates simple, always-
/// succeeding video-player backends and is convenient for tests that only
/// need to inspect [simulatePosition] / [lastSeekTarget].
class FakeBackendFactory implements BackendFactory {
  FakeBackendFactory({
    FakePlayerBackend Function(NiumaDataSource ds)? makeVideoPlayer,
    FakePlayerBackend Function(NiumaDataSource ds)? makeNative,
  })  : makeVideoPlayer = makeVideoPlayer ??
            ((_) => FakePlayerBackend(kind: PlayerBackendKind.videoPlayer)),
        makeNative = makeNative ??
            ((_) => FakePlayerBackend(kind: PlayerBackendKind.native));

  final FakePlayerBackend Function(NiumaDataSource ds) makeVideoPlayer;
  final FakePlayerBackend Function(NiumaDataSource ds) makeNative;

  final List<FakePlayerBackend> videoPlayers = <FakePlayerBackend>[];
  final List<FakePlayerBackend> nativePlayers = <FakePlayerBackend>[];

  /// Records the last [NiumaDataSource] passed to either [createVideoPlayer]
  /// or [createNative], after the middleware pipeline has run. Tests assert
  /// on this to verify middleware mutations were applied before the backend
  /// factory was invoked.
  NiumaDataSource? lastSourceFromMiddleware;

  /// The most recently constructed [FakePlayerBackend] (video-player or
  /// native). Convenience accessor for [simulatePosition] / [lastSeekTarget]
  /// without having to index into [videoPlayers] / [nativePlayers].
  FakePlayerBackend? get _latestBackend =>
      (videoPlayers + nativePlayers).isNotEmpty
          ? (videoPlayers + nativePlayers).last
          : null;

  /// Delegates to the latest backend's [FakePlayerBackend.simulatePosition].
  void simulatePosition(Duration pos) => _latestBackend?.simulatePosition(pos);

  /// Returns the last seek target recorded by the latest backend.
  Duration? get lastSeekTarget => _latestBackend?.lastSeekTarget;

  @override
  PlayerBackend createVideoPlayer(NiumaDataSource ds, {bool useAndroidPlatformView = false}) {
    lastSourceFromMiddleware = ds;
    final b = makeVideoPlayer(ds);
    b.source ??= ds;
    videoPlayers.add(b);
    return b;
  }

  @override
  PlayerBackend createNative(NiumaDataSource ds,
      {bool useAndroidPlatformView = false}) {
    lastSourceFromMiddleware = ds;
    final b = makeNative(ds);
    b.source ??= ds;
    nativePlayers.add(b);
    return b;
  }
}

/// Stubs the host check so tests don't hit `dart:io` Platform / `kIsWeb`.
class FakePlatformBridge implements PlatformBridge {
  FakePlatformBridge({
    this.isIOS = false,
    this.isWeb = false,
  });

  @override
  final bool isIOS;

  @override
  final bool isWeb;

  @override
  Future<int> processHeapLimitMb() async => 256;

  @override
  Future<void> setKeepScreenOn(bool on) async {}
}
