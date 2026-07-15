Pod::Spec.new do |s|
  s.name             = 'voice_engine_macos'
  s.version          = '1.0.0'
  s.summary          = 'voice_engine iOS FFI plugin — bundles libvoice_engine.'
  s.homepage         = 'https://github.com/k2-fsa/sherpa-onnx'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Voice App' => '' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  # voice_engine.xcframework is a self-contained dynamic framework that
  # statically embeds sherpa-onnx + onnxruntime (built by build_ios.sh).
  s.preserve_paths = 'voice_engine.xcframework/**/*'
  s.vendored_frameworks = 'voice_engine.xcframework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
