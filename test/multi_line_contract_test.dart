import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';

import 'helpers/fakes.dart';

/// 多线路契约：文档怎么说，controller 就得怎么做。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final srcA = NiumaDataSource.network('https://a');
  final srcB = NiumaDataSource.network('https://b');
  final srcC = NiumaDataSource.network('https://c');

  MediaLine line(String id, NiumaDataSource src, {int priority = 0}) =>
      MediaLine(id: id, label: id.toUpperCase(), source: src, priority: priority);

  /// 按 uri 决定 vp 是否失败的工厂；native 永远成功。
  FakeBackendFactory factoryWhereVpFails(bool Function(String uri) fails) =>
      FakeBackendFactory(
        makeVideoPlayer: (ds) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          initBlock: fails(ds.uri)
              ? () async => throw StateError('vp cannot play ${ds.uri}')
              : null,
        ),
      );

  List<String> urisOf(List<FakePlayerBackend> backends) =>
      backends.map((b) => b.source!.uri).toList();

  group('首播线路顺序', () {
    test('defaultLineId 不是最小 priority 时，首播仍然是默认线路', () async {
      final factory = FakeBackendFactory();
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.lines(
          lines: [
            line('x', srcA, priority: 0),
            line('y', srcB, priority: 1),
            line('z', srcC, priority: 2),
          ],
          defaultLineId: 'y',
        ),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();

      expect(urisOf(factory.videoPlayers), [srcB.uri],
          reason: '文档承诺"首播走 defaultLineId 线路"，不该先去试 priority 更小的 x');
      expect(ctrl.activeLineId, 'y');
      await ctrl.dispose();
    });

    test('默认线路失败后，其余线路按 priority 升序尝试', () async {
      final factory = factoryWhereVpFails((uri) => uri == srcB.uri);
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.lines(
          lines: [
            line('z', srcC, priority: 2),
            line('x', srcA, priority: 0),
            line('y', srcB, priority: 1),
          ],
          defaultLineId: 'y',
        ),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();

      expect(urisOf(factory.videoPlayers), [srcB.uri, srcA.uri],
          reason: '默认 y 先试，失败后轮到 priority 最小的 x，z 不用试');
      expect(ctrl.activeLineId, 'x');
      await ctrl.dispose();
    });
  });

  group('activeLineId / dataSource 必须指向实际在播的线路', () {
    test('failover 落到备线路后 dataSource 是备线路的源', () async {
      final factory = factoryWhereVpFails((uri) => uri == srcA.uri);
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.lines(
          lines: [line('a', srcA, priority: 0), line('b', srcB, priority: 1)],
          defaultLineId: 'a',
        ),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();

      expect(ctrl.activeLineId, 'b');
      expect(ctrl.dataSource.uri, srcB.uri,
          reason: 'dataSource 文档说是"当前激活线路的数据源"');
      await ctrl.dispose();
    });

    test('switchLine 成功后 dataSource 跟着切；回滚后回到原线路', () async {
      final factory = factoryWhereVpFails((uri) => uri == srcC.uri);
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.lines(
          lines: [line('a', srcA), line('b', srcB), line('c', srcC)],
          defaultLineId: 'a',
        ),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      expect(ctrl.dataSource.uri, srcA.uri);

      await ctrl.switchLine('b');
      expect(ctrl.activeLineId, 'b');
      expect(ctrl.dataSource.uri, srcB.uri);

      // c 起不来 → 默认 rollbackOnSwitchFailure 回滚到 b，不抛。
      await ctrl.switchLine('c');
      expect(ctrl.activeLineId, 'b');
      expect(ctrl.dataSource.uri, srcB.uri);
      await ctrl.dispose();
    });

    test('切换进行中 activeLineId 仍是在播线路，成功后才更新', () async {
      final factory = factoryWhereVpFails((uri) => uri == srcB.uri);
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.lines(
          lines: [line('a', srcA), line('b', srcB)],
          defaultLineId: 'a',
        ),
        retryPolicy: const RetryPolicy.none(),
        options: const NiumaPlayerOptions(rollbackOnSwitchFailure: false),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      final events = <NiumaPlayerEvent>[];
      final sub = ctrl.events.listen(events.add);

      await expectLater(ctrl.switchLine('b'), throwsStateError);
      expect(ctrl.activeLineId, 'a',
          reason: 'b 从未播起来，activeLineId 不能撒谎说是 b');
      expect(events.whereType<LineSwitching>().single.fromId, 'a');

      await sub.cancel();
      await ctrl.dispose();
    });
  });

  group('Android：本会话回退 IJK 后，切线沿用 IJK', () {
    NiumaMediaSource twoLines() => NiumaMediaSource.lines(
          lines: [line('a', srcA, priority: 0), line('b', srcB, priority: 1)],
          defaultLineId: 'a',
        );

    test('首播回退到 IJK 后，switchLine 不再试 video_player，直接用 IJK 拉目标线路',
        () async {
      final factory = factoryWhereVpFails((_) => true);
      final ctrl = NiumaPlayerController(
        twoLines(),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(),
        backendFactory: factory,
      );
      await ctrl.initialize();
      expect(ctrl.activeBackend, PlayerBackendKind.native);
      final vpAttemptsAfterInit = factory.videoPlayers.length;
      final events = <NiumaPlayerEvent>[];
      final sub = ctrl.events.listen(events.add);

      await ctrl.switchLine('b');

      expect(factory.videoPlayers.length, vpAttemptsAfterInit,
          reason: '这台设备本会话已证明 vp 播不了，切线不该再碰 vp');
      expect(urisOf(factory.nativePlayers).last, srcB.uri);
      expect(ctrl.activeBackend, PlayerBackendKind.native);
      expect(ctrl.activeLineId, 'b');
      expect(events.whereType<LineSwitched>().single.toId, 'b');
      expect(events.whereType<LineSwitchFailed>(), isEmpty);

      await sub.cancel();
      await ctrl.dispose();
    });

    test('首播走 vp 正常，但 switchLine 的目标线路 vp 起不来 → 切线内回退 IJK，不算失败',
        () async {
      final factory = factoryWhereVpFails((uri) => uri == srcB.uri);
      final ctrl = NiumaPlayerController(
        twoLines(),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(),
        backendFactory: factory,
      );
      await ctrl.initialize();
      expect(ctrl.activeBackend, PlayerBackendKind.videoPlayer);
      final events = <NiumaPlayerEvent>[];
      final sub = ctrl.events.listen(events.add);

      await ctrl.switchLine('b');

      expect(ctrl.activeBackend, PlayerBackendKind.native);
      expect(urisOf(factory.nativePlayers), [srcB.uri]);
      expect(ctrl.activeLineId, 'b');
      expect(events.whereType<FallbackTriggered>(), isNotEmpty);
      expect(events.whereType<LineSwitched>().single.toId, 'b');
      expect(events.whereType<LineSwitchFailed>(), isEmpty);

      // 回退过一次后，切回 a 也直接走 IJK。
      final vpBefore = factory.videoPlayers.length;
      await ctrl.switchLine('a');
      expect(factory.videoPlayers.length, vpBefore);
      expect(urisOf(factory.nativePlayers).last, srcA.uri);

      await sub.cancel();
      await ctrl.dispose();
    });

    test('load() 换新媒体后，IJK 记忆清零：新媒体的 switchLine 重新走 vp',
        () async {
      final srcD = NiumaDataSource.network('https://d');
      // 旧媒体 a/b 的 vp 都起不来；新媒体 c/d 的 vp 正常。
      final factory =
          factoryWhereVpFails((uri) => uri == srcA.uri || uri == srcB.uri);
      final ctrl = NiumaPlayerController(
        twoLines(),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(),
        backendFactory: factory,
      );
      await ctrl.initialize();
      expect(ctrl.activeBackend, PlayerBackendKind.native);

      await ctrl.load(NiumaMediaSource.lines(
        lines: [line('c', srcC), line('d', srcD)],
        defaultLineId: 'c',
      ));
      expect(ctrl.activeBackend, PlayerBackendKind.videoPlayer);
      final nativeBefore = factory.nativePlayers.length;

      await ctrl.switchLine('d');

      expect(ctrl.activeBackend, PlayerBackendKind.videoPlayer,
          reason: '新媒体 vp 已证明能播，切线不该被上一条媒体的回退记忆拖进软解');
      expect(factory.nativePlayers.length, nativeBefore);
      expect(urisOf(factory.videoPlayers).last, srcD.uri);
      await ctrl.dispose();
    });
  });

  group('NiumaMediaSource.lines 防御', () {
    test('重复的线路 id 在构造时就拒绝', () {
      expect(
        () => NiumaMediaSource.lines(
          lines: [line('a', srcA), line('a', srcB)],
          defaultLineId: 'a',
        ),
        throwsA(isA<ArgumentError>()
            .having((e) => e.name, 'name', 'lines')
            .having((e) => e.message, 'message', contains('duplicate'))),
      );
    });

    test('构造后外部改动传入的 List 不影响 source；lines 本身不可变', () {
      final input = [line('a', srcA), line('b', srcB)];
      final src = NiumaMediaSource.lines(lines: input, defaultLineId: 'a');

      input.clear();
      expect(src.lines.length, 2, reason: '@immutable 的类不能共享调用方的可变 List');
      expect(src.currentLine.id, 'a');
      expect(() => src.lines.add(line('c', srcC)), throwsUnsupportedError);
    });
  });
}
