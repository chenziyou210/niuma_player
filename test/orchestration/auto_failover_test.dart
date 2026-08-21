// 被测 API 已弃用但仍导出，行为测试保留到移除为止。
// ignore_for_file: deprecated_member_use_from_same_package, deprecated_member_use

// test/orchestration/auto_failover_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/src/domain/data_source.dart';
import 'package:niuma_player/src/domain/player_state.dart';
import 'package:niuma_player/src/orchestration/auto_failover.dart';
import 'package:niuma_player/src/orchestration/multi_source.dart';

void main() {
  test('picks next priority line on network error', () {
    final lines = [
      MediaLine(
        id: 'a',
        label: 'A',
        priority: 0,
        source: NiumaDataSource.network('https://a'),
      ),
      MediaLine(
        id: 'b',
        label: 'B',
        priority: 1,
        source: NiumaDataSource.network('https://b'),
      ),
    ];
    final orch = AutoFailoverOrchestrator(
      lines: lines,
      policy: const MultiSourcePolicy.autoFailover(maxAttempts: 1),
    );
    expect(orch.nextLine(currentId: 'a', category: PlayerErrorCategory.network),
        'b');
  });

  test('does NOT switch on codecUnsupported', () {
    final lines = [
      MediaLine(id: 'a', label: 'A', source: NiumaDataSource.network('a')),
      MediaLine(id: 'b', label: 'B', source: NiumaDataSource.network('b')),
    ];
    final orch = AutoFailoverOrchestrator(
      lines: lines,
      policy: const MultiSourcePolicy.autoFailover(),
    );
    expect(
        orch.nextLine(
            currentId: 'a', category: PlayerErrorCategory.codecUnsupported),
        isNull);
  });

  test('returns null after maxAttempts reached', () {
    final lines = [
      MediaLine(id: 'a', label: 'A', source: NiumaDataSource.network('a')),
      MediaLine(id: 'b', label: 'B', source: NiumaDataSource.network('b')),
    ];
    final orch = AutoFailoverOrchestrator(
      lines: lines,
      policy: const MultiSourcePolicy.autoFailover(maxAttempts: 1),
    );
    orch.recordFailover();
    expect(orch.nextLine(currentId: 'a', category: PlayerErrorCategory.network),
        isNull);
  });
}
