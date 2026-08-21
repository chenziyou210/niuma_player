/// `<video>` 元数据就绪判定——纯函数，不依赖 web-only library，VM 单测可跑。
library;

/// HTMLMediaElement.readyState 的 HAVE_METADATA：元数据（时长 / 尺寸）已到。
const int _haveMetadata = 1;

/// 元数据是否已就绪，可把 backend 标成 initialized：
/// - 有限正 [duration]：点播，直接就绪；
/// - [duration] 为 Infinity：直播（Safari 原生 HLS / MediaSource 直播流），
///   只要 [readyState] 到了 HAVE_METADATA 就算就绪——否则会一直等到 initTimeout；
/// - NaN（还没拿到元数据）或 0（空源）：未就绪。
bool isWebMediaReady({required double duration, required int readyState}) {
  if (duration.isNaN) return false;
  if (duration.isInfinite) return readyState >= _haveMetadata;
  return duration > 0;
}

/// `<video>.duration`（秒）→ [Duration]。Infinity / NaN（直播 / 未知）映射为
/// [Duration.zero]——与 `NiumaPlayerValue.uninitialized()` 的约定一致，UI 据此
/// 隐藏总时长；不会像直接 `(d * 1000).round()` 那样对 Infinity 抛异常。
Duration webDurationToValue(double duration) {
  if (!duration.isFinite) return Duration.zero;
  return Duration(milliseconds: (duration * 1000).round());
}
