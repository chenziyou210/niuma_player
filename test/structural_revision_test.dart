import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';

import 'helpers/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NiumaPlayerValue.structurallyEquals（结构字段清单的唯一事实源）', () {
    final base = NiumaPlayerValue.uninitialized();

    test('仅进度字段 / 版号本身变化 → 结构相等', () {
      expect(
        base.structurallyEquals(base.copyWith(
          position: const Duration(seconds: 1),
          bufferedPosition: const Duration(seconds: 2),
        )),
        isTrue,
      );
      expect(
        base.structurallyEquals(base.copyWith(structuralRevision: 5)),
        isTrue,
        reason: '版号本身不参与结构比较',
      );
    });

    test('每个结构字段单独翻动 → 结构不等（逐字段矩阵，兜底闸）', () {
      final mutations = <String, NiumaPlayerValue>{
        'phase': base.copyWith(phase: PlayerPhase.ready),
        'duration': base.copyWith(duration: const Duration(seconds: 10)),
        'size': base.copyWith(size: const Size(1280, 720)),
        'openingStage': base.copyWith(openingStage: 'openInput'),
        'error': base.copyWith(
          error: PlayerError(
            category: PlayerErrorCategory.network,
            message: 'x',
          ),
        ),
        'playbackSpeed': base.copyWith(playbackSpeed: 2.0),
        'isInPictureInPicture': base.copyWith(isInPictureInPicture: true),
        'isPictureInPictureSupported':
            base.copyWith(isPictureInPictureSupported: true),
      };
      mutations.forEach((field, mutated) {
        expect(base.structurallyEquals(mutated), isFalse,
            reason: '$field 是结构字段，翻动必须判不等');
      });
    });
  });

  group('controller 盖章 structuralRevision', () {
    test('初始化拉起递增；播放 tick 不递增；结构变化递增', () async {
      final factory = FakeBackendFactory();
      final ctrl = NiumaPlayerController(
        NiumaMediaSource.single(NiumaDataSource.network('https://x/a.mp4')),
        platform: FakePlatformBridge(isIOS: true),
        backendFactory: factory,
      );
      expect(ctrl.value.structuralRevision, 0);

      await ctrl.initialize();
      final backend = ctrl.backend! as FakePlayerBackend;
      final afterInit = ctrl.value.structuralRevision;
      expect(afterInit, greaterThan(0), reason: 'idle → ready 是结构变化');

      // 播放 tick：只有进度在动，版号不递增——上层据此跳过骨架重建。
      backend.simulatePosition(const Duration(seconds: 3));
      expect(ctrl.value.position, const Duration(seconds: 3));
      expect(ctrl.value.structuralRevision, afterInit,
          reason: '播放 tick 不得递增结构版号');
      backend.simulatePosition(const Duration(seconds: 4));
      expect(ctrl.value.structuralRevision, afterInit);

      // phase 变化：结构变化，递增一次。
      backend.emitValue(backend.value.copyWith(phase: PlayerPhase.playing));
      expect(ctrl.value.structuralRevision, afterInit + 1);

      // kit 侧的用法：比较版号即可判断"骨架要不要重建"。
      final skeletonRev = ctrl.value.structuralRevision;
      backend.simulatePosition(const Duration(seconds: 5));
      expect(ctrl.value.structuralRevision == skeletonRev, isTrue);

      await ctrl.dispose();
    });
  });
}
