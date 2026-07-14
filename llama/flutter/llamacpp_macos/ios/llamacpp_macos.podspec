Pod::Spec.new do |s|
  s.name             = 'llamacpp_macos'
  s.version          = '1.0.0'
  s.summary          = 'llamacpp iOS FFI plugin — bundles libllamacpp_nmt static library with Metal support.'
  s.homepage         = 'https://github.com/example/llamacpp_macos'
  s.license          = { :type => 'MIT' }
  s.author           = { 'VoiceHub' => '' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.preserve_paths = 'llamacpp_nmt.xcframework/**/*'
  s.vendored_frameworks = 'llamacpp_nmt.xcframework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
