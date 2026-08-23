/// 平台自由格式错误 → [PlayerErrorCategory] 的映射，收敛在内核一处。
///
/// 三端主路径（vp 的 ExoPlayer / AVFoundation）抛的是只有自由文本的
/// `PlatformException`，没有结构化分类；IJK 桥自带结构化 `errorCategory`
/// 不经过这里。**kit / 业务侧不要自己做文本嗅探**——三端错误串格式不同，
/// 猜错比不猜更糟；模式清单集中在此，配真机串样本的单测演进。
library;

import 'package:flutter/services.dart' show PlatformException;

import 'package:niuma_player/src/domain/player_state.dart';

/// 解码 / 容器不支持类模式。**必须先于网络类匹配**：Exo 的解码失败串里
/// 常同时带 "source" 字样（如 MediaCodecVideoRenderer error ... source），
/// 反过来网络失败串不会带这些解码器关键词。
const List<String> _codecPatterns = <String>[
  'decoderinitializationexception', // Exo: 解码器起不来
  'decoder init failed',
  'mediacodec', // Android 硬解层
  'cannot decode', // AVFoundation
  'format not recognized', // AVErrorFileFormatNotRecognized 文案
  'unsupported',
];

/// 网络 / I/O 类模式。`ExoPlaybackException: Source error` 是 Exo 源层
/// （网络 / 文件 IO）失败的统一外壳——Android 真机断网实测就是这条。
const List<String> _networkPatterns = <String>[
  'source error', // ExoPlaybackException 源层失败
  'httpdatasourceexception', // Exo HTTP 栈
  'invalidresponsecodeexception', // Exo 非 2xx
  'unknownhostexception', // DNS
  'sockettimeout',
  'connection',
  'connect',
  'network',
  'timed out',
  'timeout',
  'nsurlerrordomain', // AVFoundation / iOS URL 栈
  'error -1009', // NSURLErrorNotConnectedToInternet
  'error -1001', // NSURLErrorTimedOut
  'error -1004', // NSURLErrorCannotConnectToHost
  'error -1005', // NSURLErrorNetworkConnectionLost
  'internet connection',
  'dns',
];

/// 从抛出的异常对象推断分类；认不出（或不是平台异常）返回 null，
/// 调用方自行兜底（通常是 [PlayerErrorCategory.unknown]）。
PlayerErrorCategory? classifyThrownPlatformError(Object error) {
  if (error is PlatformException) {
    return classifyPlatformErrorText(code: error.code, message: error.message);
  }
  return null;
}

/// 自由格式错误文本 → 分类；认不出返回 null。大小写不敏感的子串匹配，
/// 模式故意保守：漏归类只是退化成 unknown 的旧行为，误归类会带偏
/// retry / IJK 兜底 / failover 决策。
PlayerErrorCategory? classifyPlatformErrorText({
  String? code,
  String? message,
}) {
  final haystack = '${code ?? ''} ${message ?? ''}'.toLowerCase();
  if (haystack.trim().isEmpty) return null;
  for (final p in _codecPatterns) {
    if (haystack.contains(p)) return PlayerErrorCategory.codecUnsupported;
  }
  for (final p in _networkPatterns) {
    if (haystack.contains(p)) return PlayerErrorCategory.network;
  }
  return null;
}
