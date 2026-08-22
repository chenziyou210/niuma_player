/// PiP EventChannel 进程级单 listener bus，各 backend 共用。
///
/// 直接各自 listen/cancel 有 race：第二次 listen 覆盖 native sink，旧
/// sub.cancel 报 `No active stream to cancel`（不在 await 链上，抓不到）。
/// 故整进程只 listen 一次 root channel，backend 只在 Dart 侧注册回调，
/// dispose 不向 native 发 cancel。
///
/// **归属（owner）**：native 事件本身不带播放器身份（Android 的 PiP 是
/// Activity 级，native 无法归属到某个播放器），归属在 Dart 侧维护——
/// backend 发起进入 PiP 时 [claimPipOwnership]，`pipStopped` / `pipFailed`
/// 结束会话时自动释放。有 owner 时事件只投给 owner；无 owner（宿主绕过
/// SDK 自行进 PiP）**恰好一个订阅者才投递**——单实例宿主兼容保留，多实例
/// 下无主会话归属不明，丢弃防串台（onResume 兜底纠正状态）。多实例
/// （播放器池 / feed）场景由 owner 路由保证不串台：别的播放器退 PiP
/// 不会把正在播的实例暂停。
///
/// 顶替 claim（A 还在 PiP 中时 B 进入）走一格交接窗口：顶替后的第一条
/// `pipStopped` 归前任，新会话的 `pipStarted` 关窗并给前任补退出事件；
/// backend dispose 不释放归属（tombstone），死 owner 的事件丢弃而非回退
/// 广播。连续多次顶替超出一格的部分由 controller 的 onResume 兜底。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'package:niuma_player/src/domain/player_state.dart';

const EventChannel _rawPipEventChannel =
    EventChannel('niuma_player/pip/events');

// 持有 root sub 的引用避免 GC；进程存活期内永不 cancel（见库注释）。
StreamSubscription<dynamic>? _pipEventBusRoot;

/// owner token → 事件回调。
final Map<Object, void Function(NiumaPlayerEvent event)> _pipSubscribers =
    <Object, void Function(NiumaPlayerEvent event)>{};

/// 当前 PiP 会话的发起者；null = 没有 Dart 侧发起的会话（广播模式）。
Object? _pipOwner;

/// 顶替 claim 时的前任 owner。native 换会话的顺序是 stop-old → start-new：
/// 顶替之后到达的第一条 `pipStopped` 属于**前任**的会话，要投给它而不是
/// 新 owner；新会话的 `pipStarted` 到达即关闭交接窗口（此时给前任补一条
/// 退出事件，防 stop-old 丢失时旧播放器卡在 PiP 态）。只留一格：连续
/// 多次顶替时更早的前任交给 controller 的 onResume 兜底。
Object? _prevPipOwner;

/// 声明 [owner] 发起了 PiP 会话。进入 PiP 前乐观调用，失败时
/// [releasePipOwnership] 回滚。已有其他活 owner 时进入交接窗口，
/// 见 [_prevPipOwner]。
void claimPipOwnership(Object owner) {
  final current = _pipOwner;
  if (current != null && !identical(current, owner)) {
    _prevPipOwner = current;
  }
  _pipOwner = owner;
}

/// 释放 [owner] 的会话归属；[owner] 不是当前 owner 时只清理它可能占的
/// 前任格（不能误释放别人刚 claim 的会话）。当前 owner 的释放（进入
/// 失败回滚）会把归属还给交接窗口里的前任——它的会话还活着。
void releasePipOwnership(Object owner) {
  if (identical(_pipOwner, owner)) {
    _pipOwner = _prevPipOwner;
    _prevPipOwner = null;
  } else if (identical(_prevPipOwner, owner)) {
    _prevPipOwner = null;
  }
}

/// PiP 会话的执行者换代：**仅当**当前 owner 已注销（tombstone，无人接
/// 事件）时，把会话交给 [to]——PiP 中 load() 换源 / switchLine / IJK 兜底
/// 会重建 backend，系统会话（尤其 Android Activity 级）还在继续，不收养
/// 的话遥控与 `pipStopped` 全被 tombstone 丢弃。会话本身没变，**不走**
/// 顶替 claim 的交接窗口。活 owner 不可被抢：别的实例拿着 stale 的
/// "在 PiP 中"标志调进来时必须是空操作。
void adoptOrphanedPipSession(Object to) {
  final owner = _pipOwner;
  if (owner == null) return;
  if (identical(owner, to)) return;
  if (_pipSubscribers.containsKey(owner)) return;
  _pipOwner = to;
}

/// 当前会话归属（null = 广播模式）——仅供测试断言。
@visibleForTesting
Object? get debugPipOwner => _pipOwner;

/// [subscribePipEvents] 的注册句柄。
class PipEventRegistration {
  PipEventRegistration._(this._owner);

  final Object _owner;

  /// 反注册回调。幂等。
  ///
  /// **不释放归属**：backend dispose 时系统 PiP 会话可能还活着（feed 划走
  /// 正在 PiP 的播放器、PiP 中 load() 重建 backend），立刻释放会让后续
  /// `pipStarted` / `playPauseToggle` 掉进无 owner 的广播分支串台。归属保留
  /// 为 tombstone：死 owner 的事件被丢弃，直到 `pipStopped` / `pipFailed`
  /// 结束会话清场（或新的 claim 顶替）。
  void cancel() {
    _pipSubscribers.remove(_owner);
  }
}

/// 注册 [owner] 的 PiP 事件回调——首次注册时 lazy 起 root listener。
/// native map 事件统一在 root 解析成 [NiumaPlayerEvent] 后按归属投递
/// （vp / native 两 backend 共用同一份解析）。错误静默（PiP 不可用时
/// root channel 也可能 error）。
PipEventRegistration subscribePipEvents(
  void Function(NiumaPlayerEvent event) add, {
  required Object owner,
}) {
  _pipSubscribers[owner] = add;
  _pipEventBusRoot ??= _rawPipEventChannel.receiveBroadcastStream().listen(
        _dispatchRawPipEvent,
        onError: (Object error, StackTrace stack) {/* 静默忽略 */},
      );
  return PipEventRegistration._(owner);
}

void _dispatchRawPipEvent(dynamic data) {
  if (data is! Map) return;
  final event = data['event'];
  if (event is! String) return;
  switch (event) {
    case 'pipStarted':
      // 新会话确认开始：关闭交接窗口。前任的 stop-old 要么已投递、要么
      // 不会再来——补一条退出事件让旧播放器确定性地离开 PiP 态。
      final prev = _prevPipOwner;
      _prevPipOwner = null;
      if (prev != null && !identical(prev, _pipOwner)) {
        _pipSubscribers[prev]?.call(const PipModeChanged(isInPip: false));
      }
      _deliver(const PipModeChanged(isInPip: true), endsSession: false);
    case 'pipStopped':
      final prev = _prevPipOwner;
      if (prev != null) {
        // 顶替后的第一条 stop 属于前任的会话（native 顺序 stop-old →
        // start-new）：投给前任，新会话的归属不受影响。
        _prevPipOwner = null;
        _pipSubscribers[prev]?.call(const PipModeChanged(isInPip: false));
        return;
      }
      _deliver(const PipModeChanged(isInPip: false), endsSession: true);
    case 'pipFailed':
      final reason = data['reason'];
      _deliver(
        PipStartFailed(reason: reason is String ? reason : null),
        endsSession: true,
      );
    case 'playPauseToggle':
      _deliver(
        const PipRemoteAction(action: 'playPauseToggle'),
        endsSession: false,
      );
    default:
      return;
  }
}

void _deliver(NiumaPlayerEvent event, {required bool endsSession}) {
  final owner = _pipOwner;
  // 先按当前归属算好收件人，再清归属——反过来的话，会话结束事件清完
  // 归属会掉进广播分支，串台照旧。owner 已 dispose（tombstone）时查不到
  // 回调 → 事件丢弃，绝不回退广播。
  //
  // 无 owner（宿主绕过 SDK 自行进 PiP）：**恰好一个订阅者才投递**——单实例
  // 宿主的兼容行为保留；多实例下无主会话归属不明，广播会把所有实例翻进
  // PiP 态、遥控让全体一起播放/暂停（守卫也拦不住已翻真的实例），丢弃
  // 交给 onResume 兜底。
  final targets = owner == null
      ? (_pipSubscribers.length == 1
          ? List.of(_pipSubscribers.values)
          : const <void Function(NiumaPlayerEvent event)>[])
      : <void Function(NiumaPlayerEvent event)>[
          if (_pipSubscribers[owner] case final cb?) cb,
        ];
  if (endsSession && owner != null) {
    // pipStopped 走到这里时交接窗口已关（prev 分支在上游短路），直接清场；
    // pipFailed 是新 claim 的失败，会话（若有）还给交接窗口里的前任。
    _pipOwner = _prevPipOwner;
    _prevPipOwner = null;
  }
  for (final cb in targets) {
    cb(event);
  }
}

/// 测试注入原始 native 事件，走与 root listener 相同的解析 + 归属投递。
@visibleForTesting
void debugDispatchRawPipEvent(dynamic data) => _dispatchRawPipEvent(data);

/// 清空注册表与归属（不动 root listener，它进程存活期内常驻）——仅供测试隔离。
@visibleForTesting
void debugResetPipEventBus() {
  _pipSubscribers.clear();
  _pipOwner = null;
  _prevPipOwner = null;
}
