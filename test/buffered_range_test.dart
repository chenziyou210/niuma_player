import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/src/data/buffered_range.dart';

/// 已缓冲区间 → bufferedPosition 换算——纯函数，VM 上跑。
void main() {
  Duration s(num seconds) => Duration(milliseconds: (seconds * 1000).round());
  BufferedRange r(num start, num end) => (start: s(start), end: s(end));

  group('bufferedEndAt', () {
    test('回归：拖到后面再拖回开头，取包含当前位置的那段，不是最后一段', () {
      // Safari / hls.js 保留 seek 前后两段：[0, 30] 与 [480, 510]。
      // 此前取 buffered 末段末尾 = 510，播到 16 秒灰条铺到 8 分钟。
      final ranges = [r(0, 30), r(480, 510)];
      expect(bufferedEndAt(ranges, s(16)), s(30));
    });

    test('当前位置落在后一段里 → 后一段末尾', () {
      final ranges = [r(0, 30), r(480, 510)];
      expect(bufferedEndAt(ranges, s(490)), s(510));
    });

    test('没有任何一段包含当前位置 → 返回当前位置（前方零缓冲）', () {
      final ranges = [r(0, 30), r(480, 510)];
      expect(bufferedEndAt(ranges, s(200)), s(200));
    });

    test('空区间列表 → 返回当前位置', () {
      expect(bufferedEndAt(const [], s(7)), s(7));
    });

    test('seek 落点比分片起点早不到半秒仍算包含', () {
      // HLS 按分片对齐：seek 到 100.0，区间从 100.04 开始。
      expect(bufferedEndAt([r(100.04, 130)], s(100)), s(130));
      // 差得多了就不算：那是另一段。
      expect(bufferedEndAt([r(101, 130)], s(100)), s(100));
    });

    test('相邻两段之间的小缝隙视为连续，跨过去取合并后的末尾', () {
      // MSE 偶发 buffer hole：[0, 100] 与 [100.2, 200]。
      expect(bufferedEndAt([r(0, 100), r(100.2, 200)], s(50)), s(200));
      // 缝隙超过半秒就是真断开。
      expect(bufferedEndAt([r(0, 100), r(101, 200)], s(50)), s(100));
    });

    test('输入乱序也能找对', () {
      final ranges = [r(480, 510), r(0, 30)];
      expect(bufferedEndAt(ranges, s(16)), s(30));
    });
  });
}
