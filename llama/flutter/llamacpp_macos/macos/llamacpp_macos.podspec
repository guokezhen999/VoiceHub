Pod::Spec.new do |s|
  s.name             = 'llamacpp_macos'
  s.version          = '1.0.0'
  s.summary          = 'Flutter FFI plugin bundling libllamacpp_nmt.dylib'
  s.homepage         = 'https://github.com/example/llamacpp_macos'
  s.license          = { :type => 'MIT' }
  s.author           = { 'VoiceHub' => '' }
  s.source           = { :path => '.' }
  s.platform         = :osx, '10.15'
  s.vendored_libraries = '*.dylib'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => '@executable_path/../Frameworks',
  }
end
