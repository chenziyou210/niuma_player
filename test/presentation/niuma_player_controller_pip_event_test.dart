import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';

class _PipEmittingFakeBackend extends PlayerBackend {
  final _valueCtrl = StreamController<NiumaPlayerValue>.broadcast(sync: true);
  final _eventCtrl = StreamController<NiumaPlayerEvent>.broadcast(sync: true);
  NiumaPlayerValue _value = NiumaPlayerValue.uninitialized();

  int playCalled = 0;
  int pauseCalled = 0;

  void emit(NiumaPlayerEvent event) {
    _eventCtrl.add(event);
  }

  void simulateValue(NiumaPlayerValue v) {
    _value = v;
    _valueCtrl.add(_value);
  }

  @override
  PlayerBackendKind get kind => PlayerBackendKind.videoPlayer;
  @override
  int? get textureId => null;
  @override
  NiumaPlayerValue get value => _value;
  @override
  Stream<NiumaPlayerValue> get valueStream => _valueCtrl.stream;
  @override
  Stream<NiumaPlayerEvent> get eventStream => _eventCtrl.stream;

  @override
  Future<void> initialize() async {
    _value = NiumaPlayerValue(
      phase: PlayerPhase.ready,
      position: Duration.zero,
      duration: const Duration(seconds: 10),
      size: const Size(1920, 1080),
      bufferedPosition: Duration.zero,
    );
    _valueCtrl.add(_value);
  }

  @override
  Future<void> play() async => playCalled++;
  @override
  Future<void> pause() async => pauseCalled++;
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setLooping(bool looping) async {}
  @override
  Future<void> dispose() async {
    await _valueCtrl.close();
    await _eventCtrl.close();
  }
}

class _PipEmittingFakeFactory implements BackendFactory {
  _PipEmittingFakeFactory(this.backend);
  final _PipEmittingFakeBackend backend;
  @override
  PlayerBackend createVideoPlayer(NiumaDataSource ds, {bool useAndroidPlatformView = false}) =>
      backend;
  @override
  PlayerBackend createNative(NiumaDataSource ds,
      {bool useAndroidPlatformView = false}) =>
      backend;
}

NiumaPlayerController _makeController(_PipEmittingFakeBackend backend) {
  return NiumaPlayerController.dataSource(
    NiumaDataSource.network('https://example.com/test.mp4'),
    backendFactory: _PipEmittingFakeFactory(backend),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PiP EventChannel → Controller value 同步', () {
    test('PipModeChanged(true) → value.isInPictureInPicture = true', () async {
      final backend = _PipEmittingFakeBackend();
      final c = _makeController(backend);
      await c.initialize();
      expect(c.value.isInPictureInPicture, isFalse);
      backend.emit(const PipModeChanged(isInPip: true));
      // 等 controller 处理事件
      await Future<void>.delayed(Duration.zero);
      expect(c.value.isInPictureInPicture, isTrue);
      await c.dispose();
    });

    test('PipModeChanged(false) → value.isInPictureInPicture = false',
        () async {
      final backend = _PipEmittingFakeBackend();
      final c = _makeController(backend);
      await c.initialize();
      c.value = c.value.copyWith(isInPictureInPicture: true);
      backend.emit(const PipModeChanged(isInPip: false));
      await Future<void>.delayed(Duration.zero);
      expect(c.value.isInPictureInPicture, isFalse);
      // 非 playing 状态退 PiP 不调 pause（由 fix #3 保证）
      expect(backend.pauseCalled, 0);
      await c.dispose();
    });

    test('PipModeChanged(false) + playing → 自动暂停（B 站/YouTube 行为）', () async {
      final backend = _PipEmittingFakeBackend();
      final c = _makeController(backend);
      await c.initialize();
      // 模拟在 PiP 中正在播。PiP 状态由 controller 自己维护（backend 推的
      // value 会被 copyWith 保留 controller 侧的 PiP 位），所以直接置 value。
      backend.simulateValue(c.value.copyWith(phase: PlayerPhase.playing));
      c.value = c.value.copyWith(isInPictureInPicture: true);
      // 用户按 X 关闭 PiP
      backend.emit(const PipModeChanged(isInPip: false));
      await Future<void>.delayed(Duration.zero);
      expect(c.value.isInPictureInPicture, isFalse);
      expect(backend.pauseCalled, 1, reason: '退出 PiP 应自动暂停');
      await c.dispose();
    });

    test('本实例从未进过 PiP 时收到 PipModeChanged(false)：不暂停、不透传（多实例不串台）',
        () async {
      final backend = _PipEmittingFakeBackend();
      final c = _makeController(backend);
      await c.initialize();
      backend.simulateValue(c.value.copyWith(phase: PlayerPhase.playing));
      expect(c.value.isInPictureInPicture, isFalse);
      final events = <NiumaPlayerEvent>[];
      final sub = c.events.listen(events.add);

      // 别的播放器退出 PiP（无 owner 的广播兜底路径把事件也发给了本实例）。
      backend.emit(const PipModeChanged(isInPip: false));
      await Future<void>.delayed(Duration.zero);

      expect(backend.pauseCalled, 0,
          reason: '不是本实例的 PiP 会话，正在播的实例不得被误暂停');
      expect(c.value.phase, PlayerPhase.playing);
      expect(events.whereType<PipModeChanged>(), isEmpty,
          reason: '不属于本实例的退出事件不透传，避免上层误响应');

      await sub.cancel();
      await c.dispose();
    });

    test('PipStartFailed（iOS 启动失败 / 等 possible 超时）→ isInPip 回 false、不暂停、事件透传',
        () async {
      final backend = _PipEmittingFakeBackend();
      final c = _makeController(backend);
      await c.initialize();
      backend.simulateValue(backend.value.copyWith(phase: PlayerPhase.playing));
      // enterPictureInPicture 会先乐观置 true；这里直接模拟那个状态。
      c.value = c.value.copyWith(isInPictureInPicture: true);
      final events = <NiumaPlayerEvent>[];
      final sub = c.events.listen(events.add);

      backend.emit(const PipStartFailed(reason: 'AVKit: not possible'));
      await Future<void>.delayed(Duration.zero);

      expect(c.value.isInPictureInPicture, isFalse,
          reason: 'PiP 根本没起来，乐观置位必须回滚，否则控件一直藏着');
      expect(backend.pauseCalled, 0,
          reason: '这不是"退出 PiP"，不能触发退出 PiP 的默认暂停');
      expect(events.whereType<PipStartFailed>().single.reason,
          'AVKit: not possible');
      await sub.cancel();
      await c.dispose();
    });

    test('PipRemoteAction(playPauseToggle) playing → 调 pause', () async {
      final backend = _PipEmittingFakeBackend();
      final c = _makeController(backend);
      await c.initialize();
      // 遥控来自 PiP 窗，实例必然在 PiP 中（PiP 位由 controller 维护）。
      backend.simulateValue(c.value.copyWith(phase: PlayerPhase.playing));
      c.value = c.value.copyWith(isInPictureInPicture: true);
      backend.emit(const PipRemoteAction(action: 'playPauseToggle'));
      await Future<void>.delayed(Duration.zero);
      expect(backend.pauseCalled, 1);
      await c.dispose();
    });

    test('PipRemoteAction(playPauseToggle) paused → 调 play', () async {
      final backend = _PipEmittingFakeBackend();
      final c = _makeController(backend);
      await c.initialize();
      backend.simulateValue(c.value.copyWith(phase: PlayerPhase.paused));
      c.value = c.value.copyWith(isInPictureInPicture: true);
      backend.emit(const PipRemoteAction(action: 'playPauseToggle'));
      await Future<void>.delayed(Duration.zero);
      expect(backend.playCalled, 1);
      await c.dispose();
    });

    test('本实例不在 PiP 中收到 PipRemoteAction：不播放/暂停、不透传（多实例不串台）',
        () async {
      final backend = _PipEmittingFakeBackend();
      final c = _makeController(backend);
      await c.initialize();
      backend.simulateValue(c.value.copyWith(phase: PlayerPhase.playing));
      expect(c.value.isInPictureInPicture, isFalse);
      final events = <NiumaPlayerEvent>[];
      final sub = c.events.listen(events.add);

      // 别的播放器 PiP 窗的遥控（无 owner 广播兜底 / owner 已 dispose 的迟到事件）。
      backend.emit(const PipRemoteAction(action: 'playPauseToggle'));
      await Future<void>.delayed(Duration.zero);

      expect(backend.pauseCalled, 0,
          reason: '不是本实例的 PiP 遥控，不得让所有实例一起播放/暂停');
      expect(backend.playCalled, 0);
      expect(events.whereType<PipRemoteAction>(), isEmpty);

      await sub.cancel();
      await c.dispose();
    });
  });
}
