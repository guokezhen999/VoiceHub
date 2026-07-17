Pod::Spec.new do |s|
  s.name             = 'simulst_macos'
  s.version          = '1.0.0'
  s.summary          = 'simulst macOS FFI plugin — bundles libsimulst.dylib.'
  s.homepage         = 'https://github.com/k2-fsa/sherpa-onnx'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Voice App' => '' }

  s.source           = { :path => '.' }
  s.dependency 'FlutterMacOS'
  # Only vendor libsimulst.dylib. sherpa-onnx + onnxruntime are provided by
  # sherpa_onnx_macos and resolved via @rpath at load time.
  s.vendored_libraries = '*.dylib'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => '@executable_path/../Frameworks',
  }
  s.swift_version = '5.0'
end
