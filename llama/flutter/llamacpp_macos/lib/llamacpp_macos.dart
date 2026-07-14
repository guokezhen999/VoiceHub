import 'dart:ffi';
import 'dart:io';

/// Load the libllamacpp_nmt shared library for the current platform.
///
/// On macOS, loads the dylib bundled by the llamacpp_macos Flutter FFI plugin.
/// On iOS, uses DynamicLibrary.process() since the static library is linked
/// into the app binary.
DynamicLibrary loadLlamaLibrary() {
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libllamacpp_nmt.dylib');
  }
  if (Platform.isIOS) {
    return DynamicLibrary.open('llamacpp_nmt.framework/llamacpp_nmt');
  }
  throw UnsupportedError(
      'llamacpp: unsupported platform ${Platform.operatingSystem}');
}
