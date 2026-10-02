@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuma_player/niuma_player.dart';
import 'package:niuma_player/src/data/web_video_backend.dart';
import 'package:web/web.dart' as web;

// 模拟浏览器全屏 API 与事件，不依赖测试运行器的用户激活权限。
class FakeFullscreen {
  FakeFullscreen(this.video, {bool webkit = false}) {
    final descriptor = JSObject()
      ..setProperty('configurable'.toJS, true.toJS)
      ..setProperty('get'.toJS,
          (() => element == null ? null : documentHost ?? element).toJS);
    (globalContext.getProperty('Object'.toJS) as JSObject).callMethod(
        'defineProperty'.toJS,
        web.document,
        'fullscreenElement'.toJS,
        descriptor);
    (video as JSObject)
        .setProperty('requestFullscreen'.toJS, (() => request().toJS).toJS);
    (web.document as JSObject).setProperty(
        'exitFullscreen'.toJS,
        (() {
          exits++;
          change(null);
          return Future<JSAny?>.value(null).toJS;
        }).toJS);
    if (webkit) {
      (video as JSObject).setProperty(
          'webkitEnterFullscreen'.toJS,
          (() {
            webkitEntries++;
            if (rejectWebkit) throw StateError('webkit denied');
          }).toJS);
      (video as JSObject).setProperty(
          'webkitExitFullscreen'.toJS,
          (() {
            exits++;
            if (!deferWebkitExit) {
              video.dispatchEvent(web.Event('webkitendfullscreen'));
            }
          }).toJS);
    }
  }

  final web.HTMLVideoElement video;
  web.Element? element;
  web.Element? documentHost;
  Completer<void>? gate;
  bool reject = false;
  bool rejectWebkit = false;
  bool deferWebkitExit = false;
  final queuedRequests = <Completer<void>>[];
  int entries = 0;
  int webkitEntries = 0;
  int exits = 0;

  Future<JSAny?> request() async {
    entries++;
    if (queuedRequests.isNotEmpty) {
      await queuedRequests.removeAt(0).future;
    } else {
      await gate?.future;
    }
    if (reject) throw StateError('fullscreen denied');
    change(video);
    return null;
  }

  void change(web.Element? next) {
    element = next;
    web.document.dispatchEvent(web.Event('fullscreenchange'));
  }

  void dispose() {
    final reflect = globalContext.getProperty('Reflect'.toJS) as JSObject;
    for (final key in ['fullscreenElement', 'exitFullscreen']) {
      reflect.callMethod('deleteProperty'.toJS, web.document, key.toJS);
    }
  }
}

WebVideoBackend backend(String id) {
  final result = WebVideoBackend(
      NiumaDataSource.network('https://example.invalid/$id.m3u8'));
  addTearDown(result.dispose);
  return result;
}

FakeFullscreen fakeFor(WebVideoBackend owner, {bool webkit = false}) {
  final fake = FakeFullscreen(owner.htmlVideoElement, webkit: webkit);
  addTearDown(fake.dispose);
  return fake;
}

void expectControls(WebVideoBackend owner, bool enabled) {
  final video = owner.htmlVideoElement;
  expect(video.controls, enabled);
  expect(video.style.getPropertyValue('pointer-events'),
      enabled ? 'auto' : 'none');
  expect(
      (video.parentElement as web.HTMLElement)
          .style
          .getPropertyValue('pointer-events'),
      enabled ? 'auto' : 'none');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('标准全屏自动启用可交互控件，ESC 后恢复手势穿透', () async {
    final owner = backend('standard');
    final fake = fakeFor(owner);
    expect(await owner.enterNativeFullscreen(), isTrue);
    expectControls(owner, true);
    fake.change(null);
    expectControls(owner, false);
  });

  test('ShadowRoot 内元素全屏按所在根节点判断归属', () async {
    final owner = backend('shadow');
    final fake = fakeFor(owner);
    final host = web.document.createElement('div');
    final shadow = host.attachShadow(web.ShadowRootInit(mode: 'open'));
    shadow.appendChild(owner.htmlVideoElement.parentElement!);
    web.document.body!.appendChild(host);
    addTearDown(() => host.remove());
    fake.documentHost = host;
    final descriptor = JSObject()
      ..setProperty('configurable'.toJS, true.toJS)
      ..setProperty('get'.toJS, (() => fake.element).toJS);
    (globalContext.getProperty('Object'.toJS) as JSObject).callMethod(
        'defineProperty'.toJS, shadow, 'fullscreenElement'.toJS, descriptor);
    expect(await owner.enterNativeFullscreen(), isTrue);
    expectControls(owner, true);
    expect(await owner.exitNativeFullscreen(), isTrue);
    expect(fake.exits, 1);
    expectControls(owner, false);
  });

  test('退出全屏保留调用方原有的原生控件设置', () async {
    final owner = backend('restore');
    final fake = fakeFor(owner);
    await owner.setWebNativeControls(true);
    expect(await owner.enterNativeFullscreen(), isTrue);
    expect(await owner.exitNativeFullscreen(), isTrue);
    expect(fake.exits, 1);
    expectControls(owner, true);
  });

  test('全屏中控件保持可用，退出后应用调用方最新设置', () async {
    final owner = backend('preference');
    final fake = fakeFor(owner);
    await owner.setWebNativeControls(true);
    await owner.enterNativeFullscreen();
    await owner.setWebNativeControls(false);
    expectControls(owner, true);
    fake.change(null);
    expectControls(owner, false);
  });

  test('其它播放器退出全屏不改变本实例控件，也不代退其它元素', () async {
    final owner = backend('owner');
    final other = backend('other');
    final fake = fakeFor(owner);
    await other.setWebNativeControls(true);
    await owner.enterNativeFullscreen();
    expect(await other.exitNativeFullscreen(), isTrue);
    expect(fake.exits, 0);
    expect(fake.element, same(owner.htmlVideoElement));
    fake.change(null);
    expectControls(owner, false);
    expectControls(other, true);
  });

  test('进入全屏失败后恢复原有控件，下一次仍可重试', () async {
    final owner = backend('failed');
    final fake = fakeFor(owner)..reject = true;
    expect(await owner.enterNativeFullscreen(), isFalse);
    expectControls(owner, false);
    fake.reject = false;
    expect(await owner.enterNativeFullscreen(), isTrue);
    expectControls(owner, true);
  });

  test('进入全屏途中退出：迟到的成功不重新占用全屏', () async {
    final owner = backend('cancel');
    final fake = fakeFor(owner)..gate = Completer<void>();
    final entering = owner.enterNativeFullscreen();
    expectControls(owner, true);
    expect(await owner.exitNativeFullscreen(), isTrue);
    expectControls(owner, false);
    fake.gate!.complete();
    expect(await entering, isFalse);
    expect(fake.element, isNull);
    expectControls(owner, false);
  });

  test('进入全屏途中销毁：迟到成功会退出且不重新开启控件', () async {
    final owner = backend('dispose');
    final fake = fakeFor(owner)..gate = Completer<void>();
    final entering = owner.enterNativeFullscreen();
    await owner.dispose();
    fake.gate!.complete();
    expect(await entering, isFalse);
    expect(fake.element, isNull);
    expectControls(owner, false);
  });

  test('重复进入复用在途请求，失败结果一致', () async {
    final owner = backend('duplicate');
    final fake = fakeFor(owner)
      ..gate = Completer<void>()
      ..reject = true;
    final first = owner.enterNativeFullscreen();
    final second = owner.enterNativeFullscreen();
    fake.gate!.complete();
    expect(await first, isFalse);
    expect(await second, isFalse);
    expect(fake.entries, 1);
  });

  test('旧请求迟到成功而新请求失败：接管已满足新意图的全屏并保留控件', () async {
    final owner = backend('adopt');
    final fake = fakeFor(owner);
    final oldGate = Completer<void>();
    final newGate = Completer<void>();
    fake.queuedRequests.addAll([oldGate, newGate]);
    final oldRequest = owner.enterNativeFullscreen();
    await owner.exitNativeFullscreen();
    final newRequest = owner.enterNativeFullscreen();
    oldGate.complete();
    expect(await oldRequest, isFalse);
    newGate.completeError(StateError('new request denied'));
    expect(await newRequest, isTrue);
    expect(fake.element, same(owner.htmlVideoElement));
    expectControls(owner, true);
    fake.change(null);
    expectControls(owner, false);
  });

  test('旧请求迟到失败不能收尾新请求已成功的全屏', () async {
    final owner = backend('stale-failure');
    final fake = fakeFor(owner);
    final oldGate = Completer<void>();
    final newGate = Completer<void>();
    fake.queuedRequests.addAll([oldGate, newGate]);
    final oldRequest = owner.enterNativeFullscreen();
    await owner.exitNativeFullscreen();
    final newRequest = owner.enterNativeFullscreen();
    newGate.complete();
    expect(await newRequest, isTrue);
    oldGate.completeError(StateError('old request denied'));
    expect(await oldRequest, isFalse);
    expect(fake.element, same(owner.htmlVideoElement));
    expectControls(owner, true);
  });

  test('标准全屏已进入后销毁：主动退出本实例全屏', () async {
    final owner = backend('active-dispose');
    final fake = fakeFor(owner);
    await owner.enterNativeFullscreen();
    await owner.dispose();
    expect(fake.exits, 1);
    expect(fake.element, isNull);
    expectControls(owner, false);
  });

  test('Safari 退出事件异步到达前不接受再次进入，旧事件不影响下一次全屏', () async {
    final owner = backend('webkit-delayed-exit');
    final fake = fakeFor(owner, webkit: true)..deferWebkitExit = true;
    await owner.enterNativeFullscreen();
    expect(await owner.exitNativeFullscreen(), isTrue);
    expectControls(owner, true);
    expect(await owner.enterNativeFullscreen(), isFalse);
    expect(fake.webkitEntries, 1);
    owner.htmlVideoElement.dispatchEvent(web.Event('webkitendfullscreen'));
    expectControls(owner, false);
    expect(await owner.enterNativeFullscreen(), isTrue);
    expect(fake.webkitEntries, 2);
    expectControls(owner, true);
  });

  test('Safari 全屏已进入后销毁：主动退出且移除结束事件监听', () async {
    final owner = backend('webkit-dispose');
    final fake = fakeFor(owner, webkit: true)..deferWebkitExit = true;
    await owner.enterNativeFullscreen();
    await owner.dispose();
    expect(fake.exits, 1);
    expectControls(owner, false);
    owner.htmlVideoElement.dispatchEvent(web.Event('webkitendfullscreen'));
    expectControls(owner, false);
  });

  test('Safari 全屏自动开控件，系统退出后恢复原设置', () async {
    final owner = backend('webkit');
    final fake = fakeFor(owner, webkit: true);
    expect(await owner.enterNativeFullscreen(), isTrue);
    expect(fake.webkitEntries, 1);
    expectControls(owner, true);
    owner.htmlVideoElement.dispatchEvent(web.Event('webkitendfullscreen'));
    expectControls(owner, false);
    await owner.setWebNativeControls(true);
    await owner.enterNativeFullscreen();
    expect(await owner.exitNativeFullscreen(), isTrue);
    expectControls(owner, true);
  });

  test('Safari 进入失败回落标准全屏，标准路径失败仍恢复控件', () async {
    final owner = backend('webkit-fallback');
    final fake = fakeFor(owner, webkit: true)
      ..rejectWebkit = true
      ..reject = true;
    expect(await owner.enterNativeFullscreen(), isFalse);
    expect(fake.entries, 1);
    expectControls(owner, false);
  });

  test('Safari 全屏内用户暂停后退出，不被进入前的播放状态强制续播', () async {
    final owner = backend('webkit-pause');
    fakeFor(owner, webkit: true);
    var plays = 0;
    final video = owner.htmlVideoElement;
    (video as JSObject).setProperty(
        'play'.toJS,
        (() {
          plays++;
          return Future<JSAny?>.value(null).toJS;
        }).toJS);
    var paused = false;
    final descriptor = JSObject()
      ..setProperty('configurable'.toJS, true.toJS)
      ..setProperty('get'.toJS, (() => paused.toJS).toJS);
    (globalContext.getProperty('Object'.toJS) as JSObject)
        .callMethod('defineProperty'.toJS, video, 'paused'.toJS, descriptor);
    await owner.play();
    await owner.enterNativeFullscreen();
    paused = true;
    video.dispatchEvent(web.Event('pause'));
    video.dispatchEvent(web.Event('webkitendfullscreen'));
    await Future<void>.delayed(Duration.zero);
    expect(plays, 1);
    expect(owner.value.phase, PlayerPhase.paused);
  });
}
