import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/src/data/web_media_readiness.dart';

/// `<video>` 元数据就绪判定——纯函数，VM 上跑。
/// readyState：0 HAVE_NOTHING / 1 HAVE_METADATA / 2 HAVE_CURRENT_DATA …
void main() {
  group('isWebMediaReady', () {
    test('duration 为 NaN（还没拿到元数据）→ 未就绪', () {
      expect(isWebMediaReady(duration: double.nan, readyState: 0), isFalse);
      expect(isWebMediaReady(duration: double.nan, readyState: 1), isFalse);
    });

    test('有限正 duration（点播）→ 就绪', () {
      expect(isWebMediaReady(duration: 12.5, readyState: 1), isTrue);
    });

    test('duration 为 0 → 未就绪（空源 / 坏源）', () {
      expect(isWebMediaReady(duration: 0, readyState: 1), isFalse);
    });

    test('duration 为 Infinity（直播 HLS）且已有元数据 → 就绪，不能等到超时',
        () {
      expect(isWebMediaReady(duration: double.infinity, readyState: 1), isTrue);
      expect(isWebMediaReady(duration: double.infinity, readyState: 4), isTrue);
    });

    test('duration 为 Infinity 但 readyState 还是 HAVE_NOTHING → 未就绪', () {
      expect(isWebMediaReady(duration: double.infinity, readyState: 0), isFalse);
    });
  });

  group('webDurationToValue', () {
    test('有限秒数 → 毫秒 Duration', () {
      expect(webDurationToValue(1.5), const Duration(milliseconds: 1500));
    });

    test('Infinity / NaN（直播 / 未知）→ Duration.zero，不抛', () {
      expect(webDurationToValue(double.infinity), Duration.zero);
      expect(webDurationToValue(double.nan), Duration.zero);
    });
  });
}
