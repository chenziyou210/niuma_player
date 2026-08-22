import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:niuma_player/src/domain/gesture_feedback_state.dart';
import 'package:niuma_player/src/domain/gesture_hud_icon.dart';
import 'package:niuma_player/src/domain/gesture_kind.dart';
import 'package:niuma_player/src/domain/player_state.dart';
import 'package:niuma_player/src/player/niuma_player_controller.dart';
import 'package:niuma_player/src/player/video_time_format.dart';

/// 视频手势的 headless 编排器：把手势几何量映射成播放意图 + HUD 反馈状态，
/// 不持有任何 widget 概念；接入方透传手势坐标、监听 [feedback] 渲染 HUD。
/// 手势：双击播放暂停、长按 2x 倍速、水平 pan seek、左/右半屏垂直 pan 亮度/音量。
class NiumaGestureController {
  /// 构造一个手势编排器，驱动给定 [player]。
  NiumaGestureController(this.player, {this.disabledGestures = const {}});

  /// 被驱动的 controller。
  final NiumaPlayerController player;

  /// 黑名单：不触发的手势类型。
  final Set<GestureKind> disabledGestures;

  final ValueNotifier<GestureFeedbackState?> _feedback =
      ValueNotifier<GestureFeedbackState?>(null);

  /// 当前手势 HUD 状态。null = 无手势进行中。
  ValueListenable<GestureFeedbackState?> get feedback => _feedback;

  GestureKind? _lockedKind;
  Offset _panStart = Offset.zero;
  Duration _seekStart = Duration.zero;
  double _origValue = 0.0;

  /// [_origValue] 是否已异步读回。锁定亮度/音量后、读回完成前的指针事件
  /// 直接丢弃——否则会拿 0.0 当基准把系统亮度/音量瞬间打到谷底。
  bool _origValueReady = false;

  /// 水平 seek 的最新目标；onPanEnd 直接提交它，不从 HUD 进度反算。
  Duration? _pendingSeekTarget;

  /// 手势序号：onPanStart / onPanEnd 递增。亮度 / 音量基准值经 method
  /// channel 异步读回，读回期间用户可能已松手甚至开始下一次手势——序号
  /// 不符的读数直接丢弃，既不能 `_lockedKind!`（已被 onPanEnd 清空）也不能
  /// 覆盖新手势的基准。
  int _gestureSeq = 0;

  double? _originalSpeed;
  Timer? _hideTimer;
  double? _initialBrightness;
  DateTime? _lastChannelSet;

  /// [dispose] 后置 true。亮度 / 音量基准值经 method channel 异步读回、
  /// HUD 隐藏走 Timer——两者都可能在 dispose 之后才回来，此时绝不能再碰
  /// 已释放的 [_feedback] notifier。
  bool _disposed = false;

  static const double _dragThreshold = 18;

  bool _isDisabled(GestureKind kind) => disabledGestures.contains(kind);

  /// 异步读初始亮度，[restoreBrightness] 时恢复。widget 在 init 时调一次。
  void initBrightness() {
    player.backend?.getBrightness().then((v) {
      _initialBrightness = v;
    });
  }

  void _showHud(GestureFeedbackState state) {
    if (_disposed) return;
    _feedback.value = state;
    _hideTimer?.cancel();
  }

  void _scheduleHide() {
    if (_disposed) return;
    _hideTimer = Timer(const Duration(milliseconds: 600), () {
      if (_disposed) return;
      _feedback.value = null;
    });
  }

  /// 双击 → 切播放 / 暂停。
  void onDoubleTap() {
    if (_disposed) return;
    if (_isDisabled(GestureKind.doubleTap)) return;
    final phase = player.value.phase;
    if (phase == PlayerPhase.playing) {
      player.pause();
      _showHud(const GestureFeedbackState(
        kind: GestureKind.doubleTap,
        progress: 1.0,
        label: '已暂停',
        hudIcon: GestureHudIcon.pause,
      ));
    } else {
      player.play();
      _showHud(const GestureFeedbackState(
        kind: GestureKind.doubleTap,
        progress: 1.0,
        label: '播放中',
        hudIcon: GestureHudIcon.play,
      ));
    }
    _scheduleHide();
  }

  /// 长按开始 → 临时 2x 倍速。
  void onLongPressStart() {
    if (_disposed) return;
    if (_isDisabled(GestureKind.longPressSpeed)) return;
    _originalSpeed = player.value.playbackSpeed;
    player.setPlaybackSpeed(2.0);
    _showHud(const GestureFeedbackState(
      kind: GestureKind.longPressSpeed,
      progress: 1.0,
      label: '2x 倍速',
      hudIcon: GestureHudIcon.speed,
    ));
  }

  /// 长按结束 → 恢复原倍速。
  void onLongPressEnd() {
    if (_disposed) return;
    final speed = _originalSpeed;
    if (speed != null) {
      player.setPlaybackSpeed(speed);
    }
    _originalSpeed = null;
    _scheduleHide();
  }

  /// pan 开始 → 记录起点，清锁定方向。[localPosition] 为手势相对视频区的坐标。
  void onPanStart(Offset localPosition) {
    if (_disposed) return;
    _panStart = localPosition;
    _seekStart = player.value.position;
    _lockedKind = null;
    _origValue = 0.0;
    _origValueReady = false;
    _pendingSeekTarget = null;
    _gestureSeq++;
  }

  /// 读当前系统亮度 / 音量作为本次手势的基准；不直接写字段，由调用方确认
  /// 手势仍然有效后再写。
  Future<double> _readOrigValue(GestureKind kind) async {
    final backend = player.backend;
    if (backend == null) return 0.0;
    if (kind == GestureKind.brightness) return backend.getBrightness();
    if (kind == GestureKind.volume) return backend.getSystemVolume();
    return 0.0;
  }

  /// pan 更新 → 首次过阈值时锁定方向（水平 seek / 左亮度 / 右音量），
  /// 之后按锁定方向更新。[size] 为视频区尺寸。
  Future<void> onPanUpdate(Offset localPosition, Size size) async {
    if (_disposed) return;
    final dx = localPosition.dx - _panStart.dx;
    final dy = localPosition.dy - _panStart.dy;

    if (_lockedKind == null) {
      if (dx.abs() < _dragThreshold && dy.abs() < _dragThreshold) return;
      if (dx.abs() > dy.abs()) {
        _lockedKind = GestureKind.horizontalSeek;
      } else {
        final isLeftHalf = _panStart.dx < size.width / 2;
        _lockedKind = isLeftHalf ? GestureKind.brightness : GestureKind.volume;
      }
      if (_isDisabled(_lockedKind!)) {
        _lockedKind = null;
        return;
      }
      final kind = _lockedKind!;
      final seq = _gestureSeq;
      final orig = await _readOrigValue(kind);
      // 读回期间松手 / 换了手势 / 整个 controller 已 dispose：
      // 这份读数作废，什么都别碰。
      if (_disposed || seq != _gestureSeq || _lockedKind != kind) return;
      _origValue = orig;
      _origValueReady = true;
    }

    // onPanEnd 可能在上面的 await 期间清掉它；到这里一定非空（要么没经过
    // await，要么刚通过序号校验）。
    final locked = _lockedKind;
    if (locked == null) return;
    switch (locked) {
      case GestureKind.horizontalSeek:
        final duration = player.value.duration;
        if (duration == Duration.zero) return;
        final seekDeltaMs =
            (dx / size.width * duration.inMilliseconds * 0.5).round();
        final target = _seekStart + Duration(milliseconds: seekDeltaMs);
        final clamped = Duration(
          milliseconds: target.inMilliseconds.clamp(0, duration.inMilliseconds),
        );
        _pendingSeekTarget = clamped;
        _showHud(GestureFeedbackState(
          kind: GestureKind.horizontalSeek,
          progress: clamped.inMilliseconds /
              duration.inMilliseconds.clamp(1, 1 << 30),
          label: '${seekDeltaMs >= 0 ? '+' : ''}${seekDeltaMs ~/ 1000}s '
              '/ ${formatVideoTime(clamped)} / ${formatVideoTime(duration)}',
          hudIcon: seekDeltaMs >= 0
              ? GestureHudIcon.seekForward
              : GestureHudIcon.seekBackward,
        ));
      case GestureKind.brightness:
      case GestureKind.volume:
        if (!_origValueReady) return;
        final newValue =
            (_origValue - (dy / (size.height * 0.5))).clamp(0.0, 1.0);
        // 节流 50ms
        final now = DateTime.now();
        final canSet = _lastChannelSet == null ||
            now.difference(_lastChannelSet!) >=
                const Duration(milliseconds: 50);
        if (canSet) {
          _lastChannelSet = now;
          final backend = player.backend;
          if (backend != null) {
            if (_lockedKind == GestureKind.brightness) {
              unawaited(backend.setBrightness(newValue));
            } else {
              unawaited(backend.setSystemVolume(newValue));
            }
          }
        }
        _showHud(GestureFeedbackState(
          kind: _lockedKind!,
          progress: newValue,
          label: '${(newValue * 100).round()}%',
          hudIcon: _lockedKind == GestureKind.brightness
              ? GestureHudIcon.brightness
              : (newValue == 0
                  ? GestureHudIcon.volumeMute
                  : GestureHudIcon.volume),
        ));
      case GestureKind.doubleTap:
      case GestureKind.longPressSpeed:
        break;
    }
  }

  /// pan 结束 → 水平 seek 时提交拖动中算好的目标位置。
  void onPanEnd() {
    if (_disposed) return;
    final target = _pendingSeekTarget;
    if (_lockedKind == GestureKind.horizontalSeek && target != null) {
      player.seekTo(target);
    }
    _pendingSeekTarget = null;
    _lockedKind = null;
    _gestureSeq++;
    _scheduleHide();
  }

  /// 释放：停 HUD 计时器、释放 [feedback] notifier，并把亮度恢复到
  /// [initBrightness] 读到的初值。幂等；此后所有手势入口与在途异步回调
  /// （亮度 / 音量读数、HUD 隐藏 Timer）都不再触碰已释放的 notifier。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _hideTimer?.cancel();
    restoreBrightness();
    _feedback.dispose();
  }

  /// 把屏幕亮度恢复到进入手势区前的初值（fire-and-forget）。
  void restoreBrightness() {
    final orig = _initialBrightness;
    if (orig != null) {
      player.backend?.setBrightness(orig);
    }
  }
}
