Pod::Spec.new do |s|
  s.name             = 'marian_nmt_macos'
  s.version          = '1.0.0'
  s.summary          = 'Marian NMT macOS FFI plugin — bundles libmarian_nmt + onnxruntime.'
  s.homepage         = 'https://github.com/k2-fsa/sherpa-onnx'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Voice App' => '' }

  s.source           = { :path => '.' }
  s.dependency 'FlutterMacOS'
  s.vendored_libraries = '*.dylib'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
