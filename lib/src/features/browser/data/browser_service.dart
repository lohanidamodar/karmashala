import 'dart:async';
import 'dart:typed_data';

import '../../../core/process/command_runner.dart';
import '../domain/browser_action.dart';
import '../domain/browser_failure.dart';
import '../domain/browser_target.dart';
import '../domain/element_capture.dart';
import '../domain/found_element.dart';
import 'browser_launcher.dart';
import 'cdp_connection.dart';
import 'cdp_page.dart';
import 'cdp_socket.dart';
import 'element_picker.dart';
import 'page_input.dart';
import 'page_observer.dart';

/// An attached browser plus the page we are driving in it.
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

  /// Clicking, typing and filling in the attached page.
  final PageInput input;

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
  PageObserver? _observer;
  bool _observeRequested = false;

  /// Who is recording what this service does, or null for nobody.
  ///
  /// A seam rather than a recording subclass: the pane, the MCP tools and any
  /// harness all drive this one object, so installing a sink here records all
  /// of them without a second implementation to keep in step.
  BrowserActionSink? actionSink;

  /// The active session, or null when not connected.
  BrowserSession? get session => _session;

  /// Watching the page's console and network, when something asked for it.
  PageObserver? get observer => _observer;

  /// Whether there is a session and its browser is still alive.
  bool get isConnected => _session?.isConnected ?? false;

  /// Starts collecting console errors and failed requests from the attached
  /// page.
  ///
  /// Switching tab or reconnecting re-points **the same** collector at the new
  /// page rather than making a second one, so a navigation part-way through a
  /// run does not quietly discard the errors that came before it.
  Future<void> startObserving() async {
    _observeRequested = true;
    final observer = _observer ??= PageObserver();
    await observer.watch(_require().page);
  }

  /// Stops collecting. **What was already collected stays readable** through
  /// [observer] — a caller stops the watch and then writes down what it saw,
  /// and losing the evidence at that exact moment would be the whole point.
  Future<void> stopObserving() async {
    _observeRequested = false;
    await _observer?.stop();
  }

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
      input: PageInput(page),
    );
    _session = session;

    // A run that asked to watch the console keeps watching across a reconnect
    // or a tab switch; otherwise switching tab would silently stop collecting.
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
  }) async => _recorded(
    'navigate',
    'Navigated to $url',
    () => _require().page.navigate(url, timeout: timeout),
  );

  /// Evaluates JavaScript in the attached page and returns its value.
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

  /// How many elements match [selector] in the attached page.
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

  /// Abandons a pick in progress.
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

  /// Clicks the element matching [selector] or visible [text].
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

  /// Scrolls the page by a wheel gesture.
  Future<void> scrollBy({double dx = 0, double dy = 0}) async => _recorded(
    'other',
    'Scrolled by (${dx.round()}, ${dy.round()})',
    () => _require().input.scrollBy(dx: dx, dy: dy),
  );

  /// Where the attached page is now, read from the page itself.
  Future<String> currentUrl() async => _require().page.currentUrl();

  /// The attached page's title, read from the page itself.
  Future<String> currentTitle() async => _require().page.currentTitle();

  /// Every debuggable target the browser reports.
  Future<List<BrowserTarget>> listTargets() async =>
      _require().endpoint.http.listTargets();

  /// Opens a new tab; the session keeps driving its current page.
  Future<BrowserTarget> openTab(String url) async =>
      _require().endpoint.http.openTab(url);

  // --- Recording -------------------------------------------------------------

  /// Runs [action], telling [actionSink] what happened either way.
  ///
  /// A failure is reported *and* rethrown: "the click was refused because a
  /// banner covered the button" is evidence a verification run needs, and
  /// swallowing it here would also change how every existing caller behaves.
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
