import 'dart:async';
import 'dart:typed_data';

import '../../../core/process/command_runner.dart';
import '../domain/browser_failure.dart';
import '../domain/browser_target.dart';
import '../domain/element_capture.dart';
import 'browser_launcher.dart';
import 'cdp_connection.dart';
import 'cdp_page.dart';
import 'cdp_socket.dart';
import 'element_picker.dart';

/// An attached browser plus the page we are driving in it.
class BrowserSession {
  BrowserSession({
    required this.endpoint,
    required this.page,
    required this.picker,
  });

  final BrowserEndpoint endpoint;
  final CdpPage page;
  final ElementPicker picker;

  /// Whether the browser is still there.
  bool get isConnected => page.isConnected;

  /// Completes when the browser or tab goes away.
  Future<void> get done => page.connection.done;

  /// Detaches from the page. A spawned browser is left running; the caller
  /// decides whether to close it.
  Future<void> dispose() async {
    await page.close();
    endpoint.http.close();
  }
}

/// The feature's public API — the surface an MCP tool set will call.
///
/// Everything an agent needs is one method here: `connect`, `navigate`,
/// `evaluate`, `capture`, `pickElement`, `screenshot`, `listTargets`. Nothing
/// in this class talks to Flutter, so wiring it to the MCP bridge is a matter
/// of mapping tool arguments onto these calls.
class BrowserService {
  BrowserService({
    required CommandRunner runner,
    BrowserLauncher? launcher,
    Future<CdpSocket> Function(String webSocketUrl)? connectSocket,
  }) : _launcher = launcher ?? BrowserLauncher(runner: runner),
       _connectSocket = connectSocket ?? WebSocketCdpSocket.connect;

  final BrowserLauncher _launcher;
  final Future<CdpSocket> Function(String webSocketUrl) _connectSocket;

  BrowserSession? _session;

  /// The active session, or null when not connected.
  BrowserSession? get session => _session;

  /// Whether there is a session and its browser is still alive.
  bool get isConnected => _session?.isConnected ?? false;

  /// Attaches to a browser on [port], launching one only if nothing is there.
  ///
  /// When [url] is given, the page ends up there: an existing tab is navigated,
  /// and a browser with no drivable page gets a new tab. Without [url], a
  /// browser with no page is reported as [BrowserFailure.noTarget] rather than
  /// silently opening something the user did not ask for.
  Future<BrowserSession> connect({
    int port = BrowserLauncher.defaultPort,
    bool spawnIfNeeded = true,
    String? url,
    String? targetId,
    Duration navigationTimeout = const Duration(seconds: 30),
  }) async {
    await disconnect();
    final endpoint = await _launcher.connect(
      port: port,
      spawnIfNeeded: spawnIfNeeded,
      initialUrl: url,
    );

    BrowserTarget? target;
    try {
      final targets = await endpoint.http.listTargets();
      final pages = targets.where((t) => t.isDrivablePage).toList();
      target = switch (targetId) {
        final String id => pages.where((t) => t.id == id).firstOrNull,
        null => pages.firstOrNull,
      };
      if (target == null && targetId != null) {
        throw BrowserException(
          BrowserFailure.noTarget,
          describeBrowserFailure(
            BrowserFailure.noTarget,
            detail: 'no page with target id $targetId',
          ),
        );
      }
      if (target == null) {
        if (url == null) {
          throw BrowserException(
            BrowserFailure.noTarget,
            describeBrowserFailure(BrowserFailure.noTarget),
          );
        }
        target = await endpoint.http.openTab(url);
      }
    } on Object {
      endpoint.http.close();
      rethrow;
    }

    final webSocketUrl = target.webSocketDebuggerUrl;
    if (webSocketUrl == null || webSocketUrl.isEmpty) {
      endpoint.http.close();
      throw BrowserException(
        BrowserFailure.noTarget,
        describeBrowserFailure(
          BrowserFailure.noTarget,
          detail: 'the page is already being debugged by something else',
        ),
      );
    }

    final CdpPage page;
    try {
      final socket = await _connectSocket(webSocketUrl);
      page = CdpPage(connection: CdpConnection(socket), target: target);
      await page.enableDomains();
    } on Object {
      endpoint.http.close();
      rethrow;
    }

    final session = BrowserSession(
      endpoint: endpoint,
      page: page,
      picker: ElementPicker(page),
    );
    _session = session;

    if (url != null && target.url != url) {
      await page.navigate(url, timeout: navigationTimeout);
    }
    return session;
  }

  /// Ends the session, if there is one.
  Future<void> disconnect() async {
    final session = _session;
    _session = null;
    if (session == null) return;
    await session.dispose();
  }

  // Every verb below is `async` on purpose: a missing or dead session must
  // come back as a failed future, not as a synchronous throw that skips past
  // the caller's error handling.

  /// Navigates the attached page and waits for it to load.
  Future<void> navigate(
    String url, {
    Duration timeout = const Duration(seconds: 30),
  }) async => _require().page.navigate(url, timeout: timeout);

  /// Evaluates JavaScript in the attached page and returns its value.
  Future<Object?> evaluate(
    String expression, {
    bool awaitPromise = false,
  }) async => _require().page.evaluate(expression, awaitPromise: awaitPromise);

  /// How many elements match [selector] in the attached page.
  Future<int> countMatches(String selector) async =>
      _require().page.countMatches(selector);

  /// Captures HTML, computed CSS and a cropped screenshot for [selector].
  Future<ElementCapture> capture(String selector) async =>
      _require().page.captureSelector(selector);

  /// Lets the user point at an element, and captures it.
  Future<ElementCapture> pickElement({
    Duration timeout = const Duration(minutes: 2),
  }) async => _require().picker.pick(timeout: timeout);

  /// Abandons a pick in progress.
  void cancelPick() => _session?.picker.cancel();

  /// A PNG of the viewport, the whole page, or one element.
  Future<Uint8List> screenshot({
    String? selector,
    bool fullPage = false,
  }) async {
    final page = _require().page;
    if (selector == null) return page.screenshot(fullPage: fullPage);
    final described = await page.describeSelector(selector);
    return page.screenshot(clip: described.box);
  }

  /// Every debuggable target the browser reports.
  Future<List<BrowserTarget>> listTargets() async =>
      _require().endpoint.http.listTargets();

  /// Opens a new tab; the session keeps driving its current page.
  Future<BrowserTarget> openTab(String url) async =>
      _require().endpoint.http.openTab(url);

  BrowserSession _require() {
    final session = _session;
    if (session == null) {
      throw BrowserException(
        BrowserFailure.notRunning,
        'Not connected to a browser. Connect first.',
      );
    }
    if (!session.isConnected) {
      throw BrowserException(
        BrowserFailure.disconnected,
        describeBrowserFailure(BrowserFailure.disconnected),
      );
    }
    return session;
  }
}
