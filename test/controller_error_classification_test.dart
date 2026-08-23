import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';

import 'helpers/fakes.dart';

/// 端到端验证：内核的平台错误模式表驱动 controller 的重试 / 回退决策——
/// kit 侧读 `value.error.category` / `FallbackTriggered.errorCategory`
/// 即可，不做文本嗅探。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final src = NiumaDataSource.network('https://x/a.mp4');

  test('vp 抛自由文本 PlatformException(Source error)：归类 network 驱动重试成功',
      () async {
    var attempt = 0;
    final factory = FakeBackendFactory(
      makeVideoPlayer: (_) => FakePlayerBackend(
        kind: PlayerBackendKind.videoPlayer,
        initBlock: () async {
          // 首次拉起模拟 Android 断网真机串，重试后成功。
          if (attempt++ == 0) {
            throw PlatformException(
              code: 'VideoError',
              message: 'ExoPlaybackException: Source error, null, null',
            );
          }
        },
      ),
    );
    final ctrl = NiumaPlayerController(
      NiumaMediaSource.single(src),
      retryPolicy: const RetryPolicy.exponential(
        base: Duration.zero, // 测试零延迟
        maxAttempts: 1,
      ),
      platform: FakePlatformBridge(isIOS: true),
      backendFactory: factory,
    );

    // 此前 PlatformException 落 unknown → 不重试 → 这里直接抛错。
    await ctrl.initialize();
    expect(attempt, 2, reason: 'network 分类必须触发一次重试');
    expect(ctrl.value.phase, isNot(PlayerPhase.error));

    await ctrl.dispose();
  });

  test('终局失败时 value.error.category 携带模式表的归类结果', () async {
    final factory = FakeBackendFactory(
      makeVideoPlayer: (_) => FakePlayerBackend(
        kind: PlayerBackendKind.videoPlayer,
        initBlock: () async {
          throw PlatformException(
            code: 'VideoError',
            message: 'ExoPlaybackException: Source error, null, null',
          );
        },
      ),
    );
    final ctrl = NiumaPlayerController(
      NiumaMediaSource.single(src),
      retryPolicy: const RetryPolicy.none(),
      platform: FakePlatformBridge(isIOS: true),
      backendFactory: factory,
    );

    await expectLater(ctrl.initialize(), throwsA(isA<PlatformException>()));
    expect(ctrl.value.phase, PlayerPhase.error);
    expect(ctrl.value.error?.category, PlayerErrorCategory.network,
        reason: 'kit 的分类文案读这里——此前恒为 unknown 通用兜底');

    await ctrl.dispose();
  });
}
