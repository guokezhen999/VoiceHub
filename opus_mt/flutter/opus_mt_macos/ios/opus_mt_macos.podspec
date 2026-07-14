Pod::Spec.new do |s|
  s.name             = 'opus_mt_macos'
  s.version          = '1.0.0'
  s.summary          = 'opus-mt iOS FFI plugin — bundles libopus_mt static library.'
  s.homepage         = 'https://github.com/k2-fsa/sherpa-onnx'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Voice App' => '' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.preserve_paths = 'opus_mt.xcframework/**/*'
  s.vendored_frameworks = 'opus_mt.xcframework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
