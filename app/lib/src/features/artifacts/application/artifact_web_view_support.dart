import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:riverpod/riverpod.dart';

/// Null when this platform can run a sandboxed page; otherwise why not, in
/// words a person can act on.
final artifactWebViewSupportProvider = FutureProvider<String?>((ref) async {
  if (kIsWeb) return 'the web build cannot hold a sandboxed web view';
  if (Platform.isLinux) return 'Linux has no web view Karmashala can embed';
  if (Platform.isWindows) {
    try {
      final version = await WebViewEnvironment.getAvailableVersion();
      if (version == null) {
        return 'the Microsoft Edge WebView2 Runtime is not installed';
      }
    } on Object catch (error) {
      return 'the WebView2 Runtime could not be checked ($error)';
    }
  }
  return null;
});
