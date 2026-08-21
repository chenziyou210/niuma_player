import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';

/// 可控 + 记录型 fake backend：可直接 emit 带 duration 的 value，并记录
/// seek / 亮度 / 音量调用，用于断言 [NiumaGestureController] 的纯逻辑。
class _RecBackend extends PlayerBackend {
  final StreamController<NiumaPlayerValue> _vc =
      StreamController<NiumaPlayerValue>.broadcast(sync: true);
  final StreamController<NiumaPlayerEvent> _ec =
      StreamController<NiumaPlayerEvent>.broadcast(sync: true);
  NiumaPlayerValue _v = NiumaPlayerValue.uninitialized();

  double brightness = 0.3;
  double volume = 0.4;
  final List<double> brightnessSets = <double>[];
  final List<double> volumeSets = <double>[];
  Duration? lastSeek;

  void emit(NiumaPlayerValue v) {
    _v = v;
    _vc.add(v);
  }

  @override
  PlayerBackendKind get kind => PlayerBackendKind.videoPlayer;
  @override
  int? get textureId => null;
  @override
  NiumaPlayerValue get value => _v;
  @override
  Stream<NiumaPlayerValue> get valueStream => _vc.stream;
  @override
  Stream<NiumaPlayerEvent> get eventStream => _ec.stream;
  @override
  Future<void> initialize() async =>
      emit(_v.copyWith(phase: PlayerPhase.ready));
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekTo(Duration position) async => lastSeek = position;
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setVolume(double v) async {}
  @override
  Future<void> setLooping(bool looping) async {}
  /// 每次 [getBrightness] 调用登记一个 gate；非空时要等测试放行才返回，
  /// 用来模拟 method channel 读亮度的异步窗口。
  final List<Completer<void>> brightnessGates = <Completer<void>>[];
  bool gateBrightness = false;

  @override
  Future<double> getBrightness() async {
    if (gateBrightness) {
      final gate = Completer<void>();
      brightnessGates.add(gate);
      await gate.future;
    }
    return brightness;
  }
  @override
  Future<bool> setBrightness(double v) async {
    brightnessSets.add(v);
    brightness = v;
    return true;
  }

  @override
  Future<double> getSystemVolume() async => volume;
  @override
  Future<bool> setSystemVolume(double v) async {
    volumeSets.add(v);
    volume = v;
    return true;
  }

  @override
  Future<void> dispose() async {
    await _vc.close();
    await _ec.close();
  }
}

class _Factory implements BackendFactory {
  _Factory(this.backend);
  final _RecBackend backend;
  @override
  PlayerBackend createVideoPlayer(NiumaDataSource ds, {bool useAndroidPlatformView = false}) =>
      backend;
  @override
  PlayerBackend createNative(NiumaDataSource ds,
      {bool useAndroidPlatformView = false}) =>
      backend;
}

class _NoopBridge implements PlatformBridge {
  @override
  bool get isIOS => false;
  @override
  bool get isWeb => false;
  @override
  Future<int> processHeapLimitMb() async => 256;
  @override
  Future<void> setKeepScreenOn(bool on) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const size = Size(400, 300);

  Future<(NiumaPlayerController, _RecBackend, NiumaGestureController)>
      build() async {
    final backend = _RecBackend();
    final controller = NiumaPlayerController(
      NiumaMediaSource.single(NiumaDataSource.network('https://x/v.mp4')),
      platform: _NoopBridge(),
      backendFactory: _Factory(backend),
    );
    await controller.initialize();
    // 注入 4 分钟时长 + 当前 1 分钟位置，供 seek 数学用。
    backend.emit(NiumaPlayerValue.uninitialized().copyWith(
      phase: PlayerPhase.playing,
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 4),
    ));
    return (controller, backend, NiumaGestureController(controller));
  }

  test('水平 pan 过阈值 → 锁定 seek，松手按进度提交 seekTo', () async {
    final (controller, backend, g) = await build();
    g.onPanStart(const Offset(200, 150));
    // dx = +width*0.5 = +200 → delta = 0.5 * 240000 * 0.5 = 60000ms = +60s
    await g.onPanUpdate(const Offset(400, 150), size);
    expect(g.feedback.value?.kind, GestureKind.horizontalSeek);
    g.onPanEnd();
    // seekStart 1min + 60s = 2min。
    expect(backend.lastSeek, const Duration(minutes: 2));
    await controller.dispose();
  });

  test('左半屏垂直 pan → 锁定亮度并记录 setBrightness', () async {
    final (controller, backend, g) = await build();
    g.onPanStart(const Offset(50, 150)); // 左半屏
    await g.onPanUpdate(const Offset(50, 30), size); // 上滑 → 亮度增
    expect(g.feedback.value?.kind, GestureKind.brightness);
    expect(backend.brightnessSets, isNotEmpty);
    expect(backend.brightnessSets.last, greaterThan(0.3));
    await controller.dispose();
  });

  test('右半屏垂直 pan → 锁定音量并记录 setSystemVolume', () async {
    final (controller, backend, g) = await build();
    g.onPanStart(const Offset(350, 150)); // 右半屏
    await g.onPanUpdate(const Offset(350, 30), size); // 上滑 → 音量增
    expect(g.feedback.value?.kind, GestureKind.volume);
    expect(backend.volumeSets, isNotEmpty);
    expect(backend.volumeSets.last, greaterThan(0.4));
    await controller.dispose();
  });

  test('双击播放中 → 暂停 + HUD 用语义 hudIcon 不引 material icon / 资源路径', () async {
    final (controller, backend, g) = await build();
    g.onDoubleTap();
    final hud = g.feedback.value;
    expect(hud?.kind, GestureKind.doubleTap);
    expect(hud?.hudIcon, GestureHudIcon.pause);
    await controller.dispose();
  });

  test('disabledGestures 命中 → 双击不触发、无 HUD', () async {
    final backend = _RecBackend();
    final controller = NiumaPlayerController(
      NiumaMediaSource.single(NiumaDataSource.network('https://x/v.mp4')),
      platform: _NoopBridge(),
      backendFactory: _Factory(backend),
    );
    await controller.initialize();
    final g = NiumaGestureController(
      controller,
      disabledGestures: const {GestureKind.doubleTap},
    );
    g.onDoubleTap();
    expect(g.feedback.value, isNull);
    await controller.dispose();
  });

  test('亮度基准还在异步读取时松手：迟到的读数不抛 null 断言、不设亮度、不弹 HUD',
      () async {
    final (controller, backend, g) = await build();
    backend.gateBrightness = true;
    g.onPanStart(const Offset(50, 150));
    final update = g.onPanUpdate(const Offset(50, 30), size); // 卡在 getBrightness
    g.onPanEnd(); // 用户松手
    backend.brightnessGates.single.complete();

    await update; // 此前在这里抛 "Null check operator used on a null value"
    expect(backend.brightnessSets, isEmpty,
        reason: '手势已结束，迟到的读数不该再去动系统亮度');
    expect(g.feedback.value, isNull);
    await controller.dispose();
  });

  test('上一手势迟到的亮度读数不覆盖新手势的基准值', () async {
    final (controller, backend, g) = await build();
    backend.gateBrightness = true;

    // 手势 1：读数挂起，用户松手。
    g.onPanStart(const Offset(50, 150));
    final update1 = g.onPanUpdate(const Offset(50, 30), size);
    g.onPanEnd();

    // 手势 2：重新起手，读数也挂起。
    g.onPanStart(const Offset(50, 150));
    final update2 = g.onPanUpdate(const Offset(50, 30), size);
    expect(backend.brightnessGates.length, 2);

    // 手势 2 的读数先回来：基准 0.3。
    backend.brightness = 0.3;
    backend.brightnessGates[1].complete();
    await update2;
    // 手势 1 的读数后回来，且系统亮度此时已是 0.9——它属于已结束的手势，必须被丢弃。
    backend.brightness = 0.9;
    backend.brightnessGates[0].complete();
    await update1;

    // 手势 2 继续：dy=0 → 设置值应等于手势 2 的基准 0.3，而不是 0.9。
    backend.brightnessSets.clear();
    backend.gateBrightness = false;
    await Future<void>.delayed(const Duration(milliseconds: 60)); // 过节流窗口
    await g.onPanUpdate(const Offset(50, 150), size);
    expect(backend.brightnessSets.last, closeTo(0.3, 0.001),
        reason: '基准被旧手势迟到的 0.9 覆盖了');
    await controller.dispose();
  });
}
