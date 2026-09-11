import 'dart:async';
import 'dart:typed_data';

import '../domain/browser_action.dart';
import '../domain/browser_failure.dart';
import '../domain/browser_target.dart';
import '../domain/element_capture.dart';
import '../domain/found_element.dart';
import 'browser_launcher.dart';
import 'browser_process.dart';
import 'cdp_connection.dart';
import 'cdp_page.dart';
import 'cdp_socket.dart';
import 'element_picker.dart';
import 'page_input.dart';
import 'page_observer.dart';

class BrowserSession {
  BrowserSession({
    required this.endpoint,
    required this.page,
    required this.picker,
    required this.input,
  });

  final BrowserEndpoint endpoint;
  final CdpPage page;
  final ElementPicker picker;

  final PageInput input;

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

/// The feature's public API. Nothing here talks to Flutter, so wiring it to the
/// MCP bridge is a matter of mapping tool arguments onto these calls.
class BrowserService {
  BrowserService({
    required BrowserProcessStarter startProcess,
    BrowserLauncher? launcher,
    Future<CdpSocket> Function(String webSocketUrl)? connectSocket,
  }) : _launcher = launcher ?? BrowserLauncher(startProcess: startProcess),
       _connectSocket = connectSocket ?? WebSocketCdpSocket.connect;

  final BrowserLauncher _launcher;
  final Future<CdpSocket> Function(String webSocketUrl) _connectSocket;

  BrowserSession? _session;
  PageObserver? _observer;
  bool _observeRequested = false;

  /// Who is recording what this service does, or null for nobody. A seam rather
  /// than a subclass: pane, MCP tools and harness all drive this one object.
  BrowserActionSink? actionSink;

  BrowserSession? get session => _session;

  /// Watching the page's console and network, when something asked for it.
  PageObserver? get observer => _observer;

  bool get isConnected => _session?.isConnected ?? false;

  /// Starts collecting console errors and failed requests. Switching tab or
  /// reconnecting re-points the same collector rather than making a second one,
  /// so a navigation part-way through a run keeps the errors before it.
  Future<void> startObserving() async {
    _observeRequested = true;
    final observer = _observer ??= PageObserver();
    await observer.watch(_require().page);
  }

  /// Stops collecting. What was already collected stays readable through
  /// [observer]; losing the evidence at that moment would be the whole point.
  Future<void> stopObserving() async {
    _observeRequested = false;
    await _observer?.stop();
  }

  /// Attaches to a browser on [port], launching one only if nothing is there.
  /// With [url] the page ends up there; without it, a browser with no drivable
  /// page is [BrowserFailure.noTarget] rather than a tab nobody asked for.
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

    CdpPage? page;
    try {
      final socket = await _connectSocket(webSocketUrl);
      page = CdpPage(connection: CdpConnection(socket), target: target);
      await page.enableDomains();
    } on Object {
      endpoint.http.close();
      // A socket opened and then refused is still a debugger the page counts.
      await page?.close();
      rethrow;
    }

    final session = BrowserSession(
      endpoint: endpoint,
      page: page,
      picker: ElementPicker(page),
      input: PageInput(page),
    );
    _session = session;

    // A run that asked to watch keeps watching across a reconnect or tab switch.
    if (_observeRequested) await startObserving();

    if (url != null && target.url != url) {
      await page.navigate(url, timeout: navigationTimeout);
    }
    _report(
      BrowserAction(
        verb: 'connect',
        summary: endpoint.description,
        detail: target.url.isEmpty ? null : 'Driving ${target.url}',
      ),
    );
    return session;
  }

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
  }) async => _recorded(
    'navigate',
    'Navigated to $url',
    () => _require().page.navigate(url, timeout: timeout),
  );

  Future<Object?> evaluate(
    String expression, {
    bool awaitPromise = false,
  }) async => _recorded(
    'evaluate',
    'Evaluated ${_short(expression)}',
    () => _require().page.evaluate(expression, awaitPromise: awaitPromise),
    describe: (value) => BrowserAction(
      verb: 'evaluate',
      summary: 'Evaluated ${_short(expression)}',
      detail: '$expression\n→ $value',
    ),
  );

  Future<int> countMatches(String selector) async =>
      _require().page.countMatches(selector);

  /// Captures HTML, computed CSS and a cropped screenshot for [selector].
  Future<ElementCapture> capture(String selector) async => _recorded(
    'capture',
    'Captured `$selector`',
    () => _require().page.captureSelector(selector),
    describe: (capture) => _captureAction(capture, 'Captured `$selector`'),
  );

  /// Lets the user point at an element, and captures it.
  Future<ElementCapture> pickElement({
    Duration timeout = const Duration(minutes: 2),
  }) async => _recorded(
    'capture',
    'Picked an element',
    () => _require().picker.pick(timeout: timeout),
    describe: (capture) =>
        _captureAction(capture, 'Picked ${capture.selector}'),
  );

  void cancelPick() => _session?.picker.cancel();

  /// A PNG of the viewport, the whole page, or one element.
  Future<Uint8List> screenshot({
    String? selector,
    bool fullPage = false,
  }) async {
    final what = selector != null
        ? 'Screenshot of `$selector`'
        : (fullPage ? 'Screenshot of the full page' : 'Screenshot');
    return _recorded(
      'screenshot',
      what,
      () async {
        final page = _require().page;
        if (selector == null) return page.screenshot(fullPage: fullPage);
        final described = await page.describeSelector(selector);
        return page.screenshot(clip: described.box);
      },
      describe: (png) =>
          BrowserAction(verb: 'screenshot', summary: what, png: png),
    );
  }

  /// Elements matching a CSS [selector] or their visible [text].
  Future<FindResult> findElements({
    String? selector,
    String? text,
    bool exact = false,
    bool visibleOnly = true,
    int limit = 25,
  }) async => _recorded(
    'find',
    'Searched for ${selector ?? '"${text ?? ''}"'}',
    () => _require().input.find(
      selector: selector,
      text: text,
      exact: exact,
      visibleOnly: visibleOnly,
      limit: limit,
    ),
    describe: (found) => BrowserAction(
      verb: 'find',
      summary:
          '${found.total} match${found.total == 1 ? '' : 'es'} for '
          '${found.query}',
      detail: found.elements.isEmpty ? null : found.indexedListing(max: 10),
    ),
  );

  Future<ClickResult> click({
    String? selector,
    String? text,
    bool exact = false,
    int? index,
    int clickCount = 1,
  }) async => _recorded(
    'click',
    'Clicked ${selector ?? '"${text ?? ''}"'}',
    () => _require().input.click(
      selector: selector,
      text: text,
      exact: exact,
      index: index,
      clickCount: clickCount,
    ),
    describe: (result) => BrowserAction(
      verb: 'click',
      summary: 'Clicked ${result.element.toListing()}',
      detail:
          'at (${result.x.round()}, ${result.y.round()}) in the viewport'
          '${result.element.disabled ? ' — the element is disabled' : ''}',
    ),
  );

  /// Types [text] with real key events, into [selector] when one is given and
  /// otherwise into whatever has focus.
  Future<TypeResult> type(
    String text, {
    String? selector,
    String? targetText,
    bool exact = false,
    int? index,
    bool submit = false,
  }) async => _recorded(
    'type',
    'Typed "$text"',
    () => _require().input.type(
      text,
      selector: selector,
      targetText: targetText,
      exact: exact,
      index: index,
      submit: submit,
    ),
    describe: (result) => _typeAction('Typed', result, submit),
  );

  /// Replaces a field's contents with [value] and reads back what it holds.
  Future<TypeResult> fill({
    String? selector,
    String? text,
    bool exact = false,
    int? index,
    required String value,
    bool submit = false,
  }) async => _recorded(
    'type',
    'Filled with "$value"',
    () => _require().input.fill(
      selector: selector,
      text: text,
      exact: exact,
      index: index,
      value: value,
      submit: submit,
    ),
    describe: (result) => _typeAction('Filled', result, submit),
  );

  /// Presses a named key in the page — `enter`, `tab`, `escape`, `arrowDown`…
  Future<void> pressKey(String key) async =>
      _recorded('key', 'Pressed $key', () => _require().input.pressKey(key));

  Future<void> scrollBy({double dx = 0, double dy = 0}) async => _recorded(
    'other',
    'Scrolled by (${dx.round()}, ${dy.round()})',
    () => _require().input.scrollBy(dx: dx, dy: dy),
  );

  /// Where the attached page is now, read from the page itself.
  Future<String> currentUrl() async => _require().page.currentUrl();

  /// The attached page's title, read from the page itself.
  Future<String> currentTitle() async => _require().page.currentTitle();

  Future<List<BrowserTarget>> listTargets() async =>
      _require().endpoint.http.listTargets();

  /// Opens a new tab; the session keeps driving its current page.
  Future<BrowserTarget> openTab(String url) async =>
      _require().endpoint.http.openTab(url);

  /// Runs [action], telling [actionSink] what happened either way. A failure is
  /// reported *and* rethrown: the refusal is evidence a verification run needs.
  Future<T> _recorded<T>(
    String verb,
    String summary,
    Future<T> Function() action, {
    BrowserAction Function(T result)? describe,
  }) async {
    if (actionSink == null) return action();
    try {
      final result = await action();
      _report(
        describe?.call(result) ?? BrowserAction(verb: verb, summary: summary),
      );
      return result;
    } on Object catch (error) {
      _report(BrowserAction(verb: verb, summary: summary).failed(error));
      rethrow;
    }
  }

  /// Reports to the sink without letting a recorder's own fault break the
  /// browser call it was watching.
  void _report(BrowserAction action) {
    final sink = actionSink;
    if (sink == null) return;
    try {
      sink(action);
    } on Object {
      // Recording is observation. It never decides whether driving succeeded.
    }
  }

  BrowserAction _captureAction(ElementCapture capture, String summary) =>
      BrowserAction(
        verb: 'capture',
        summary: summary,
        png: capture.screenshotPng,
        text: capture.toPromptText(),
        pageUrl: capture.pageUrl,
      );

  BrowserAction _typeAction(
    String did,
    TypeResult result,
    bool submit,
  ) => BrowserAction(
    verb: 'type',
    summary:
        '$did "${result.text}"'
        '${result.element == null ? '' : ' into ${result.element!.toListing()}'}'
        '${submit ? ', then Enter' : ''}',
    detail: result.value == null
        ? 'The field could not be read back.'
        : (result.matches
              ? 'The field now holds exactly that.'
              : 'The field now holds "${result.value}", which is NOT what '
                    'was sent.'),
    ok: result.value == null || result.matches,
  );

  static String _short(String value) {
    final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 60 ? flat : '${flat.substring(0, 57)}…';
  }

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
