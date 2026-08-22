import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';

void main() {
  group('NiumaDataSource.toString', () {
    test('不回显 header 值（Authorization 等凭据脱敏），仍可见 header 名', () {
      final ds = NiumaDataSource.network(
        'https://x/a.mp4',
        headers: {'Authorization': 'Bearer secret-token'},
      );
      final s = ds.toString();
      expect(s, isNot(contains('secret-token')),
          reason: 'toString 会进异常链和日志，凭据不得回显');
      expect(s, contains('Authorization'));
      expect(s, contains('https://x/a.mp4'));
    });

    test('无 headers 时照常打印 null', () {
      final ds = NiumaDataSource.network('https://x/a.mp4');
      expect(ds.toString(), contains('headers: null'));
    });

    test('uri 的 query 段脱敏（签名 token 不回显），路径保留', () {
      final ds = NiumaDataSource.network(
        'https://cdn.example.com/v/a.m3u8?token=SECRET123&expires=999',
      );
      final s = ds.toString();
      expect(s, isNot(contains('SECRET123')),
          reason: '签名 URL 的 token 在 query 里，不得随 toString 进日志');
      expect(s, contains('https://cdn.example.com/v/a.m3u8'));
      expect(s, contains('<2 params>'));
    });

    test('无 query 的 uri 原样输出', () {
      final ds = NiumaDataSource.network('https://x/a.mp4');
      expect(ds.toString(), contains('uri: https://x/a.mp4,'));
    });
  });
}
