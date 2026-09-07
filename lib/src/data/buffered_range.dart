/// 已缓冲区间 → 单一 `bufferedPosition` 的换算——纯函数，不依赖 web-only
/// library，VM 单测可跑。
library;

/// 一段已缓冲区间 [start, end]。
typedef BufferedRange = ({Duration start, Duration end});

/// 区间起点允许比当前位置晚这么多仍算「包含」：seek 落点与分片起点常差
/// 几十毫秒（HLS 按分片对齐），timeupdate 也可能先于 buffered 更新。
/// 相邻两段之间不超过这个缝隙也视为连续——MSE 偶发的 buffer hole，浏览器
/// 播放时自己会跳过去，进度条上不该断成两截。
const Duration _slack = Duration(milliseconds: 500);

/// 从若干（可能不连续的）已缓冲区间里，取**包含 [position] 的那一段**的
/// 末尾，并跨过与之相接的后续段。
///
/// 浏览器 / AVPlayer 会保留 seek 前后的多段区间：拖到后面再拖回开头，
/// `buffered` 里同时有 [0, 30s] 与 [8min, 8min30s] 两段。此前取「最后一段
/// 的末尾」，播到 16 秒灰条却铺到 8 分钟——远处那段从当前位置并不能连续
/// 播过去。没有任何一段包含 [position] 时返回 [position]（前方零缓冲）。
/// [ranges] 顺序不限。
Duration bufferedEndAt(Iterable<BufferedRange> ranges, Duration position) {
  final sorted = [...ranges]..sort((a, b) => a.start.compareTo(b.start));
  Duration? end;
  for (final r in sorted) {
    if (end == null) {
      if (r.start - _slack <= position && position <= r.end) end = r.end;
      continue;
    }
    if (r.start - _slack > end) break;
    if (r.end > end) end = r.end;
  }
  return end ?? position;
}
