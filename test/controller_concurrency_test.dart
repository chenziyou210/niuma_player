import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';
import 'package:niuma_player/src/data/_pip_event_bus.dart';

import 'helpers/fakes.dart';

/// 按 uri 放行的 middleware：没登记 gate 的源直接放行，登记了的要等测试
/// `release(uri)` 才返回。用来把一次 bring-up 精确卡在"middleware 跑完之前"，
/// 好让另一个操作插进来。
class _GateMiddleware extends SourceMiddleware {
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};

  void hold(String uri) => _gates[uri] = Completer<void>();

  void release(String uri) => _gates[uri]!.complete();

  @override
  Future<NiumaDataSource> apply(NiumaDataSource input) async {
    final gate = _gates[input.uri];
    if (gate != null) await gate.future;
    return input;
  }
}

/// 让事件循环转几圈，把链式 await 全部推进到下一个阻塞点。
Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Matcher get _superseded => throwsA(isA<StateError>().having(
      (e) => e.toString(),
      'message',
      contains('superseded or disposed'),
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final srcA = NiumaDataSource.network('https://a');
  final srcB = NiumaDataSource.network('https://b');
  final srcC = NiumaDataSource.network('https://c');

  test('切向 B 在途时再次选择 A：取消 B 并恢复 A 的位置和播放意图', () async {
    final gate = _GateMiddleware()..hold(srcB.uri);
    final factory = FakeBackendFactory();
    final ctrl = NiumaPlayerController(
      NiumaMediaSource.lines(lines: [
        MediaLine(id: 'a', label: 'A', source: srcA),
        MediaLine(id: 'b', label: 'B', source: srcB),
      ], defaultLineId: 'a'),
      middlewares: [gate],
      retryPolicy: const RetryPolicy.none(),
      platform: FakePlatformBridge(isIOS: true),
      backendFactory: factory,
    );
    addTearDown(ctrl.dispose);
    await ctrl.initialize();
    factory.videoPlayers.single.emitValue(ctrl.value.copyWith(
      phase: PlayerPhase.playing,
      position: const Duration(seconds: 5),
    ));
    final toB = ctrl.switchLine('b');
    final outcome = toB.then<Object?>((_) => null, onError: (Object e) => e);
    await _settle();
    await ctrl.switchLine('a');
    gate.release(srcB.uri);
    expect(await outcome, isA<StateError>());
    expect(ctrl.activeLineId, 'a');
    expect(
        factory.videoPlayers.last.lastSeekTarget, const Duration(seconds: 5));
    expect(factory.videoPlayers.last.playCalls, 1);
    final count = factory.videoPlayers.length;
    await ctrl.switchLine('a');
    expect(factory.videoPlayers.length, count, reason: '稳定的同线路调用仍为 no-op');
  });

  group('NiumaPlayerController 并发操作：后发操作必须压倒先发操作', () {
    test(
        'load() 打断卡在 middleware 的 initialize()：'
        '终态 backend 是新源，旧链的 backend 被销毁，旧 initialize() 以 superseded 结束',
        () async {
      final gate = _GateMiddleware()
        ..hold(srcA.uri)
        ..hold(srcB.uri);
      final factory = FakeBackendFactory();
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcA),
        middlewares: [gate],
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      final events = <NiumaPlayerEvent>[];
      final sub = ctrl.events.listen(events.add);

      // 旧链：过了代际检查，卡在 middleware(A)。
      final init = ctrl.initialize();
      final initOutcome = expectLater(init, _superseded);
      await _settle();

      // 新链：load(B) 插进来，同样卡在 middleware(B)。
      final load = ctrl.load(NiumaMediaSource.single(srcB));
      await _settle();

      // 新链先完成，旧链后醒来——旧链醒来后绝不能再碰 controller。
      gate.release(srcB.uri);
      await load;
      gate.release(srcA.uri);
      await initOutcome;
      await _settle();

      expect(ctrl.backend, isNotNull);
      expect((ctrl.backend! as FakePlayerBackend).source?.uri, srcB.uri,
          reason: '屏幕上必须是 load() 换上去的新源');
      expect((ctrl.backend! as FakePlayerBackend).disposed, isFalse);

      // 过期链要么根本不造 backend（在 middleware 之后就退出），要么造了
      // 必须自己销毁——两种都不许留下活的平台播放器。
      final leakedStale = factory.videoPlayers
          .where((b) => b.source?.uri == srcA.uri && !b.disposed);
      expect(leakedStale, isEmpty, reason: '过期链不得留下未销毁的 backend，否则泄漏平台播放器');

      expect(events.whereType<BackendSelected>().length, 1,
          reason: '只有胜出的那条链可以宣布 BackendSelected');

      await sub.cancel();
      await ctrl.dispose();
    });

    test(
        '并发 switchLine(b) / switchLine(c)，b 的 middleware 后返回：'
        '终态是 c，b 的 backend 被销毁，只发一条 LineSwitched(c)，b 的调用以 superseded 结束',
        () async {
      final gate = _GateMiddleware()
        ..hold(srcB.uri)
        ..hold(srcC.uri);
      final factory = FakeBackendFactory();
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.lines(
          lines: [
            MediaLine(id: 'a', label: 'A', source: srcA),
            MediaLine(id: 'b', label: 'B', source: srcB),
            MediaLine(id: 'c', label: 'C', source: srcC),
          ],
          defaultLineId: 'a',
        ),
        middlewares: [gate],
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      final events = <NiumaPlayerEvent>[];
      final sub = ctrl.events.listen(events.add);

      final toB = ctrl.switchLine('b');
      final toBOutcome = expectLater(toB, _superseded);
      await _settle();
      final toC = ctrl.switchLine('c');
      await _settle();

      gate.release(srcC.uri);
      await toC;
      gate.release(srcB.uri);
      await toBOutcome;
      await _settle();

      expect(ctrl.activeLineId, 'c');
      expect((ctrl.backend! as FakePlayerBackend).source?.uri, srcC.uri,
          reason: 'activeLineId 说是 c，屏幕上就必须是 c');
      expect((ctrl.backend! as FakePlayerBackend).disposed, isFalse);

      final leakedB = factory.videoPlayers
          .where((b) => b.source?.uri == srcB.uri && !b.disposed);
      expect(leakedB, isEmpty, reason: '被压倒的 switchLine(b) 不得留下未销毁的 backend');

      expect(
        events.whereType<LineSwitched>().map((e) => e.toId).toList(),
        ['c'],
        reason: '被压倒的切换不得宣布成功',
      );
      expect(events.whereType<LineSwitchFailed>(), isEmpty,
          reason: '被压倒不是失败：不该触发回滚，也不该上报 LineSwitchFailed');

      await sub.cancel();
      await ctrl.dispose();
    });

    test(
        'web 原地换源路径并发 load(A) / load(B)，A 的 middleware 后返回：'
        'backend 只收到 B，A 的调用以 superseded 结束', () async {
      final gate = _GateMiddleware()
        ..hold(srcA.uri)
        ..hold(srcB.uri);
      final factory = FakeBackendFactory(
        makeVideoPlayer: (_) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          supportsSourceSwap: true,
        ),
      );
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcC),
        middlewares: [gate],
        platform: FakePlatformBridge(isWeb: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      final backend = ctrl.backend! as FakePlayerBackend;

      final loadA = ctrl.load(NiumaMediaSource.single(srcA));
      final loadAOutcome = expectLater(loadA, _superseded);
      await _settle();
      final loadB = ctrl.load(NiumaMediaSource.single(srcB));
      await _settle();

      gate.release(srcB.uri);
      await loadB;
      gate.release(srcA.uri);
      await loadAOutcome;
      await _settle();

      expect(
        backend.loadedSources.map((s) => s.uri).toList(),
        [srcB.uri],
        reason: '过期的 load(A) 醒来后不得把 A 喂给 backend 覆盖 B',
      );
      expect(ctrl.source.currentLine.source.uri, srcB.uri);

      await ctrl.dispose();
    });

    test(
        'web 路径 initialize() 还在途时 load()：不对半初始化的 backend 原地换源，'
        '而是重建', () async {
      final initGate = Completer<void>();
      final factory = FakeBackendFactory(
        makeVideoPlayer: (ds) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          supportsSourceSwap: true,
          // 只卡第一个（源 A）的初始化
          initBlock: ds.uri == srcA.uri ? () => initGate.future : null,
        ),
      );
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcA),
        platform: FakePlatformBridge(isWeb: true),
        backendFactory: factory,
      );

      final init = ctrl.initialize();
      final initOutcome = expectLater(init, _superseded);
      await _settle();
      final first = factory.videoPlayers.single;

      await ctrl.load(NiumaMediaSource.single(srcB));
      initGate.complete();
      await initOutcome;
      await _settle();

      expect(first.loadedSources, isEmpty, reason: '半初始化的 backend 不能被 load()');
      expect(first.disposed, isTrue, reason: '旧 backend 应随重建被销毁');
      expect((ctrl.backend! as FakePlayerBackend).source?.uri, srcB.uri);
      expect(factory.videoPlayers.length, 2, reason: '重建 = 造了第二个 backend');

      await ctrl.dispose();
    });

    test('同一 tick 内连续两次 load()：只留最后一个源的 backend，不多造、不泄漏', () async {
      final factory = FakeBackendFactory();
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcC),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      final events = <NiumaPlayerEvent>[];
      final sub = ctrl.events.listen(events.add);

      final loadA = ctrl.load(NiumaMediaSource.single(srcA));
      final loadAOutcome = expectLater(loadA, _superseded);
      final loadB = ctrl.load(NiumaMediaSource.single(srcB));
      await loadB;
      await loadAOutcome;
      await _settle();

      expect((ctrl.backend! as FakePlayerBackend).source?.uri, srcB.uri);
      final alive = factory.videoPlayers.where((b) => !b.disposed).toList();
      expect(alive.length, 1, reason: '除当前 backend 外不得有存活的 backend');
      expect(identical(alive.single, ctrl.backend), isTrue);
      expect(events.whereType<BackendSelected>().length, 1,
          reason: '被压倒的 load(A) 不得起一条自己的 init 链');

      await sub.cancel();
      await ctrl.dispose();
    });
  });

  group('过期链醒来后的收尾不得伤及新链', () {
    test(
        'Android 单线路：initialize 被 load 压倒后才失败（不可重试）——'
        '旧链不得 dispose 新链的 backend、不得兜底 IJK、不得上报 FallbackTriggered', () async {
      final vpGateA = Completer<void>();
      final factory = FakeBackendFactory(
        makeVideoPlayer: (ds) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          initBlock: ds.uri == srcA.uri ? () => vpGateA.future : null,
        ),
      );
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcA),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(), // 非 iOS 非 web = Android 路径
        backendFactory: factory,
      );
      final events = <NiumaPlayerEvent>[];
      final sub = ctrl.events.listen(events.add);

      final init = ctrl.initialize();
      final initOutcome = expectLater(init, _superseded);
      await _settle();

      // 新链：load(B) 压倒旧链并正常起来。
      await ctrl.load(NiumaMediaSource.single(srcB));
      final backendB = ctrl.backend! as FakePlayerBackend;
      expect(backendB.source?.uri, srcB.uri);

      // 旧链的 vp 初始化此刻才失败（真实场景：它的 backend 已被压倒者
      // 销毁，抛的是普通异常而非生命周期取消，且不可重试）。
      vpGateA.completeError(StateError('vp init failed'));
      await initOutcome;
      await _settle();

      expect(backendB.disposed, isFalse,
          reason: '过期链的失败收尾不得 dispose 新链刚挂上的 backend');
      expect(identical(ctrl.backend, backendB), isTrue,
          reason: '_backend 必须仍指向新链的 backend');
      expect(factory.nativePlayers, isEmpty, reason: '过期链不得再为旧源拉起 IJK 兜底');
      expect(events.whereType<FallbackTriggered>(), isEmpty,
          reason: '过期链的失败不是本次播放的失败');
      expect(ctrl.value.phase, isNot(PlayerPhase.error));

      await sub.cancel();
      await ctrl.dispose();
    });

    test('卡死在 middleware 的旧链不得吞掉新链 backend 的 error（按代际过滤候选）', () async {
      final gate = _GateMiddleware()..hold(srcA.uri);
      final factory = FakeBackendFactory();
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcA),
        middlewares: [gate],
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );

      final init = ctrl.initialize();
      final initOutcome = expectLater(init, _superseded);
      await _settle();

      // 新链正常起来；旧链仍卡在 middleware(A)，其候选登记不会注销。
      await ctrl.load(NiumaMediaSource.single(srcB));
      final backendB = ctrl.backend! as FakePlayerBackend;

      // 正在播的新 backend 挂了：error 必须进 value，不能被旧链的
      // "候选拉起在途"误伤吞掉。
      backendB.emitValue(backendB.value.copyWith(
        phase: PlayerPhase.error,
        error: PlayerError(
          category: PlayerErrorCategory.network,
          message: 'stream died',
        ),
      ));
      await _settle();
      expect(ctrl.value.phase, PlayerPhase.error,
          reason: '稳定播放期的 error 不得因过期候选在途而被抑制');
      expect(ctrl.value.error?.message, 'stream died');

      gate.release(srcA.uri);
      await initOutcome;
      await ctrl.dispose();
    });

    test(
        'web 原地换源：A 已进 backend.load、B 压倒后 A 才完成——'
        'A 必须以 superseded 结束，不得宣布成功', () async {
      final gate = _GateMiddleware()..hold(srcB.uri);
      final loadGateA = Completer<void>();
      final factory = FakeBackendFactory(
        makeVideoPlayer: (_) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          supportsSourceSwap: true,
          loadBlock: (ds) async {
            if (ds.uri == srcA.uri) await loadGateA.future;
          },
        ),
      );
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcC),
        middlewares: [gate],
        platform: FakePlatformBridge(isWeb: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      final backend = ctrl.backend! as FakePlayerBackend;

      // A 过了 middleware，进到 backend.load 里等着。
      final loadA = ctrl.load(NiumaMediaSource.single(srcA));
      final loadAOutcome = expectLater(loadA, _superseded);
      await _settle();

      // B 压倒 A 后卡在 middleware(B)——controller 已声明 source=B。
      final loadB = ctrl.load(NiumaMediaSource.single(srcB));
      await _settle();
      expect(ctrl.source.currentLine.source.uri, srcB.uri);

      // A 此刻才从 backend.load 回来：明明已被压倒，不得宣布成功。
      loadGateA.complete();
      await loadAOutcome;

      gate.release(srcB.uri);
      await loadB;
      expect(backend.loadedSources.last.uri, srcB.uri,
          reason: '最终喂给 backend 的必须是 B');

      await ctrl.dispose();
    });

    test('switchLine 在"恢复播放"的 await 期间被压倒：不得事后补发 LineSwitched', () async {
      final playGateB = Completer<void>();
      final factory = FakeBackendFactory(
        makeVideoPlayer: (ds) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          playBlock: ds.uri == srcB.uri ? () => playGateB.future : null,
        ),
      );
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.lines(
          lines: [
            MediaLine(id: 'a', label: 'A', source: srcA),
            MediaLine(id: 'b', label: 'B', source: srcB),
            MediaLine(id: 'c', label: 'C', source: srcC),
          ],
          defaultLineId: 'a',
        ),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      // 打上播放意图：切换成功后要续播，会走 _backend.play() 的 await。
      final backendA = ctrl.backend! as FakePlayerBackend;
      backendA.emitValue(backendA.value.copyWith(phase: PlayerPhase.playing));
      final events = <NiumaPlayerEvent>[];
      final sub = ctrl.events.listen(events.add);

      // b 拉起成功，卡在恢复播放的 play() 里。
      final toB = ctrl.switchLine('b');
      final toBOutcome = expectLater(toB, _superseded);
      await _settle();

      // c 压倒 b 并完成。
      await ctrl.switchLine('c');
      expect(
          events.whereType<LineSwitched>().map((e) => e.toId).toList(), ['c']);

      // b 此刻才从 play() 回来：不得补一条 LineSwitched(b)。
      playGateB.complete();
      await toBOutcome;
      await _settle();

      expect(
        events.whereType<LineSwitched>().map((e) => e.toId).toList(),
        ['c'],
        reason: '被压倒的切换不得在事后宣布成功',
      );
      expect(ctrl.activeLineId, 'c');

      await sub.cancel();
      await ctrl.dispose();
    });
  });

  group('终局失败与迟到回调的清理', () {
    test('初始化终局失败后：失败候选必须被摘除销毁，迟到的 ready 不得覆盖 error', () async {
      final initGate = Completer<void>();
      final factory = FakeBackendFactory(
        makeVideoPlayer: (_) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          initBlock: () => initGate.future,
        ),
      );
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcA),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      final init = ctrl.initialize();
      final initOutcome = expectLater(init, throwsA(isA<StateError>()));
      await _settle();
      final backend = factory.videoPlayers.single;

      // 终局失败：不可重试、无备用线路、无 IJK 兜底（iOS）。
      initGate.completeError(StateError('init failed'));
      await initOutcome;
      await _settle();

      expect(ctrl.value.phase, PlayerPhase.error);
      expect(backend.disposed, isTrue,
          reason: 'Future.timeout 不取消底层初始化：失败候选不销毁的话，'
              '平台侧还在后台继续加载');
      expect(ctrl.backend, isNull);

      // 老代码里失败候选仍挂在 controller 上：迟到的 ready 会把 error 覆盖。
      backend.emitValue(backend.value.copyWith(phase: PlayerPhase.ready));
      await _settle();
      expect(ctrl.value.phase, PlayerPhase.error,
          reason: '迟到的 ready 不得复活已宣告失败的播放器');

      await ctrl.dispose();
    });

    test(
        'PiP 能力查询不阻塞 initialize 完成；查询期间被 load 压倒后，'
        '旧 backend 的迟到结果不得写进新媒体', () async {
      final queryGateA = Completer<bool>();
      final factory = FakeBackendFactory(
        makeVideoPlayer: (ds) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          pipQueryBlock: ds.uri == srcA.uri ? () => queryGateA.future : null,
        ),
      );
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcA),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      final init = ctrl.initialize();
      var initDone = false;
      unawaited(init.then((_) => initDone = true, onError: (Object _) {}));
      await _settle();
      // 查询是 best-effort：拉起成功即完成 initialize，不等 method channel
      // 往返——否则 dispose / switchLine 打断查询后旧 initialize 反而成功。
      expect(initDone, isTrue, reason: 'PiP 能力查询不得把 initialize 的完成挡在自己身后');

      await ctrl.load(NiumaMediaSource.single(srcB)); // B 的查询立即返回 false
      expect(ctrl.value.isPictureInPictureSupported, isFalse);

      queryGateA.complete(true); // 旧 backend 此刻才回答"支持"
      await _settle();

      expect(ctrl.value.isPictureInPictureSupported, isFalse,
          reason: '旧 backend 的能力结果不得污染新媒体的 value');

      await ctrl.dispose();
    });

    test('dispose 时 PiP 查询在途：initialize 已在 dispose 前完成，迟到结果安全丢弃', () async {
      final queryGate = Completer<bool>();
      final factory = FakeBackendFactory(
        makeVideoPlayer: (_) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          pipQueryBlock: () => queryGate.future,
        ),
      );
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcA),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      final init = ctrl.initialize();
      var initDone = false;
      unawaited(init.then((_) => initDone = true, onError: (Object _) {}));
      await _settle();
      expect(initDone, isTrue,
          reason: '此前查询挡在 complete 之前，dispose 打断后 initialize '
              '会在 dispose 之后才"成功"');

      await ctrl.dispose();
      queryGate.complete(true); // 查询此刻才回来
      await _settle();
      expect(ctrl.value.isPictureInPictureSupported, isFalse,
          reason: 'dispose 后迟到的查询结果不得再写 value');
    });

    test('失败候选的清理本身抛错：不得替换原始初始化错误', () async {
      final initGate = Completer<void>();
      final factory = FakeBackendFactory(
        makeVideoPlayer: (_) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          initBlock: () => initGate.future,
        )..disposeError = StateError('cleanup blew up'),
      );
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcA),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      final init = ctrl.initialize();
      final initOutcome = expectLater(init, throwsA(isA<TimeoutException>()));
      await _settle();

      initGate.completeError(TimeoutException('init timed out'));
      await initOutcome; // 原始错误不得被清理错误顶掉
      await _settle();
      expect(ctrl.value.error?.category, PlayerErrorCategory.network,
          reason: '清理错误顶掉超时错误会把 network 分类改成 unknown，'
              '带偏 retry / failover 决策');

      await ctrl.dispose();
    });

    test('PiP 中 load() 重建 backend：新 backend 收养 PiP 会话归属', () async {
      addTearDown(debugResetPipEventBus);
      final factory = FakeBackendFactory();
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(srcA),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      final oldBackend = ctrl.backend!;
      // 模拟已在 PiP 中：置位 + 会话归属旧 backend（真实流程由
      // enterPictureInPicture 完成）。
      ctrl.value = ctrl.value.copyWith(isInPictureInPicture: true);
      claimPipOwnership(oldBackend);

      await ctrl.load(NiumaMediaSource.single(srcB));

      expect(identical(ctrl.backend, oldBackend), isFalse);
      expect(debugPipOwner, same(ctrl.backend),
          reason: 'Activity 级 PiP 会话还在继续，新 backend 不接管的话，'
              '遥控与 pipStopped 全被 tombstone 丢弃');

      await ctrl.dispose();
    });
  });
}
