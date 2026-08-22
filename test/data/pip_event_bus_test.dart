import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';
import 'package:niuma_player/src/data/_pip_event_bus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(debugResetPipEventBus);

  test('有 owner 时事件只投给 owner，其他订阅者一条不收（多实例不串台）', () {
    final ownerA = Object();
    final ownerB = Object();
    final gotA = <NiumaPlayerEvent>[];
    final gotB = <NiumaPlayerEvent>[];
    subscribePipEvents(gotA.add, owner: ownerA);
    subscribePipEvents(gotB.add, owner: ownerB);

    claimPipOwnership(ownerA);
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStarted'});
    debugDispatchRawPipEvent(<String, Object?>{'event': 'playPauseToggle'});
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStopped'});

    expect(gotB, isEmpty,
        reason: '别的播放器的 PiP 会话事件不得广播给非 owner，'
            '否则 feed 多实例里其他正在播的 controller 会被 pipStopped 误暂停');
    expect(gotA, hasLength(3));
    expect((gotA[0] as PipModeChanged).isInPip, isTrue);
    expect(gotA[1], isA<PipRemoteAction>());
    expect((gotA[2] as PipModeChanged).isInPip, isFalse);
  });

  test('pipStopped 结束会话并释放归属：之后回到无 owner 的广播模式', () {
    final ownerA = Object();
    final ownerB = Object();
    final gotA = <NiumaPlayerEvent>[];
    final gotB = <NiumaPlayerEvent>[];
    subscribePipEvents(gotA.add, owner: ownerA);
    subscribePipEvents(gotB.add, owner: ownerB);

    claimPipOwnership(ownerA);
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStopped'});
    expect(gotA, hasLength(1));
    expect(gotB, isEmpty,
        reason: '结束会话的那条 pipStopped 本身必须仍按旧归属投递，'
            '不能先释放归属再投递（否则掉进广播分支，串台照旧）');

    // 会话已结束、无人 claim，且存在多个订阅者 → 无主事件归属不明，丢弃
    //（广播会把所有实例翻进 PiP 态，后续遥控让全体一起播放/暂停）。
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStarted'});
    expect(gotA, hasLength(1));
    expect(gotB, isEmpty);
  });

  test('无 owner：恰好一个订阅者才投递（单实例宿主兼容），多实例丢弃', () {
    final ownerA = Object();
    final gotA = <NiumaPlayerEvent>[];
    subscribePipEvents(gotA.add, owner: ownerA);

    // 单实例：宿主绕过 SDK 自行进 PiP 的旧行为保留。
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStarted'});
    expect(gotA, hasLength(1));

    // 第二个实例加入后，无主事件归属不明 → 全部丢弃。
    final ownerB = Object();
    final gotB = <NiumaPlayerEvent>[];
    subscribePipEvents(gotB.add, owner: ownerB);
    debugDispatchRawPipEvent(<String, Object?>{'event': 'playPauseToggle'});
    expect(gotA, hasLength(1));
    expect(gotB, isEmpty);
  });

  test('pipFailed 只投 owner 并结束会话', () {
    final ownerA = Object();
    final ownerB = Object();
    final gotA = <NiumaPlayerEvent>[];
    final gotB = <NiumaPlayerEvent>[];
    subscribePipEvents(gotA.add, owner: ownerA);
    subscribePipEvents(gotB.add, owner: ownerB);

    claimPipOwnership(ownerA);
    debugDispatchRawPipEvent(
        <String, Object?>{'event': 'pipFailed', 'reason': 'not possible'});
    expect(gotB, isEmpty);
    expect((gotA.single as PipStartFailed).reason, 'not possible');

    // 会话已结束；两个订阅者的无主事件按"多实例丢弃"规则不投递。
    debugDispatchRawPipEvent(<String, Object?>{'event': 'playPauseToggle'});
    expect(gotA, hasLength(1));
    expect(gotB, isEmpty);
  });

  test('releasePipOwnership 只允许当前 owner 释放，不能误释放别人刚 claim 的会话',
      () {
    final ownerA = Object();
    final ownerB = Object();
    final gotA = <NiumaPlayerEvent>[];
    final gotB = <NiumaPlayerEvent>[];
    subscribePipEvents(gotA.add, owner: ownerA);
    subscribePipEvents(gotB.add, owner: ownerB);

    claimPipOwnership(ownerB);
    releasePipOwnership(ownerA); // 不是 owner，必须是空操作
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStarted'});
    expect(gotA, isEmpty);
    expect(gotB, hasLength(1));
  });

  test('owner dispose（cancel）后归属保留为 tombstone：迟到事件丢弃而非回退广播',
      () {
    final ownerA = Object();
    final ownerB = Object();
    final gotA = <NiumaPlayerEvent>[];
    final gotB = <NiumaPlayerEvent>[];
    final regA = subscribePipEvents(gotA.add, owner: ownerA);
    subscribePipEvents(gotB.add, owner: ownerB);

    // A 在 PiP 中被 dispose（feed 划走 / load 重建），系统会话还活着。
    claimPipOwnership(ownerA);
    regA.cancel();

    // 会话未结束前的迟到事件：必须丢弃，不得广播给别的播放器——否则
    // playPauseToggle 会让所有实例一起播放/暂停。
    debugDispatchRawPipEvent(<String, Object?>{'event': 'playPauseToggle'});
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStarted'});
    expect(gotA, isEmpty);
    expect(gotB, isEmpty,
        reason: '死 owner 的会话事件不得回退成广播串台');

    // pipStopped 结束会话、清掉 tombstone → 之后恢复无 owner 的广播模式。
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStopped'});
    expect(gotB, isEmpty);
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStarted'});
    expect(gotB, hasLength(1));
  });

  group('顶替 claim 的交接窗口', () {
    test('顶替后的第一条 pipStopped 归前任；新会话不受影响', () {
      final ownerA = Object();
      final ownerB = Object();
      final gotA = <NiumaPlayerEvent>[];
      final gotB = <NiumaPlayerEvent>[];
      subscribePipEvents(gotA.add, owner: ownerA);
      subscribePipEvents(gotB.add, owner: ownerB);

      claimPipOwnership(ownerA);
      claimPipOwnership(ownerB); // B 顶替 A（native 顺序 stop-old → start-new）

      debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStopped'});
      expect((gotA.single as PipModeChanged).isInPip, isFalse,
          reason: '这条 stop 属于前任 A 的会话');
      expect(gotB, isEmpty);

      debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStarted'});
      debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStopped'});
      expect(gotA, hasLength(1));
      expect(gotB, hasLength(2), reason: '新会话的 started/stopped 归 B');
    });

    test('stop-old 丢失时，pipStarted 关窗并给前任补退出事件', () {
      final ownerA = Object();
      final ownerB = Object();
      final gotA = <NiumaPlayerEvent>[];
      final gotB = <NiumaPlayerEvent>[];
      subscribePipEvents(gotA.add, owner: ownerA);
      subscribePipEvents(gotB.add, owner: ownerB);

      claimPipOwnership(ownerA);
      claimPipOwnership(ownerB);

      debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStarted'});
      expect((gotA.single as PipModeChanged).isInPip, isFalse,
          reason: '合成退出事件让旧播放器确定性离开 PiP 态');
      expect((gotB.single as PipModeChanged).isInPip, isTrue);

      // 之后的 stop 属于 B 的新会话。
      debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStopped'});
      expect(gotA, hasLength(1));
      expect(gotB, hasLength(2));
    });

    test('顶替者进入失败（release）：归属还给仍在会话中的前任', () {
      final ownerA = Object();
      final ownerB = Object();
      final gotA = <NiumaPlayerEvent>[];
      final gotB = <NiumaPlayerEvent>[];
      subscribePipEvents(gotA.add, owner: ownerA);
      subscribePipEvents(gotB.add, owner: ownerB);

      claimPipOwnership(ownerA);
      claimPipOwnership(ownerB);
      releasePipOwnership(ownerB); // B 的 enterPictureInPicture 失败回滚

      debugDispatchRawPipEvent(<String, Object?>{'event': 'playPauseToggle'});
      expect(gotA, hasLength(1), reason: 'A 的会话还活着，遥控归 A');
      expect(gotB, isEmpty);
    });
  });

  group('孤儿会话收养（PiP 中重建 backend）', () {
    test('owner 已注销后新 backend 收养会话：遥控与 stop 都归它', () {
      final oldBackend = Object();
      final newBackend = Object();
      final gotNew = <NiumaPlayerEvent>[];
      final regOld = subscribePipEvents((_) {}, owner: oldBackend);
      claimPipOwnership(oldBackend);
      regOld.cancel(); // PiP 中 load() 重建：旧 backend dispose → tombstone

      subscribePipEvents(gotNew.add, owner: newBackend);
      adoptOrphanedPipSession(newBackend);
      expect(debugPipOwner, same(newBackend));

      debugDispatchRawPipEvent(<String, Object?>{'event': 'playPauseToggle'});
      expect(gotNew, hasLength(1),
          reason: '不收养的话，遥控会投给 tombstone 被丢弃');
      debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStopped'});
      expect((gotNew[1] as PipModeChanged).isInPip, isFalse);
    });

    test('活 owner 不可被收养抢走（防 stale 的"在 PiP 中"标志误夺会话）', () {
      final live = Object();
      final thief = Object();
      subscribePipEvents((_) {}, owner: live);
      subscribePipEvents((_) {}, owner: thief);
      claimPipOwnership(live);

      adoptOrphanedPipSession(thief);
      expect(debugPipOwner, same(live));
    });

    test('无会话时收养是空操作', () {
      final b = Object();
      subscribePipEvents((_) {}, owner: b);
      adoptOrphanedPipSession(b);
      expect(debugPipOwner, isNull);
    });
  });

  test('非法 payload（非 Map / 缺 event / 未知 event）安全忽略', () {
    final owner = Object();
    final got = <NiumaPlayerEvent>[];
    subscribePipEvents(got.add, owner: owner);

    debugDispatchRawPipEvent('not a map');
    debugDispatchRawPipEvent(<String, Object?>{'noEvent': 1});
    debugDispatchRawPipEvent(<String, Object?>{'event': 42});
    debugDispatchRawPipEvent(<String, Object?>{'event': 'unknownKind'});
    expect(got, isEmpty);
  });
}
