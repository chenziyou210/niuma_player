import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';

/// 轻量 fake backend——只需驱动 [NiumaPlayerController.initialize] 走通，
/// 并记录 play / pause / dispose 调用供池行为断言。
class _FakeBackend extends PlayerBackend {
  _FakeBackend({this.initBlock});

  final Future<void> Function()? initBlock;

  @override
  PlayerBackendKind get kind => PlayerBackendKind.videoPlayer;

  final StreamController<NiumaPlayerValue> _values =
      StreamController<NiumaPlayerValue>.broadcast(sync: true);
  final StreamController<NiumaPlayerEvent> _events =
      StreamController<NiumaPlayerEvent>.broadcast(sync: true);

  bool pauseCalled = false;
  bool disposed = false;

  @override
  int? get textureId => null;

  @override
  NiumaPlayerValue get value => NiumaPlayerValue.uninitialized();

  @override
  Stream<NiumaPlayerValue> get valueStream => _values.stream;

  @override
  Stream<NiumaPlayerEvent> get eventStream => _events.stream;

  @override
  Future<void> initialize() async {
    if (initBlock != null) {
      await initBlock!();
    }
    _values.add(NiumaPlayerValue(
      phase: PlayerPhase.ready,
      position: Duration.zero,
      duration: const Duration(seconds: 10),
      size: const Size(1280, 720),
      bufferedPosition: Duration.zero,
    ));
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async => pauseCalled = true;
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
    disposed = true;
    await _values.close();
    await _events.close();
  }
}

class _FakeFactory implements BackendFactory {
  _FakeFactory({this.makeBackend});

  final _FakeBackend Function()? makeBackend;

  final List<_FakeBackend> created = <_FakeBackend>[];

  @override
  PlayerBackend createVideoPlayer(NiumaDataSource ds, {bool useAndroidPlatformView = false}) {
    final b = makeBackend?.call() ?? _FakeBackend();
    created.add(b);
    return b;
  }

  @override
  PlayerBackend createNative(NiumaDataSource ds,
      {bool useAndroidPlatformView = false}) {
    final b = makeBackend?.call() ?? _FakeBackend();
    created.add(b);
    return b;
  }
}

class _FakeBridge implements PlatformBridge {
  @override
  bool get isIOS => true; // 走 video_player 主路径，池测试无需 Android IJK 兜底分支
  @override
  bool get isWeb => false;
  @override
  Future<int> processHeapLimitMb() async => 256;
  @override
  Future<void> setKeepScreenOn(bool on) async {}
}

NiumaMediaSource _src(String url) =>
    NiumaMediaSource.single(NiumaDataSource.network(url));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 计数：每次池建 controller 调了多少次工厂，用于"命中不重复建"断言。
  int factoryCalls = 0;

  PoolControllerFactory factoryWith(_FakeFactory backendFactory) {
    return (source) {
      factoryCalls++;
      return NiumaPlayerController(
        source,
        platform: _FakeBridge(),
        backendFactory: backendFactory,
      );
    };
  }

  setUp(() => factoryCalls = 0);

  group('computeCapacityForHeap', () {
    test('阈值映射', () {
      expect(NiumaPlayerPool.computeCapacityForHeap(128), 1);
      expect(NiumaPlayerPool.computeCapacityForHeap(191), 1);
      expect(NiumaPlayerPool.computeCapacityForHeap(192), 2);
      expect(NiumaPlayerPool.computeCapacityForHeap(319), 2);
      expect(NiumaPlayerPool.computeCapacityForHeap(320), 3);
      expect(NiumaPlayerPool.computeCapacityForHeap(447), 3);
      expect(NiumaPlayerPool.computeCapacityForHeap(448), 4);
      expect(NiumaPlayerPool.computeCapacityForHeap(1024), 4);
    });
  });

  group('acquire', () {
    test('同 key 命中复用，不重复建 controller', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));

      final c1 = await pool.acquire(_src('https://x/a.mp4'));
      final c2 = await pool.acquire(_src('https://x/a.mp4'));

      expect(identical(c1, c2), isTrue);
      expect(factoryCalls, 1);

      await pool.dispose();
    });

    test('不同 key 建新 controller', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));

      final c1 = await pool.acquire(_src('https://x/a.mp4'));
      final c2 = await pool.acquire(_src('https://x/b.mp4'));

      expect(identical(c1, c2), isFalse);
      expect(factoryCalls, 2);

      await pool.dispose();
    });

    test('超容量时按 LRU evict 最旧条目并 dispose', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        capacity: 2,
      );

      final a = await pool.acquire(_src('https://x/a.mp4'));
      await pool.acquire(_src('https://x/b.mp4'));
      // touch a 让 b 成为最旧的
      await pool.acquire(_src('https://x/a.mp4'));
      // release b 让它成为可回收的 inactive 条目；active 条目不能被容量回收。
      pool.release('https://x/b.mp4');
      // 第三个 key 超容量 → 应 evict b（最旧），a 保活
      await pool.acquire(_src('https://x/c.mp4'));
      // evict 的 dispose 是 unawaited，让其 dispose 链（含 stream 订阅
      // cancel）跑完再断言。
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // a 的 backend 没被 dispose
      expect(bf.created[0].disposed, isFalse);
      // b 的 backend 被 dispose
      expect(bf.created[1].disposed, isTrue);
      // a 仍是池里同一实例（命中，不重建）
      final aAgain = await pool.acquire(_src('https://x/a.mp4'));
      expect(identical(a, aAgain), isTrue);

      await pool.dispose();
    });

    test('容量满且全是 active 时 acquire 新 key 不 dispose 当前 active', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        capacity: 1,
      );

      await pool.acquire(_src('https://x/a.mp4'));
      await pool.acquire(_src('https://x/b.mp4'));

      expect(bf.created.length, 2);
      expect(bf.created[0].disposed, isFalse,
          reason: 'active controller must not be evicted by a new acquire');
      expect(bf.created[1].disposed, isFalse);

      await pool.dispose();
    });

    test('initialize 失败会清理坏 entry，后续 acquire 可重新创建', () async {
      var attempt = 0;
      final bf = _FakeFactory(
        makeBackend: () {
          final current = attempt++;
          return _FakeBackend(
            initBlock: current == 0
                ? () async => throw StateError('init failed')
                : null,
          );
        },
      );
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));
      final source = _src('https://x/a.mp4');

      await expectLater(pool.acquire(source), throwsStateError);
      expect(pool.holds('https://x/a.mp4'), isFalse);
      expect(bf.created.single.disposed, isTrue);

      final c = await pool.acquire(source);
      expect(c, isA<NiumaPlayerController>());
      expect(factoryCalls, 2);
      expect(bf.created.length, 2);

      await pool.dispose();
    });
  });

  group('preload', () {
    test('preload 未 await 时立刻 acquire：等同一 init，不拿半成品也不重建',
        () async {
      // 回归：插入 entry 与赋 pending 若隔着 await，acquire 会命中
      // pending==null 的半成品直接返回未初始化 controller。
      final initGate = Completer<void>();
      var initDone = false;
      final bf = _FakeFactory(
        makeBackend: () => _FakeBackend(initBlock: () async {
          await initGate.future;
          initDone = true;
        }),
      );
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));
      final source = _src('https://x/a.mp4');

      final preloading = pool.preload(source); // 故意不 await
      final acquiring = pool.acquire(source);

      initGate.complete();
      final c = await acquiring;
      await preloading;

      expect(initDone, isTrue,
          reason: 'acquire 必须等 preload 的 initialize 完成');
      expect(c, isA<NiumaPlayerController>());
      expect(factoryCalls, 1, reason: '并发同 key 不得重复建 controller');

      await pool.dispose();
    });

    test('preload 后 init 完立刻 pause，acquire 命中不重建', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));

      await pool.preload(_src('https://x/a.mp4'));
      expect(factoryCalls, 1);
      // preload 对刚建好的 backend 调了 pause
      expect(bf.created.single.pauseCalled, isTrue);

      await pool.acquire(_src('https://x/a.mp4'));
      // 命中预加载，没有重建
      expect(factoryCalls, 1);

      await pool.dispose();
    });

    test('已在池则跳过', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));

      await pool.acquire(_src('https://x/a.mp4'));
      await pool.preload(_src('https://x/a.mp4'));
      expect(factoryCalls, 1);

      await pool.dispose();
    });

    test('capacity=1 且当前页 active 时 preload 跳过，不 dispose 当前页', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        capacity: 1,
      );

      await pool.acquire(_src('https://x/a.mp4'));
      await pool.preload(_src('https://x/b.mp4'));

      expect(factoryCalls, 1);
      expect(bf.created.single.disposed, isFalse);
      expect(pool.holds('https://x/a.mp4'), isTrue);
      expect(pool.holds('https://x/b.mp4'), isFalse);

      await pool.dispose();
    });

    test('preload initialize 失败会清理坏 entry，后续 preload 可重试', () async {
      var attempt = 0;
      final bf = _FakeFactory(
        makeBackend: () {
          final current = attempt++;
          return _FakeBackend(
            initBlock: current == 0
                ? () async => throw StateError('preload failed')
                : null,
          );
        },
      );
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));
      final source = _src('https://x/a.mp4');

      await expectLater(pool.preload(source), throwsStateError);
      expect(pool.holds('https://x/a.mp4'), isFalse);
      expect(bf.created.single.disposed, isTrue);

      await pool.preload(source);
      expect(pool.holds('https://x/a.mp4'), isTrue);
      expect(factoryCalls, 2);
      expect(bf.created.length, 2);

      await pool.dispose();
    });
  });

  group('evict', () {
    test('立刻 dispose 指定条目并从池移除', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));

      await pool.acquire(_src('https://x/a.mp4'));
      await pool.evict('https://x/a.mp4');

      expect(pool.holds('https://x/a.mp4'), isFalse);
      expect(bf.created.single.disposed, isTrue);

      await pool.dispose();
    });

    test('active 条目也可被显式 evict', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));

      await pool.acquire(_src('https://x/a.mp4'));
      await pool.evict('https://x/a.mp4');
      await pool.acquire(_src('https://x/a.mp4'));

      expect(factoryCalls, 2);
      expect(bf.created.first.disposed, isTrue);
      expect(bf.created.last.disposed, isFalse);

      await pool.dispose();
    });
  });

  group('stale 清理', () {
    // 用真实事件循环 + 极短 staleDuration：fakeAsync 不能完整 drain
    // controller.dispose 里 broadcast stream 订阅 cancel 的调度，所以这里
    // 走真定时器，等过期周期跑过后断言。
    test('过期且已 release 的条目被 dispose 并移除', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        staleDuration: const Duration(milliseconds: 40),
      );

      await pool.acquire(_src('https://x/a.mp4'));
      pool.release('https://x/a.mp4'); // 标记可回收

      // 等过 staleDuration + 一个清理周期（period = staleDuration/2 = 20ms）。
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(bf.created.single.disposed, isTrue);

      await pool.dispose();
    });

    test('active（持有中、未 release）条目跨过期周期也不被清', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        staleDuration: const Duration(milliseconds: 40),
      );

      await pool.acquire(_src('https://x/a.mp4'));
      // 不 release → 仍 active，等清理周期跑过也不该被 dispose
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(bf.created.single.disposed, isFalse);

      await pool.dispose();
    });
  });

  test('dispose 停 timer 并清空所有 controller', () async {
    final bf = _FakeFactory();
    final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));

    await pool.acquire(_src('https://x/a.mp4'));
    await pool.acquire(_src('https://x/b.mp4'));
    await pool.dispose();

    expect(bf.created[0].disposed, isTrue);
    expect(bf.created[1].disposed, isTrue);
  });

  group('持有计数（同 key 多个持有者）', () {
    test('两个持有者各 acquire 一次，一个 release 后另一个仍受 LRU 保护', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf), capacity: 2);

      final a1 = await pool.acquire(_src('https://x/a.mp4'));
      final a2 = await pool.acquire(_src('https://x/a.mp4'));
      expect(identical(a1, a2), isTrue);
      pool.release('https://x/a.mp4'); // 持有者 1 走了，持有者 2 还在用

      await pool.acquire(_src('https://x/b.mp4'));
      await pool.acquire(_src('https://x/c.mp4')); // 超容，需要找 victim

      expect(bf.created[0].disposed, isFalse,
          reason: 'a 仍被一个消费者持有，不能被当作 inactive 淘汰');
      expect(pool.holds('https://x/a.mp4'), isTrue);

      await pool.dispose();
    });

    test('所有持有者都 release 之后才有资格被淘汰', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf), capacity: 2);

      await pool.acquire(_src('https://x/a.mp4'));
      await pool.acquire(_src('https://x/a.mp4'));
      pool.release('https://x/a.mp4');
      pool.release('https://x/a.mp4');

      await pool.acquire(_src('https://x/b.mp4'));
      await pool.acquire(_src('https://x/c.mp4'));

      expect(bf.created[0].disposed, isTrue, reason: '无人持有的 a 是 LRU victim');
      expect(pool.holds('https://x/a.mp4'), isFalse);

      await pool.dispose();
    });

    test('一个持有者 release 后另一个仍在，stale 清理也不碰它', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        staleDuration: const Duration(milliseconds: 40),
      );

      await pool.acquire(_src('https://x/a.mp4'));
      await pool.acquire(_src('https://x/a.mp4'));
      pool.release('https://x/a.mp4');
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(bf.created.single.disposed, isFalse);

      await pool.dispose();
    });

    test('多余的 release 不会让计数变负（下一次 acquire 仍算持有）', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf), capacity: 2);

      await pool.acquire(_src('https://x/a.mp4'));
      pool.release('https://x/a.mp4');
      pool.release('https://x/a.mp4'); // 多余的一次
      await pool.acquire(_src('https://x/a.mp4')); // 重新持有

      await pool.acquire(_src('https://x/b.mp4'));
      await pool.acquire(_src('https://x/c.mp4'));

      expect(bf.created[0].disposed, isFalse,
          reason: '重新 acquire 之后 a 是持有中，不该因之前多 release 一次而被淘汰');

      await pool.dispose();
    });
  });

  group('缓存 key', () {
    test('同 URL 不同 headers 视为不同条目，不误复用鉴权信息', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));

      final c1 = await pool.acquire(NiumaMediaSource.single(NiumaDataSource.network(
          'https://x/a.mp4',
          headers: {'Authorization': 'Bearer A'})));
      final c2 = await pool.acquire(NiumaMediaSource.single(NiumaDataSource.network(
          'https://x/a.mp4',
          headers: {'Authorization': 'Bearer B'})));

      expect(identical(c1, c2), isFalse);
      expect(factoryCalls, 2);

      await pool.dispose();
    });

    test('headers 内容相同、顺序不同 → 同一条目', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));

      final c1 = await pool.acquire(NiumaMediaSource.single(NiumaDataSource.network(
          'https://x/a.mp4',
          headers: {'A': '1', 'B': '2'})));
      final c2 = await pool.acquire(NiumaMediaSource.single(NiumaDataSource.network(
          'https://x/a.mp4',
          headers: {'B': '2', 'A': '1'})));

      expect(identical(c1, c2), isTrue);
      expect(factoryCalls, 1);

      await pool.dispose();
    });

    test('network 且无 headers 时默认 key 就是 URL（向后兼容裸 URL 调用方）', () {
      expect(NiumaPlayerPool.keyFor(_src('https://x/a.mp4')), 'https://x/a.mp4');
    });

    test('可注入自定义 keyBuilder，keyOf 与 release/holds 用同一套 key', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        keyBuilder: (s) => 'video:${Uri.parse(s.currentLine.source.uri).pathSegments.last}',
      );

      final c1 = await pool.acquire(_src('https://cdn1/a.mp4'));
      final c2 = await pool.acquire(_src('https://cdn2/a.mp4'));
      expect(identical(c1, c2), isTrue, reason: '自定义 key 认为是同一条视频');
      expect(pool.keyOf(_src('https://cdn2/a.mp4')), 'video:a.mp4');
      expect(pool.holds('video:a.mp4'), isTrue);

      await pool.dispose();
    });
  });

  group('dispose 之后', () {
    test('acquire / preload 抛 StateError 且不再建 controller', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));
      await pool.dispose();

      await expectLater(pool.acquire(_src('https://x/a.mp4')), throwsStateError);
      await expectLater(pool.preload(_src('https://x/b.mp4')), throwsStateError);
      expect(factoryCalls, 0, reason: 'dispose 后建出来的 controller 永远无人回收');
      expect(bf.created, isEmpty);
    });

    test('release / evict / holds 是安全的空操作', () async {
      final bf = _FakeFactory();
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));
      await pool.acquire(_src('https://x/a.mp4'));
      await pool.dispose();

      expect(() => pool.release('https://x/a.mp4'), returnsNormally);
      await expectLater(pool.evict('https://x/a.mp4'), completes);
      expect(pool.holds('https://x/a.mp4'), isFalse);
    });
  });

  group('同 key 换代（ABA）', () {
    test('preload 被 evict 后同 key 已有新 entry：迟到的失败回调不得删掉新 entry',
        () async {
      final initGate = Completer<void>();
      var created = 0;
      final bf = _FakeFactory(makeBackend: () {
        final index = created++;
        // 只有第一只（旧 preload 的）backend 被卡住。
        return _FakeBackend(initBlock: index == 0 ? () => initGate.future : null);
      });
      final pool = NiumaPlayerPool(controllerFactory: factoryWith(bf));
      const key = 'https://x/a.mp4';

      // 旧 preload 卡在 init 里。
      final stalePreload = pool.preload(_src(key));
      final stalePreloadOutcome = expectLater(stalePreload, throwsStateError);
      await Future<void>.delayed(Duration.zero);

      // 主动 evict 淘汰它（controller 被 dispose，init 链之后才会失败）。
      await pool.evict(key);

      // 同 key 立刻建了新 entry 并就绪——这是用户正在用的实例。
      final fresh = await pool.acquire(_src(key));

      // 旧 preload 的 init 此刻才 settle → 其失败回调不得动同 key 的新 entry。
      initGate.complete();
      await stalePreloadOutcome;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(pool.holds(key), isTrue,
          reason: '迟到的失败回调删掉的必须只能是自己那个 entry');
      expect(bf.created[1].disposed, isFalse,
          reason: '新 entry 的 backend 不得被旧回调误 dispose');
      expect(identical(await pool.acquire(_src(key)), fresh), isTrue,
          reason: '新 entry 仍在池中命中');

      await pool.dispose();
    });

    test('init 还在途的 preload 不当 LRU victim；无可回收 victim 时 preload 跳过',
        () async {
      final initGate = Completer<void>();
      var created = 0;
      final bf = _FakeFactory(makeBackend: () {
        final index = created++;
        return _FakeBackend(initBlock: index == 0 ? () => initGate.future : null);
      });
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        capacity: 1,
      );

      final preloadA = pool.preload(_src('https://x/a.mp4'));
      await Future<void>.delayed(Duration.zero);

      // 容量已满、唯一条目还在 init：preload(B) 不得把它挤掉，应静默跳过。
      await pool.preload(_src('https://x/b.mp4'));
      expect(pool.holds('https://x/b.mp4'), isFalse,
          reason: '无可回收 victim 时 preload 跳过');
      expect(bf.created.single.disposed, isFalse,
          reason: 'init 中的 preload 不得被 evict 打断（白干一次拉起还触发 ABA）');

      initGate.complete();
      await preloadA;
      expect(pool.holds('https://x/a.mp4'), isTrue);

      await pool.dispose();
    });

    test('旧 acquire 失败的迟到回调不得扣减同 key 新 entry 的持有计数', () async {
      final initGate = Completer<void>();
      var created = 0;
      final bf = _FakeFactory(makeBackend: () {
        final index = created++;
        return _FakeBackend(initBlock: index == 0 ? () => initGate.future : null);
      });
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        capacity: 1,
      );
      const key = 'https://x/a.mp4';

      // 旧 acquire 卡在 init。
      final staleAcquire = pool.acquire(_src(key));
      final staleOutcome = expectLater(staleAcquire, throwsStateError);
      await Future<void>.delayed(Duration.zero);

      // 强制 evict（连同它的持有计数一起清掉），同 key 重新 acquire 并持有。
      await pool.evict(key);
      await pool.acquire(_src(key));

      // 旧 init 此刻才失败：它的持有计数早随 evict 清掉了，不得再按 key
      // 扣一次——那会扣到新 entry 持有者头上。
      initGate.completeError(StateError('boom'));
      await staleOutcome;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 新 key 触发 LRU：被持有的新 entry 不能成为 victim。
      await pool.acquire(_src('https://x/b.mp4'));
      expect(bf.created[1].disposed, isFalse,
          reason: '持有计数被旧回调误扣的话，正在使用的新 entry 会被 LRU 回收');
      expect(pool.holds(key), isTrue);

      await pool.dispose();
    });
  });

  group('stale 清理', () {
    test('init 还在途的条目不算 stale，不被 sweep 中途销毁', () async {
      final initGate = Completer<void>();
      final bf = _FakeFactory(
        makeBackend: () => _FakeBackend(initBlock: () => initGate.future),
      );
      final pool = NiumaPlayerPool(
        controllerFactory: factoryWith(bf),
        staleDuration: const Duration(milliseconds: 40),
      );

      final preloadA = pool.preload(_src('https://x/a.mp4'));
      // 远超 staleDuration，sweep 已跑过多轮。
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(bf.created.single.disposed, isFalse,
          reason: '慢 init 不是 stale，sweep 不得把它中途销毁');

      initGate.complete();
      await preloadA; // 老代码：controller 已被 sweep dispose，这里抛 StateError

      await pool.dispose();
    });
  });

  group('keyFor 的 headers 处理', () {
    test('header 值不进 key 原文；同 URL 不同凭据仍分池', () {
      NiumaMediaSource src(Map<String, String> headers) => NiumaMediaSource
          .single(NiumaDataSource.network('https://x/a.mp4', headers: headers));

      final k1 =
          NiumaPlayerPool.keyFor(src({'Authorization': 'Bearer secret-token-1'}));
      final k2 =
          NiumaPlayerPool.keyFor(src({'Authorization': 'Bearer secret-token-2'}));

      expect(k1, isNot(contains('secret-token-1')),
          reason: 'key 会被调用方持有、还会进池的异常信息，凭据不得落进原文');
      expect(k1, isNot(equals(k2)),
          reason: '同 URL 不同鉴权不能错误复用同一个 controller');
    });

    test('k=v; 裸拼接的键值碰撞已修复', () {
      NiumaMediaSource src(Map<String, String> headers) => NiumaMediaSource
          .single(NiumaDataSource.network('https://x/a.mp4', headers: headers));

      final merged = NiumaPlayerPool.keyFor(src({'a': '1;b=2'}));
      final split = NiumaPlayerPool.keyFor(src({'a': '1', 'b': '2'}));
      expect(merged, isNot(equals(split)));
    });
  });
}
