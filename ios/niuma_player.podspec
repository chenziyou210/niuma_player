#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint niuma_player.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'niuma_player'
  # 与 pubspec.yaml 的 version 保持一致——CI 会校验两者相同。
  s.version          = '0.5.2'
  s.summary          = 'Headless Flutter video player SDK: unified controller across iOS / Android / Web.'
  s.description      = <<-DESC
niuma_player iOS pod: video_player (AVPlayer) primary path plus the Picture-in-Picture bridge
(NiumaPipPlugin) and system helpers. Orchestration (multi-line failover, retry, middleware)
lives in Dart; this pod only carries the native glue.
                       DESC
  s.homepage         = 'https://github.com/doubledog789/niuma_player'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'doubledog789' => '248255786+doubledog789@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Privacy manifest 随 pod 打包（目前声明为空：不追踪、不采集、未用 required-reason
  # API）。之后若用到 UserDefaults / 文件时间戳等 required-reason API，改
  # Resources/PrivacyInfo.xcprivacy 的 NSPrivacyAccessedAPITypes。
  s.resource_bundles = {'niuma_player_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
