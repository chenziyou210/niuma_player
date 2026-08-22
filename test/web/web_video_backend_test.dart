@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';
import 'package:niuma_player/src/data/web_video_backend.dart';
import 'package:web/web.dart' as web;

/// 往 window 上装一个假的 `Hls` 构造器：记录每个实例、不发任何网络请求。
/// Chrome 有 MSE、vendor 不是 Apple，所以 `.m3u8` 源一定走 hls.js 路径，
/// `<video>` 的 src 不会被设置，也就不会因为假 URL 触发 error 事件。
void installFakeHls() {
  globalContext.callMethod(
    'eval'.toJS,
    r'''
    window.__niumaHls = [];
    window.Hls = class {
      constructor(cfg) {
        this.cfg = cfg; this.destroyed = false; this.handlers = {};
        this.src = null; window.__niumaHls.push(this);
      }
      static isSupported() { return true; }
      on(ev, cb) { this.handlers[ev] = cb; }
      attachMedia(v) { this.media = v; }
      loadSource(u) { this.src = u; }
      destroy() { this.destroyed = true; }
      fireFatal(type, details) {
        const cb = this.handlers['hlsError'];
        if (cb) cb('hlsError', { fatal: true, type: type, details: details });
      }
    };
    '''
        .toJS,
  );
}

JSArray<JSObject> get _hlsInstances =>
    globalContext.getProperty('__niumaHls'.toJS) as JSArray<JSObject>;

int get hlsCount => _hlsInstances.length;

JSObject hlsAt(int i) => _hlsInstances[i];

String? hlsSrc(JSObject hls) =>
    (hls.getProperty('src'.toJS) as JSString?)?.toDart;

bool hlsDestroyed(JSObject hls) =>
    (hls.getProperty('destroyed'.toJS) as JSBoolean).toDart;

void hlsFireFatal(JSObject hls, String type, String details) =>
    hls.callMethod('fireFatal'.toJS, type.toJS, details.toJS);

/// 用 defineProperty 在实例上覆盖只读的 duration / readyState，
/// 再派发 `loadedmetadata`——不需要真媒体就能让 backend 认为元数据到了。
void fakeMetadata(web.HTMLVideoElement v,
    {required double duration, int readyState = 1}) {
  (globalContext.getProperty('Object'.toJS) as JSObject).callMethod(
    'defineProperty'.toJS,
    v as JSObject,
    'duration'.toJS,
    _getterDescriptor(duration.toJS),
  );
  (globalContext.getProperty('Object'.toJS) as JSObject).callMethod(
    'defineProperty'.toJS,
    v as JSObject,
    'readyState'.toJS,
    _getterDescriptor(readyState.toJS),
  );
  v.dispatchEvent(web.Event('loadedmetadata'));
}

JSObject _getterDescriptor(JSAny value) {
  final d = JSObject();
  d.setProperty('configurable'.toJS, true.toJS);
  d.setProperty('get'.toJS, (() => value).toJS);
  return d;
}

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Matcher get superseded => throwsA(isA<StateError>()
    .having((e) => e.toString(), 'message', contains('superseded')));

NiumaDataSource hls(String name, {Map<String, String>? headers}) =>
    NiumaDataSource.network('https://example.invalid/$name.m3u8',
        headers: headers);

void main() {
  setUp(installFakeHls);

  group('直播（duration = Infinity）', () {
    test('loadedmetadata 带 Infinity duration 即视为初始化完成，value.duration 为 0',
        () async {
      final backend = WebVideoBackend(hls('live'));
      final init = backend.initialize();
      await settle();
      fakeMetadata(backend.htmlVideoElement, duration: double.infinity);

      await init.timeout(const Duration(seconds: 2));
      expect(backend.value.phase, PlayerPhase.ready);
      expect(backend.value.duration, Duration.zero);

      await backend.dispose();
    });
  });

  group('load() 代际', () {
    /// 把 hls.js 的"脚本加载"接缝卡住，制造 load 之间的异步空隙。
    late Map<String, Completer<void>> gates;
    late int loaderCalls;

    Future<void> gatedLoader() {
      loaderCalls++;
      final c = Completer<void>();
      gates['#$loaderCalls'] = c;
      return c.future;
    }

    setUp(() {
      gates = {};
      loaderCalls = 0;
    });

    test('快速连续 load(A) / load(B)，A 的脚本加载后返回：只建 B 的 Hls，A 以 superseded 结束',
        () async {
      final backend = WebVideoBackend(hls('init'), hlsJsLoader: gatedLoader);
      final init = backend.initialize();
      await settle();
      gates['#1']!.complete();
      await settle();
      fakeMetadata(backend.htmlVideoElement, duration: 10);
      await init;
      final hlsBefore = hlsCount;

      final loadA = backend.load(hls('a'));
      final loadAOutcome = expectLater(loadA, superseded);
      await settle();
      final loadB = backend.load(hls('b'));
      await settle();

      gates['#3']!.complete(); // B 先回来
      await settle();
      gates['#2']!.complete(); // A 后回来——此时绝不能再建 Hls
      await settle();
      fakeMetadata(backend.htmlVideoElement, duration: 20);
      await loadB.timeout(const Duration(seconds: 2));
      await loadAOutcome;

      expect(hlsCount - hlsBefore, 1, reason: '只有 B 应该建 Hls 实例');
      expect(hlsSrc(hlsAt(hlsCount - 1)), hls('b').uri);
      expect(backend.value.phase, PlayerPhase.ready);

      await backend.dispose();
    });

    test('initialize() 还没完成就 load()：initialize 以 superseded 结束，新源正常就绪',
        () async {
      final backend = WebVideoBackend(hls('init'), hlsJsLoader: gatedLoader);
      final init = backend.initialize();
      final initOutcome = expectLater(init, superseded);
      await settle();

      final load = backend.load(hls('b'));
      await settle();
      gates['#2']!.complete();
      await settle();
      gates['#1']!.complete();
      await settle();
      fakeMetadata(backend.htmlVideoElement, duration: 20);

      await load.timeout(const Duration(seconds: 2));
      await initOutcome;
      expect(hlsCount, 1, reason: '被压倒的 initialize 不得建 Hls');
      expect(hlsSrc(hlsAt(0)), hls('b').uri);

      await backend.dispose();
    });

    test('换源后，旧 Hls 实例迟到的 fatal 错误不影响新源', () async {
      final backend = WebVideoBackend(hls('a'));
      final init = backend.initialize();
      await settle();
      fakeMetadata(backend.htmlVideoElement, duration: 10);
      await init;
      final oldHls = hlsAt(hlsCount - 1);

      final load = backend.load(hls('b'));
      await settle();
      expect(hlsDestroyed(oldHls), isTrue);

      hlsFireFatal(oldHls, 'networkError', 'late error from old instance');
      await settle();

      fakeMetadata(backend.htmlVideoElement, duration: 20);
      await load.timeout(const Duration(seconds: 2));
      expect(backend.value.phase, PlayerPhase.ready,
          reason: '旧实例的错误不该把新源打成 error');

      await backend.dispose();
    });
  });

  group('initialize 前元数据已就绪（构造期已设 src 的缓存命中）', () {
    test('metadata 先于 initialize 到达：initialize 仍能完成，不永挂到 initTimeout',
        () async {
      final backend = WebVideoBackend(hls('cached'));
      // 构造函数已挂好事件监听；模拟极快就绪（缓存命中）的媒体在
      // initialize 之前就触发 metadata——once-only 标记在此被提前消耗。
      fakeMetadata(backend.htmlVideoElement, duration: 10);
      await settle();

      final init = backend.initialize();
      await settle();
      // initialize 重新触发的 metadata 必须还能完成本代 completer。
      fakeMetadata(backend.htmlVideoElement, duration: 10);

      await init.timeout(const Duration(seconds: 2));
      expect(backend.value.phase, PlayerPhase.ready);
      await backend.dispose();
    });
  });

  group('过期 DOM 事件', () {
    test('元素无 error 状态时的裸 error 事件（旧源过期事件）不得把当前源打成 error',
        () async {
      final backend = WebVideoBackend(hls('stale-error'));
      final init = backend.initialize();
      await settle();
      fakeMetadata(backend.htmlVideoElement, duration: 10);
      await init.timeout(const Duration(seconds: 2));
      expect(backend.value.phase, PlayerPhase.ready);

      // load() 换源会清 error 属性并按 spec 移除排队中的媒体任务；模拟仍有
      // 一条旧 error 事件穿过来：此刻 video.error == null，即证明它已过期。
      backend.htmlVideoElement.dispatchEvent(web.Event('error'));
      await settle();

      expect(backend.value.phase, PlayerPhase.ready,
          reason: '过期的 error 事件不得覆盖当前源的状态');
      await backend.dispose();
    });

    test('load 换源后旧 metadata 事件到达而新源未就绪：不得误完成新源', () async {
      final backend = WebVideoBackend(hls('gen-a'));
      final init = backend.initialize();
      await settle();
      fakeMetadata(backend.htmlVideoElement, duration: 10);
      await init.timeout(const Duration(seconds: 2));

      final load = backend.load(hls('gen-b'));
      await settle();
      // 新源元数据未到（duration 回到 NaN）；旧源的 loadedmetadata 此刻穿过来。
      fakeMetadata(backend.htmlVideoElement, duration: double.nan, readyState: 0);
      await settle();

      var loadDone = false;
      unawaited(load.then((_) => loadDone = true));
      await settle();
      expect(loadDone, isFalse,
          reason: '现场读 readyState/duration 的守卫：旧事件不得完成新源的 completer');

      // 新源真正就绪后正常完成。
      fakeMetadata(backend.htmlVideoElement, duration: 20);
      await load.timeout(const Duration(seconds: 2));
      expect(backend.value.duration, const Duration(seconds: 20));
      await backend.dispose();
    });
  });

  group('headers', () {
    test('非 hls.js 路径传 headers 不再把 crossOrigin 设成 anonymous', () async {
      final backend = WebVideoBackend(NiumaDataSource.network(
        'https://example.invalid/a.mp4',
        headers: {'Authorization': 'Bearer x'},
      ));
      expect(backend.htmlVideoElement.crossOrigin, isNull,
          reason: '<video> 本来就发不出自定义 header；anonymous 只会让没配 CORS 的'
              '服务器拒掉本来能播的 mp4，还会丢 cookie');
      await backend.dispose();
    });

    test('hls.js 路径的 headers 经 xhrSetup 注入', () async {
      final backend = WebVideoBackend(
        hls('auth', headers: {'Authorization': 'Bearer x'}),
      );
      final init = backend.initialize();
      await settle();
      final cfg = hlsAt(hlsCount - 1).getProperty('cfg'.toJS) as JSObject;
      expect(cfg.has('xhrSetup'), isTrue);
      fakeMetadata(backend.htmlVideoElement, duration: 10);
      await init;
      await backend.dispose();
    });
  });
}
