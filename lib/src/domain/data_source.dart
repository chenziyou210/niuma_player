/// [NiumaDataSource] 的 source 类型。
enum NiumaSourceType { network, asset, file }

/// 描述视频从哪儿来。
///
/// 镜像 niuma_player 支持的 [VideoPlayerController] 工厂构造子集。
/// 底层 backend（video_player 或 IJK）由 [NiumaPlayerController] 选择。
class NiumaDataSource {
  const NiumaDataSource._({
    required this.type,
    required this.uri,
    this.headers,
  });

  /// source 类型（network / asset / file）。
  final NiumaSourceType type;

  /// URI / 路径 / asset key，取决于 [type]。
  final String uri;

  /// 可选的 HTTP headers（仅对 [NiumaSourceType.network] 有意义）。
  ///
  /// **Web 限制**：浏览器 `<video>` 的原生媒体请求无法由 JS 附加请求头——
  /// 普通 mp4、以及 Safari / iOS 的原生 HLS 都**不会**发送这里的 headers；
  /// 只有走 hls.js（Chrome / Firefox / Edge 的 HLS）时经 XHR 注入，且
  /// `cookie` / `referer` 等 forbidden headers 仍会被浏览器拒绝。web 上的鉴权
  /// 请改用签名 URL 或 query token。
  final Map<String, String>? headers;

  /// 网络 source（http/https/hls 等）。
  factory NiumaDataSource.network(
    String url, {
    Map<String, String>? headers,
  }) {
    return NiumaDataSource._(
      type: NiumaSourceType.network,
      uri: url,
      headers: headers,
    );
  }

  /// Flutter asset source（与 app 一起打包）。
  factory NiumaDataSource.asset(String assetPath) {
    return NiumaDataSource._(
      type: NiumaSourceType.asset,
      uri: assetPath,
    );
  }

  /// 本地文件 source。
  factory NiumaDataSource.file(String filePath) {
    return NiumaDataSource._(
      type: NiumaSourceType.file,
      uri: filePath,
    );
  }

  @override
  String toString() =>
      'NiumaDataSource(type: $type, uri: $uri, headers: $headers)';
}
