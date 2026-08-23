import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';
import 'package:niuma_player/src/data/platform_error_classifier.dart';

void main() {
  group('classifyThrownPlatformError', () {
    test('Android 真机断网实测串：ExoPlaybackException Source error → network',
        () {
      // 取自 kit ROADMAP 2.4 的真机抓包。
      final e = PlatformException(
        code: 'VideoError',
        message:
            'ExoPlaybackException: Source error, null, null',
      );
      expect(classifyThrownPlatformError(e), PlayerErrorCategory.network);
    });

    test('Exo HTTP 栈 / DNS / 超时 → network', () {
      for (final msg in const [
        'HttpDataSourceException: Unable to connect',
        'UnknownHostException: cdn.example.com',
        'InvalidResponseCodeException: Response code: 403',
        'SocketTimeoutException: timeout',
      ]) {
        expect(
          classifyThrownPlatformError(
              PlatformException(code: 'VideoError', message: msg)),
          PlayerErrorCategory.network,
          reason: msg,
        );
      }
    });

    test('iOS NSURLErrorDomain（断网 -1009 / 超时 -1001）→ network', () {
      for (final msg in const [
        "The operation couldn't be completed. (NSURLErrorDomain error -1009.)",
        'Failed: NSURLErrorDomain error -1001.',
      ]) {
        expect(
          classifyThrownPlatformError(
              PlatformException(code: 'VideoError', message: msg)),
          PlayerErrorCategory.network,
          reason: msg,
        );
      }
    });

    test('解码器失败 → codecUnsupported，且优先于同串里的 source 字样', () {
      for (final msg in const [
        'MediaCodecVideoRenderer error, index=0, format=..., '
            'DecoderInitializationException from source',
        'Decoder init failed: OMX.qcom.video.decoder.hevc',
        'Cannot Decode',
      ]) {
        expect(
          classifyThrownPlatformError(
              PlatformException(code: 'VideoError', message: msg)),
          PlayerErrorCategory.codecUnsupported,
          reason: msg,
        );
      }
    });

    test('认不出的文本 / 非平台异常 → null（调用方兜 unknown）', () {
      expect(
        classifyThrownPlatformError(
            PlatformException(code: 'VideoError', message: 'weird failure')),
        isNull,
      );
      expect(classifyThrownPlatformError(StateError('boom')), isNull);
      expect(
        classifyPlatformErrorText(code: null, message: null),
        isNull,
      );
    });
  });
}
