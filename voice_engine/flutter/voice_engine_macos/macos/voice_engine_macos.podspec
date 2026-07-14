Pod::Spec.new do |s|
  s.name             = 'voice_engine_macos'
  s.version          = '1.0.0'
  s.summary          = 'voice_engine macOS FFI plugin — bundles libvoice_engine.'
  s.homepage         = 'https://github.com/k2-fsa/sherpa-onnx'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Voice App' => '' }

  s.source           = { :path => '.' }
  s.dependency 'FlutterMacOS'
  # Only vendor libvoice_engine.dylib; libsherpa-onnx-c-api.dylib is provided
  # by the sherpa_onnx_macos plugin and resolved via @rpath at load time.
  s.vendored_libraries = '*.dylib'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
