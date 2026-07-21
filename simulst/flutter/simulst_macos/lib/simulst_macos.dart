/// macOS FFI plugin entry point for simulst.
///
/// Bundles libsimulst.dylib via the podspec so `flutter run` links it into the
/// app bundle automatically. Runtime dependencies (libsherpa-onnx-c-api,
/// libonnxruntime) are provided by the sherpa_onnx_macos plugin.
library simulst_macos;

import 'dart:ffi';
import 'dart:io';

/// Load the simulst native library from the app bundle.
DynamicLibrary loadSimulstLibrary() {
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libsimulst.dylib');
  }
  if (Platform.isIOS) {
    try {
      return DynamicLibrary.open('simulst.framework/simulst');
    } catch (_) {
      return DynamicLibrary.process();
    }
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libsimulst.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('simulst.dll');
  }
  throw UnsupportedError(
      'simulst: unsupported platform ${Platform.operatingSystem}');
}
