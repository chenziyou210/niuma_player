import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';

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
      expect(leakedStale, isEmpty,
          reason: '过期链不得留下未销毁的 backend，否则泄漏平台播放器');

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
      expect(leakedB, isEmpty,
          reason: '被压倒的 switchLine(b) 不得留下未销毁的 backend');

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

      expect(first.loadedSources, isEmpty,
          reason: '半初始化的 backend 不能被 load()');
      expect(first.disposed, isTrue, reason: '旧 backend 应随重建被销毁');
      expect((ctrl.backend! as FakePlayerBackend).source?.uri, srcB.uri);
      expect(factory.videoPlayers.length, 2, reason: '重建 = 造了第二个 backend');

      await ctrl.dispose();
    });

    test('同一 tick 内连续两次 load()：只留最后一个源的 backend，不多造、不泄漏',
        () async {
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
}
