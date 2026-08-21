import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';

import 'helpers/fakes.dart';

/// 真机验收里抓到的问题：用户切到不可用线路时，候选 backend 在初始化阶段
/// 报出的 `phase=error` 泄漏进 `controller.value`，上层的"播放中途自动容灾"
/// 据此抢先又发起一次 switchLine，并且把位置 / 播放快照取自半成品
/// （0:00、未播放），回滚后播放器停在 0:00 暂停。
///
/// 契约：**切换失败 = 什么都没发生**。候选的 error 不进 value；位置 / 播放
/// 快照来自最近一次稳定状态，不受进行中的切换影响。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final srcA = NiumaDataSource.network('https://a');
  final srcB = NiumaDataSource.network('https://b');
  final srcC = NiumaDataSource.network('https://c');
  const pos53 = Duration(seconds: 53);

  NiumaPlayerValue playingAt(Duration pos) => NiumaPlayerValue(
        phase: PlayerPhase.playing,
        position: pos,
        duration: const Duration(minutes: 10),
        size: const Size(320, 180),
        bufferedPosition: pos,
      );

  NiumaPlayerValue errorValue() => NiumaPlayerValue.uninitialized().copyWith(
        phase: PlayerPhase.error,
        error: const PlayerError(
          category: PlayerErrorCategory.network,
          message: 'Unable to resolve host',
        ),
      );

  NiumaMediaSource threeLines() => NiumaMediaSource.lines(
        lines: [
          MediaLine(id: 'a', label: 'A', source: srcA),
          MediaLine(id: 'b', label: 'B', source: srcB),
          MediaLine(id: 'c', label: 'C', source: srcC),
        ],
        defaultLineId: 'a',
      );

  group('switchLine：候选 backend 的 error 不进 value', () {
    test('切换失败并回滚：全程 value.phase 不出现 error，回滚后 seek 回原位置并续播',
        () async {
      // b 线路：先像 vp 那样把 error 推进 valueStream，再抛出。
      FakePlayerBackend? bBackend;
      final factory2 = FakeBackendFactory(
        makeVideoPlayer: (ds) {
          if (ds.uri != srcB.uri) {
            return FakePlayerBackend(kind: PlayerBackendKind.videoPlayer);
          }
          late FakePlayerBackend b;
          b = FakePlayerBackend(
            kind: PlayerBackendKind.videoPlayer,
            initBlock: () async {
              b.emitValue(errorValue());
              throw StateError('Unable to resolve host');
            },
          );
          bBackend = b;
          return b;
        },
      );
      final ctrl = NiumaPlayerController(
        threeLines(),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory2,
      );
      await ctrl.initialize();
      final a = factory2.videoPlayers.single;
      a.emitValue(playingAt(pos53));
      expect(ctrl.value.position, pos53);

      final phases = <PlayerPhase>[];
      ctrl.addListener(() => phases.add(ctrl.value.phase));

      await ctrl.switchLine('b'); // 默认 rollbackOnSwitchFailure → 不抛

      expect(bBackend, isNotNull);
      expect(phases, isNot(contains(PlayerPhase.error)),
          reason: '候选线路的 error 不该泄漏进 value——上层会据此误触发自动容灾');
      expect(ctrl.activeLineId, 'a');
      final rebuiltA = factory2.videoPlayers.last;
      expect(rebuiltA.source?.uri, srcA.uri);
      expect(rebuiltA.lastSeekTarget, pos53, reason: '回滚要回到切换前的位置');
      expect(rebuiltA.playCalls, 1, reason: '切换前在播，回滚后要续播');
      await ctrl.dispose();
    });

    test('切换失败且禁用回滚：value 必须显式落到 error（因为候选的 error 被吞了）',
        () async {
      final factory = FakeBackendFactory(
        makeVideoPlayer: (ds) => FakePlayerBackend(
          kind: PlayerBackendKind.videoPlayer,
          initBlock: ds.uri == srcB.uri
              ? () async => throw StateError('Unable to resolve host')
              : null,
        ),
      );
      final ctrl = NiumaPlayerController(
        threeLines(),
        retryPolicy: const RetryPolicy.none(),
        options: const NiumaPlayerOptions(rollbackOnSwitchFailure: false),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      factory.videoPlayers.single.emitValue(playingAt(pos53));

      await expectLater(ctrl.switchLine('b'), throwsStateError);

      expect(ctrl.value.phase, PlayerPhase.error);
      expect(ctrl.value.error, isNotNull);
      await ctrl.dispose();
    });
  });

  group('switchLine：位置 / 播放快照取自稳定状态', () {
    test('第一次切换还在途（候选已把 value 打成 0:00 / 未播放）时再切一次：新目标仍回到 0:53 并续播',
        () async {
      final gate = Completer<void>();
      final factory = FakeBackendFactory(
        makeVideoPlayer: (ds) {
          if (ds.uri == srcB.uri) {
            late FakePlayerBackend b;
            b = FakePlayerBackend(
              kind: PlayerBackendKind.videoPlayer,
              initBlock: () async {
                // 像真 backend 一样先推一个 uninitialized（position 0、未播放）
                b.emitValue(NiumaPlayerValue.uninitialized());
                await gate.future;
              },
            );
            return b;
          }
          return FakePlayerBackend(kind: PlayerBackendKind.videoPlayer);
        },
      );
      final ctrl = NiumaPlayerController(
        threeLines(),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await ctrl.initialize();
      factory.videoPlayers.single.emitValue(playingAt(pos53));

      final toB = ctrl.switchLine('b');
      final toBOutcome = expectLater(toB, throwsStateError); // 被压倒
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.value.position, Duration.zero,
          reason: '前置条件：此刻 value 已是候选 b 的半成品状态');

      await ctrl.switchLine('c');
      gate.complete();
      await toBOutcome;

      final c = factory.videoPlayers.last;
      expect(c.source?.uri, srcC.uri);
      expect(c.lastSeekTarget, pos53,
          reason: '快照应取自稳定状态 0:53，而不是候选 b 的 0:00');
      expect(c.playCalls, 1, reason: '稳定状态在播，新线路要续播');
      await ctrl.dispose();
    });
  });

  group('initialize：候选遍历期间候选的 error 不进 value', () {
    test('默认线路候选推出 error 后失败、备线路成功：全程 value 不出现 error，最终 ready',
        () async {
      final factory = FakeBackendFactory(
        makeVideoPlayer: (ds) {
          if (ds.uri != srcA.uri) {
            return FakePlayerBackend(kind: PlayerBackendKind.videoPlayer);
          }
          late FakePlayerBackend a;
          a = FakePlayerBackend(
            kind: PlayerBackendKind.videoPlayer,
            initBlock: () async {
              a.emitValue(errorValue()); // vp 的 VideoError 会先推 error value
              throw StateError('MediaCodecVideoRenderer error');
            },
          );
          return a;
        },
      );
      final ctrl = NiumaPlayerController(
        threeLines(),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      final phases = <PlayerPhase>[];
      ctrl.addListener(() => phases.add(ctrl.value.phase));

      await ctrl.initialize();

      expect(phases, isNot(contains(PlayerPhase.error)),
          reason: '候选 a 的 error 在遍历期间不该进 value——UI 会先闪错误层再"自愈"');
      expect(ctrl.value.phase, PlayerPhase.ready);
      expect(ctrl.activeLineId, 'b');
      await ctrl.dispose();
    });

    test('全部候选失败：initialize 抛出且 value 落到 error', () async {
      final factory = FakeBackendFactory(
        makeVideoPlayer: (ds) {
          late FakePlayerBackend b;
          b = FakePlayerBackend(
            kind: PlayerBackendKind.videoPlayer,
            initBlock: () async {
              b.emitValue(errorValue());
              throw StateError('down');
            },
          );
          return b;
        },
      );
      final ctrl = NiumaPlayerController(
        threeLines(),
        retryPolicy: const RetryPolicy.none(),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      await expectLater(ctrl.initialize(), throwsStateError);
      expect(ctrl.value.phase, PlayerPhase.error);
      expect(ctrl.value.error, isNotNull);
      await ctrl.dispose();
    });
  });
}
