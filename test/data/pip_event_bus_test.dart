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

    // 会话已结束、无人 claim → 广播（宿主绕过 SDK 自行进 PiP 的兼容行为）。
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStarted'});
    expect(gotA, hasLength(2));
    expect(gotB, hasLength(1));
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

    debugDispatchRawPipEvent(<String, Object?>{'event': 'playPauseToggle'});
    expect(gotB, hasLength(1), reason: '会话已结束，回到广播');
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

  test('cancel 反注册并释放归属；owner 已 dispose 后事件安全丢弃', () {
    final ownerA = Object();
    final gotA = <NiumaPlayerEvent>[];
    final reg = subscribePipEvents(gotA.add, owner: ownerA);

    claimPipOwnership(ownerA);
    reg.cancel();

    // owner 已注销：这条事件没有收件人，安全丢弃、不得崩。
    debugDispatchRawPipEvent(<String, Object?>{'event': 'pipStopped'});
    expect(gotA, isEmpty);
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
