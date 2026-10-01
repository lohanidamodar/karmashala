import 'dart:typed_data';

import '../domain/browser_action.dart';
import '../domain/browser_failure.dart';
import '../domain/browser_viewport.dart';
import 'browser_service.dart';
import 'cdp_page.dart';

/// One capture at one emulated viewport.
typedef ViewportScreenshot = ({BrowserViewport viewport, Uint8List png});

/// Viewport emulation over CDP's `Emulation` domain. An override outlives the
/// call that set it, so every path that sets one clears it.
extension CdpViewport on CdpPage {
  /// Lays the page out at [viewport], at one device pixel per CSS pixel so two
  /// captures of it compare pixel for pixel.
  Future<void> emulateViewport(BrowserViewport viewport) async {
    await enableDomains();
    await connection.send(
      'Emulation.setDeviceMetricsOverride',
      params: {
        'width': viewport.width,
        'height': viewport.height,
        'deviceScaleFactor': 1,
        'mobile': viewport.mobile,
      },
    );
  }

  /// Puts the window's own size back.
  Future<void> clearViewport() =>
      connection.send('Emulation.clearDeviceMetricsOverride');

  /// A screenshot at each of [viewports] in turn, then the override cleared —
  /// on failure too.
  Future<List<ViewportScreenshot>> screenshotsAt(
    List<BrowserViewport> viewports, {
    bool fullPage = false,
  }) async {
    final shots = <ViewportScreenshot>[];
    try {
      for (final viewport in viewports) {
        await emulateViewport(viewport);
        await _settle();
        shots.add((
          viewport: viewport,
          png: await screenshot(fullPage: fullPage),
        ));
      }
    } finally {
      if (isConnected) await clearViewport();
    }
    return shots;
  }

  /// Two frames, so the resize has been laid out. A background tab draws no
  /// frames; the capture then goes ahead rather than failing.
  Future<void> _settle() async {
    try {
      await evaluate(
        'new Promise(r => requestAnimationFrame(() => '
        'requestAnimationFrame(() => r(true))))',
        awaitPromise: true,
        timeout: const Duration(seconds: 3),
      );
    } on BrowserException catch (error) {
      if (error.failure == BrowserFailure.disconnected) rethrow;
    }
  }
}

/// [CdpViewport] through the service the tools and the pane share.
extension BrowserServiceViewports on BrowserService {
  /// The page at each of [viewports], told to whoever records this service.
  Future<List<ViewportScreenshot>> screenshotsAtViewports(
    List<BrowserViewport> viewports, {
    bool fullPage = false,
  }) async {
    final current = session;
    if (current == null) {
      throw BrowserException(
        BrowserFailure.notRunning,
        'Not connected to a browser. Connect first.',
      );
    }
    if (!current.isConnected) {
      throw BrowserException(
        BrowserFailure.disconnected,
        describeBrowserFailure(BrowserFailure.disconnected),
      );
    }
    final shots = await current.page.screenshotsAt(
      viewports,
      fullPage: fullPage,
    );
    for (final shot in shots) {
      try {
        actionSink?.call(
          BrowserAction(
            verb: 'screenshot',
            summary: 'Screenshot at ${shot.viewport}',
            png: shot.png,
          ),
        );
      } on Object {
        // Recording is observation; it never fails the capture.
      }
    }
    return shots;
  }
}
