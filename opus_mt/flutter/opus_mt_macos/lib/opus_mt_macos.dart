/// macOS FFI plugin entry point for opus-mt.
///
/// This plugin bundles libopus_mt.dylib and libonnxruntime.dylib via its
/// podspec so that `flutter run` automatically links them into the macOS
/// app bundle — no Xcode project editing required.
library opus_mt_macos;

import 'dart:ffi';
import 'dart:io';

/// Load the opus-mt native library from the app bundle.
///
/// On macOS the dylibs are vendored by the CocoaPods podspec and placed
/// in the app bundle at runtime. Flutter's `ffiPlugin: true` registration
/// ensures the bundle path is on the library search path.
DynamicLibrary loadOpusMtLibrary() {
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libopus_mt.dylib');
  }
  if (Platform.isIOS) {
    return DynamicLibrary.open('opus_mt.framework/opus_mt');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libopus_mt.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('opus_mt.dll');
  }
  throw UnsupportedError(
      'opus-mt: unsupported platform ${Platform.operatingSystem}');
}
