import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';
import 'package:niuma_player/src/data/native_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NativeBackend 初始化失败的结构化分类', () {
    test('prepare 前的 native error：initialize 以携带 Kotlin 结构化分类的错误失败',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const global = MethodChannel('cn.niuma/player');
      const events = EventChannel('cn.niuma/player/events/7');
      messenger.setMockMethodCallHandler(global, (call) async {
        switch (call.method) {
          case 'create':
            return <String, dynamic>{
              'textureId': 7,
              'isPlatformView': false,
              'selectedVariant': 'ijk',
            };
          case 'dispose':
            return null;
        }
        return null;
      });
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(onListen: (arguments, sink) {
          // 对齐 Kotlin PlayerSession 的事件形状：errorCategory 是独立的
          // 结构化字段（真机断网抓包里它同时被格式化进了 message 文本）。
          sink.success(<String, dynamic>{
            'phase': 'error',
            'positionMs': 0,
            'durationMs': 0,
            'errorCode': '-10000',
            'errorMessage':
                'IjkMediaPlayer error what=-10000 extra=0 pos=0/0ms',
            'errorCategory': 'network',
          });
        }),
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(global, null);
        messenger.setMockStreamHandler(events, null);
      });

      final backend =
          NativeBackend(NiumaDataSource.network('https://x/a.mp4'));
      await expectLater(
        backend.initialize(),
        throwsA(isA<PlayerError>()
            .having((e) => e.category, 'category', PlayerErrorCategory.network)
            .having((e) => e.code, 'code', '-10000')),
        reason: '此前这里重新包裸 PlatformException，Kotlin 已算好的 '
            'category=network 被扔进 message 文本，_categorize 取不到 → '
            'unknown → 断网不重试',
      );
      await backend.dispose();
    });
  });

  group('NativeBackend PiP channel 协议', () {
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

    test('enterPictureInPicture 不传 textureId（Android Activity 级别）', () async {
      final r = await channel.invokeMethod<bool>('enterPictureInPicture', {
        'aspectNum': 16,
        'aspectDen': 9,
      });
      expect(r, isTrue);
      expect(calls.first.method, 'enterPictureInPicture');
      expect(calls.first.arguments['aspectNum'], 16);
      expect(calls.first.arguments['aspectDen'], 9);
      expect(calls.first.arguments.containsKey('textureId'), isFalse,
          reason: 'Android PiP 是 Activity 级别，不需要 textureId');
    });

    test('exitPictureInPicture 不传参数', () async {
      final r = await channel.invokeMethod<bool>('exitPictureInPicture');
      expect(r, isTrue);
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
