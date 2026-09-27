import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_browser/browser.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../data/runs_work.dart';
import '../server/gui_session.dart';
import 'server_browser_consent.dart';

/// The Chrome the server drives over CDP (slice 3d): the person's own
/// window beside a local server, a headless one on a box with no desktop.
/// Every client's pane and every agent's `browser_*` tool drive this one
/// [service]; what it now shows is told to every client as
/// [BrowserStateChanged].
///
/// A browser the server launched lives until [close] — the server's exit —
/// which kills it and deletes its throwaway profile. One it attached to is
/// the person's and is never killed.
class ServerBrowser implements BrowserWork {
  ServerBrowser({
    required AppDatabase database,
    required String dataDirectory,
    required void Function(List<DataChange> changes) tell,
    required Map<String, String> hostEnvironment,
    String? operatingSystem,
    BrowserService? service,
    CommandRunner runner = const LocalCommandRunner(),
    this.port = BrowserLauncher.defaultPort,
    DateTime Function()? clock,
  }) : headless = !hasGuiSession(
         hostEnvironment,
         operatingSystem: operatingSystem ?? Platform.operatingSystem,
       ),
       _tell = tell,
       _captures = p.join(dataDirectory, 'captures'),
       _now = clock ?? DateTime.now,
       consent = ServerBrowserConsent(database) {
    this.service =
        service ??
        BrowserService(
          startProcess: browserProcessStarter(runner),
          launcher: BrowserLauncher(
            startProcess: browserProcessStarter(runner),
            headless: headless,
          ),
        );
    _state = BrowserState(port: port, headless: headless);
  }

  /// No window can open on this machine: pages are seen as screenshots, and
  /// nothing can be picked by hand.
  final bool headless;
  final int port;
  late final BrowserService service;
  final ServerBrowserConsent consent;
  final void Function(List<DataChange> changes) _tell;
  final String _captures;
  final DateTime Function() _now;

  late BrowserState _state;
  BrowserSession? _watched;
  StreamSubscription<void>? _watch;
  final _spawned = <int, BrowserEndpoint>{};
  var _closed = false;

  BrowserState get state => _state;

  /// Why a pick is refused on a machine with no window.
  static const String headlessPickRefusal =
      'The Karmashala server runs this browser headless — its machine has no '
      'desktop — so there is no window for anyone to click an element in. '
      'Use browser_find, browser_capture or browser_screenshot instead.';

  @override
  List<DataChange> greeting() => [
    // Only a browser in use (or one that failed): an idle one says nothing.
    if (_state.status != BrowserStatus.disconnected || _state.error != null)
      BrowserStateChanged(_state),
  ];

  @override
  Future<Object?> handle(BrowserWorkRequest<Object?> request) async =>
      switch (request) {
        BrowserStateGet() => _state,
        BrowserConnect(:final spawn, :final url) => connect(
          spawn: spawn,
          url: url,
        ),
        BrowserDisconnect() => disconnect(),
        BrowserNavigate(:final url) => navigate(url),
        BrowserTabs() => refreshTabs(),
        BrowserSelectTab(:final targetId) => selectTab(targetId),
        BrowserScreenshot() => _refused(() => service.screenshot()),
        BrowserPickElement() => pick(),
        BrowserCancelPick() => _cancelPick(),
        BrowserEvaluate(:final expression) => _refused(
          () async => _renderValue(await service.evaluate(expression)),
        ),
        BrowserFind(:final selector, :final text, :final limit) => _refused(
          () async => _renderMatches(
            await service.findElements(
              selector: selector,
              text: text,
              limit: limit,
            ),
            limit,
          ),
        ),
      };

  /// Attaches to the browser on [port], launching one when [spawn] and
  /// nothing listens.
  Future<BrowserState> connect({bool spawn = true, String? url}) async {
    _stopWatching();
    _set(_state.copyWith(status: BrowserStatus.connecting, clearError: true));
    try {
      final session = await service.connect(
        port: port,
        spawnIfNeeded: spawn,
        url: url == null || url.isEmpty ? null : normalizeUrl(url),
      );
      _set(
        _state.copyWith(
          status: BrowserStatus.connected,
          connection: session.endpoint.description,
          currentTargetId: session.page.target.id,
        ),
      );
    } on Object catch (error) {
      _set(
        BrowserState(port: port, headless: headless, error: _message(error)),
      );
      throw DataRefused(DataRefusalCode.failed, _message(error));
    }
    await afterUse();
    return _state;
  }

  Future<BrowserState> disconnect() async {
    _stopWatching();
    await service.disconnect();
    _set(BrowserState(port: port, headless: headless));
    return _state;
  }

  /// Goes to [url], connecting first when nothing is attached.
  Future<BrowserState> navigate(String url) async {
    if (url.trim().isEmpty) return _state;
    if (!service.isConnected) return connect(url: url);
    return _run(() => service.navigate(normalizeUrl(url)));
  }

  Future<BrowserState> refreshTabs() async {
    await afterUse();
    return _state;
  }

  /// Drives tab [targetId] of the same browser.
  Future<BrowserState> selectTab(String targetId) async {
    if (targetId == _state.currentTargetId && service.isConnected) {
      return _state;
    }
    _stopWatching();
    return _run(() async {
      await service.connect(
        port: service.session?.endpoint.port ?? port,
        spawnIfNeeded: false,
        targetId: targetId,
      );
    });
  }

  /// Hands the page to a person to click an element in; refused headless.
  Future<BrowserPick> pick() async {
    if (headless) {
      throw const DataRefused(DataRefusalCode.invalid, headlessPickRefusal);
    }
    if (!service.isConnected) {
      throw DataRefused(
        DataRefusalCode.failed,
        describeBrowserFailure(BrowserFailure.notRunning, port: port),
      );
    }
    _set(_state.copyWith(status: BrowserStatus.picking, clearError: true));
    try {
      final capture = await service.pickElement();
      _set(
        _state.copyWith(
          status: BrowserStatus.connected,
          url: capture.pageUrl,
          title: capture.pageTitle,
        ),
      );
      return BrowserPick(capture, captureFile: _writeCapture(capture));
    } on Object catch (error) {
      _set(
        _state.copyWith(
          status: service.isConnected
              ? BrowserStatus.connected
              : BrowserStatus.disconnected,
          error: _message(error),
        ),
      );
      throw DataRefused(DataRefusalCode.failed, _message(error));
    }
  }

  DataAck _cancelPick() {
    service.cancelPick();
    return const DataAck();
  }

  /// After anything drove [service] — a pane, an agent's tool, a
  /// verification run: reads where it is and its tabs, remembers a browser
  /// it launched, watches the session for its end, and tells every client.
  Future<void> afterUse() async {
    final session = service.session;
    if (session == null || !service.isConnected) {
      _stopWatching();
      if (_state.status != BrowserStatus.disconnected) {
        _set(BrowserState(port: port, headless: headless, error: _state.error));
      }
      return;
    }
    if (session.endpoint.mode == BrowserConnectionMode.spawned) {
      _spawned[session.endpoint.port] = session.endpoint;
    }
    _watchForDeath(session);
    var next = _state.copyWith(
      status: _state.status == BrowserStatus.picking
          ? BrowserStatus.picking
          : BrowserStatus.connected,
      connection: session.endpoint.description,
      currentTargetId: session.page.target.id,
    );
    try {
      next = next.copyWith(
        url: await service.currentUrl(),
        title: await service.currentTitle(),
      );
    } on BrowserException {
      // Where the page is is a nicety; the action that worked still did.
    }
    try {
      final targets = await service.listTargets();
      next = next.copyWith(
        tabs: [
          for (final target in targets)
            if (target.isDrivablePage)
              BrowserTab(id: target.id, title: target.title, url: target.url),
        ],
      );
    } on Object {
      // The tab list keeps what it had.
    }
    _set(next);
  }

  /// Lets go of the page and ends every browser the server launched. The
  /// person's own browser, attached to, is left running.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stopWatching();
    try {
      await service.disconnect();
    } on Object {
      // Going anyway.
    }
    final spawned = [..._spawned.values];
    _spawned.clear();
    for (final endpoint in spawned) {
      await endpoint.shutDown();
    }
  }

  Future<BrowserState> _run(Future<void> Function() action) async {
    _set(_state.copyWith(status: BrowserStatus.busy, clearError: true));
    try {
      await action();
    } on Object catch (error) {
      _set(
        _state.copyWith(
          status: service.isConnected
              ? BrowserStatus.connected
              : BrowserStatus.disconnected,
          error: _message(error),
        ),
      );
      throw DataRefused(DataRefusalCode.failed, _message(error));
    }
    await afterUse();
    return _state;
  }

  Future<T> _refused<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DataRefused {
      rethrow;
    } on Object catch (error) {
      throw DataRefused(DataRefusalCode.failed, _message(error));
    }
  }

  void _set(BrowserState next) {
    if (next.sameAs(_state)) return;
    _state = next;
    if (!_closed) _tell([BrowserStateChanged(next)]);
  }

  void _stopWatching() {
    _watched = null;
    unawaited(_watch?.cancel());
    _watch = null;
  }

  /// The browser going away stops the pane claiming a connection.
  void _watchForDeath(BrowserSession session) {
    if (identical(_watched, session)) return;
    _stopWatching();
    _watched = session;
    _watch = session.done.asStream().listen((_) {
      if (!identical(_watched, session) || service.isConnected) return;
      _watched = null;
      _set(
        BrowserState(
          port: port,
          headless: headless,
          error: describeBrowserFailure(BrowserFailure.disconnected),
        ),
      );
    });
  }

  /// The capture's picture, beside the server's data, where the agents that
  /// read the prompt run.
  String? _writeCapture(ElementCapture capture) {
    final png = capture.screenshotPng;
    if (png == null) return null;
    try {
      final directory = Directory(_captures)..createSync(recursive: true);
      final file = File(
        p.join(directory.path, 'element_${_now().microsecondsSinceEpoch}.png'),
      )..writeAsBytesSync(png, flush: true);
      return file.path;
    } on FileSystemException {
      return null;
    }
  }

  static String _message(Object error) => switch (error) {
    BrowserException(:final message) => message,
    DataRefused(:final message) => message,
    _ => '$error',
  };

  /// `localhost:3000` gets a scheme, so it is not read as the scheme
  /// `localhost`; a real URL, or an about:/data: one, is left alone.
  static String normalizeUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return trimmed;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed)) {
      return trimmed;
    }
    for (final scheme in const ['about:', 'data:', 'chrome:', 'view-source:']) {
      if (trimmed.toLowerCase().startsWith(scheme)) return trimmed;
    }
    return 'http://$trimmed';
  }

  static String _renderValue(Object? value) =>
      value == null ? 'null' : '$value';

  static String _renderMatches(FindResult found, int shown) {
    if (found.elements.isEmpty) {
      // "Nothing matched" and "everything that matched is hidden" differ.
      return found.hidden > 0
          ? 'No visible match for ${found.query} — ${found.hidden} matched and '
                'were hidden.'
          : 'No match for ${found.query}.';
    }
    final notShown = found.total - found.elements.length;
    return [
      '${found.total} match${found.total == 1 ? '' : 'es'} for ${found.query}',
      found.indexedListing(max: shown),
      if (notShown > 0) '… $notShown more not listed',
      if (found.hidden > 0) '${found.hidden} hidden match(es) not counted here',
    ].join('\n');
  }
}

/// A [ProcessHandle] seen as the four things [BrowserLauncher] reads.
class _HandleAsBrowserProcess implements BrowserProcess {
  const _HandleAsBrowserProcess(this._handle);

  final ProcessHandle _handle;

  @override
  Stream<String> get stdoutLines => _handle.stdoutLines;

  @override
  Stream<String> get stderrLines => _handle.stderrLines;

  @override
  Future<int> get exitCode => _handle.exitCode;

  @override
  Future<void> kill() => _handle.kill();
}

/// The browser package spawns nothing itself; this starts Chrome through the
/// server's own runner.
BrowserProcessStarter browserProcessStarter(CommandRunner runner) =>
    (String executable, List<String> arguments) async {
      try {
        return _HandleAsBrowserProcess(
          await runner.start(
            CommandRequest(executable: executable, arguments: arguments),
          ),
        );
      } on CommandException catch (e) {
        throw BrowserProcessException(e.message, cause: e);
      }
    };
