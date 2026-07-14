/// macOS FFI plugin entry point for voice_engine.
///
/// This plugin bundles libvoice_engine.dylib via its podspec so that
/// `flutter run` automatically links it into the macOS app bundle — no Xcode
/// project editing required. libsherpa-onnx-c-api.dylib is already vendored by
/// the sherpa_onnx_macos plugin; voice_engine links against it at load time.
library voice_engine_macos;

import 'dart:ffi';
import 'dart:io';

/// Load the voice_engine native library from the app bundle.
///
/// On macOS the dylib is vendored by the CocoaPods podspec and placed in the
/// app bundle at runtime. Flutter's `ffiPlugin: true` registration ensures the
/// bundle path is on the library search path.
DynamicLibrary loadVoiceEngineLibrary() {
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libvoice_engine.dylib');
  }
  if (Platform.isIOS) {
    return DynamicLibrary.open('voice_engine.framework/voice_engine');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libvoice_engine.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('voice_engine.dll');
  }
  throw UnsupportedError(
      'voice_engine: unsupported platform ${Platform.operatingSystem}');
}
