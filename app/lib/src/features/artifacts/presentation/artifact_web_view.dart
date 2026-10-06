import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';

/// The page a web view is handed: the sandbox shell around an artifact, and
/// what the view must be set up with.
class ArtifactWebDocument {
  const ArtifactWebDocument({required this.shell, required this.allowNetwork});

  final String shell;
  final bool allowNetwork;
  ArtifactSandboxSettings get settings => kArtifactSandboxSettings;
}

typedef ArtifactWebSurfaceBuilder =
    Widget Function(BuildContext context, ArtifactWebDocument document);

/// How a sandboxed page is drawn. A provider so a test sees what a web view
/// would have been given without a platform view.
final artifactWebSurfaceProvider = Provider<ArtifactWebSurfaceBuilder>(
  (ref) =>
      (context, document) => _SandboxedWebView(document: document),
);

/// The shell in a real web view: no JavaScript handler is registered and no
/// resource, console or request callback is wired, so the plugin's injected
/// bridge reaches nothing of Karmashala's. Until the shell has loaded only the
/// main frame may navigate — the shell itself; after that, and for every
/// subframe always, only [artifactSandboxAllowsNavigation] passes.
class _SandboxedWebView extends StatefulWidget {
  const _SandboxedWebView({required this.document});

  final ArtifactWebDocument document;

  @override
  State<_SandboxedWebView> createState() => _SandboxedWebViewState();
}

class _SandboxedWebViewState extends State<_SandboxedWebView> {
  var _shellLoaded = false;
  InAppWebViewController? _controller;

  @override
  void didUpdateWidget(_SandboxedWebView old) {
    super.didUpdateWidget(old);
    if (old.document.shell != widget.document.shell ||
        old.document.allowNetwork != widget.document.allowNetwork) {
      _shellLoaded = false;
      _controller?.loadData(
        data: widget.document.shell,
        baseUrl: WebUri('about:blank'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.document.settings;
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: widget.document.shell,
        baseUrl: WebUri('about:blank'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: s.multipleWindows,
        allowFileAccess: s.allowFileAccess,
        allowFileAccessFromFileURLs: s.allowFileAccessFromFileUrls,
        allowUniversalAccessFromFileURLs: s.allowUniversalAccessFromFileUrls,
        allowContentAccess: s.allowContentAccess,
        blockNetworkLoads: !widget.document.allowNetwork,
        isInspectable: s.inspectable,
        incognito: s.incognito,
        cacheEnabled: false,
        clearCache: true,
        thirdPartyCookiesEnabled: false,
        useShouldOverrideUrlLoading: true,
        mediaPlaybackRequiresUserGesture: true,
        geolocationEnabled: false,
        disableContextMenu: false,
      ),
      onWebViewCreated: (controller) => _controller = controller,
      onLoadStop: (_, _) => _shellLoaded = true,
      shouldOverrideUrlLoading: (_, action) async {
        final main = action.isForMainFrame;
        final uri = action.request.url;
        if (main && !_shellLoaded) return NavigationActionPolicy.ALLOW;
        return uri != null && artifactSandboxAllowsNavigation(uri)
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      onPermissionRequest: (_, _) async =>
          PermissionResponse(action: PermissionResponseAction.DENY),
      onGeolocationPermissionsShowPrompt: (_, origin) async =>
          GeolocationPermissionShowPromptResponse(
            origin: origin,
            allow: false,
            retain: false,
          ),
    );
  }
}
