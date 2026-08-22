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
/// SDK 自行进 PiP）保持广播，兼容单实例旧行为。多实例（播放器池 / feed）
/// 场景由 owner 路由保证不串台：别的播放器退 PiP 不会把正在播的实例暂停。
///
/// 已知限制：A 还在 PiP 中时 B 直接 claim 会顶替归属（系统层同一时刻只有
/// 一个 PiP 会话，这么做的宿主本身就在换会话），A 丢失的 `pipStopped` 由
/// controller 的 onResume 兜底翻回 stale 状态。
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

/// 声明 [owner] 发起了 PiP 会话。进入 PiP 前乐观调用，失败时
/// [releasePipOwnership] 回滚。
void claimPipOwnership(Object owner) => _pipOwner = owner;

/// 释放 [owner] 的会话归属；[owner] 不是当前 owner 时为空操作
/// （不能误释放别人刚 claim 的会话）。
void releasePipOwnership(Object owner) {
  if (identical(_pipOwner, owner)) _pipOwner = null;
}

/// [subscribePipEvents] 的注册句柄。
class PipEventRegistration {
  PipEventRegistration._(this._owner);

  final Object _owner;

  /// 反注册回调并释放 [_owner] 可能持有的会话归属。幂等。
  void cancel() {
    _pipSubscribers.remove(_owner);
    releasePipOwnership(_owner);
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
  final NiumaPlayerEvent mapped;
  var endsSession = false;
  switch (event) {
    case 'pipStarted':
      mapped = const PipModeChanged(isInPip: true);
    case 'pipStopped':
      mapped = const PipModeChanged(isInPip: false);
      endsSession = true;
    case 'pipFailed':
      final reason = data['reason'];
      mapped = PipStartFailed(reason: reason is String ? reason : null);
      endsSession = true;
    case 'playPauseToggle':
      mapped = const PipRemoteAction(action: 'playPauseToggle');
    default:
      return;
  }
  final owner = _pipOwner;
  // 先按当前归属算好收件人，再释放归属——反过来的话，会话结束事件释放
  // 归属后会掉进广播分支，串台照旧。
  final targets = owner == null
      ? List.of(_pipSubscribers.values)
      : <void Function(NiumaPlayerEvent event)>[
          if (_pipSubscribers[owner] case final cb?) cb,
        ];
  if (endsSession && owner != null) _pipOwner = null;
  for (final cb in targets) {
    cb(mapped);
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
}
