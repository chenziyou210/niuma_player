import 'package:flutter/foundation.dart';
import 'package:niuma_player/niuma_player.dart';
import 'package:niuma_player/src/data/video_player_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VideoPlayerBackend PiP channel 协议', () {
    late List<MethodCall> calls;
    const channel = MethodChannel('niuma_player/pip');

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'enterPictureInPicture':
            return true;
          case 'exitPictureInPicture':
            return true;
          case 'queryPictureInPictureSupport':
            return true;
        }
        return false;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('Android backend 把 PiP 播放和暂停状态传给原生', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final backend =
          VideoPlayerBackend(NiumaDataSource.network('https://x/a.mp4'));
      addTearDown(backend.dispose);
      await backend.updatePictureInPictureActions(isPlaying: false);
      await backend.updatePictureInPictureActions(isPlaying: true);
      expect(calls.map((c) => c.method), [
        'updatePictureInPictureActions',
        'updatePictureInPictureActions',
      ]);
      expect(calls.map((c) => c.arguments['isPlaying']), [false, true]);
    });

    test('iOS backend 不发送 Android PiP action 更新', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final backend =
          VideoPlayerBackend(NiumaDataSource.network('https://x/a.mp4'));
      addTearDown(backend.dispose);
      await backend.updatePictureInPictureActions(isPlaying: false);
      expect(calls, isEmpty);
    });

    test('enterPictureInPicture 调 channel 带 textureId / aspectNum / aspectDen',
        () async {
      final r = await channel.invokeMethod<bool>('enterPictureInPicture', {
        'textureId': 7,
        'aspectNum': 16,
        'aspectDen': 9,
      });
      expect(r, isTrue);
      expect(calls, hasLength(1));
      expect(calls.first.method, 'enterPictureInPicture');
      expect(calls.first.arguments['textureId'], 7);
      expect(calls.first.arguments['aspectNum'], 16);
      expect(calls.first.arguments['aspectDen'], 9);
    });

    test('exitPictureInPicture 不传参数', () async {
      final r = await channel.invokeMethod<bool>('exitPictureInPicture');
      expect(r, isTrue);
      expect(calls, hasLength(1));
      expect(calls.first.method, 'exitPictureInPicture');
    });

    test('queryPictureInPictureSupport 不传参数', () async {
      final r =
          await channel.invokeMethod<bool>('queryPictureInPictureSupport');
      expect(r, isTrue);
      expect(calls.first.method, 'queryPictureInPictureSupport');
    });
  });
}
