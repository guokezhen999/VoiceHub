import 'dart:ffi';

/// Load the libllamacpp_nmt shared library for the current platform.
///
/// On macOS, loads the dylib bundled by the llamacpp_macos Flutter FFI plugin.
DynamicLibrary loadLlamaLibrary() {
  return DynamicLibrary.open('libllamacpp_nmt.dylib');
}
