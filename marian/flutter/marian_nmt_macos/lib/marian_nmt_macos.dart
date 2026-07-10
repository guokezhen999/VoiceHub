/// macOS FFI plugin entry point for Marian NMT.
///
/// This plugin bundles libmarian_nmt.dylib and libonnxruntime.dylib via its
/// podspec so that `flutter run` automatically links them into the macOS
/// app bundle — no Xcode project editing required.
library marian_nmt_macos;

import 'dart:ffi';
import 'dart:io';

/// Load the Marian NMT native library from the app bundle.
///
/// On macOS the dylibs are vendored by the CocoaPods podspec and placed
/// in the app bundle at runtime. Flutter's `ffiPlugin: true` registration
/// ensures the bundle path is on the library search path.
DynamicLibrary loadMarianLibrary() {
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libmarian_nmt.dylib');
  }
  if (Platform.isIOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libmarian_nmt.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('marian_nmt.dll');
  }
  throw UnsupportedError(
      'Marian NMT: unsupported platform ${Platform.operatingSystem}');
}
