import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/browser_service.dart';
import '../domain/browser_failure.dart';
import '../domain/browser_target.dart';
import '../domain/element_capture.dart';
import 'browser_providers.dart';

/// What the pane is doing, so it can say so instead of guessing.
enum BrowserPaneStatus {
  /// No session. The browser may well be open; we are not attached to it.
  disconnected,

  /// Attaching or launching.
  connecting,

  /// Attached, idle.
  connected,

  /// Attached, with a command in flight.
  busy,

  /// Attached, waiting for the user to click an element in the page.
  picking,
}

/// Everything the browser pane renders.
class BrowserPaneState {
  const BrowserPaneState({
    this.status = BrowserPaneStatus.disconnected,
    this.connection,
    this.port = 9222,
    this.url = '',
    this.title = '',
    this.error,
    this.capture,
    this.captureFile,
    this.tabs = const [],
    this.currentTargetId,
    this.sentToSession,
  });

  final BrowserPaneStatus status;

  /// How we got hold of the browser — "Attached to the browser already
  /// listening on port 9222" or "Launched …". Shown verbatim: whether we are
  /// driving the user's own window or a throwaway one is the difference
  /// between this feature working and this feature lying.
  final String? connection;
  final int port;
  final String url;
  final String title;

  /// The last failure's message, from the [BrowserFailure] taxonomy.
  final String? error;
  final ElementCapture? capture;

  /// Where the capture's screenshot was written, so a prompt can point an
  /// agent at the actual image.
  final String? captureFile;
  final List<BrowserTarget> tabs;
  final String? currentTargetId;

  /// A short confirmation of the last "send to session", shown then dropped.
  final String? sentToSession;

  bool get isConnected =>
      status != BrowserPaneStatus.disconnected &&
      status != BrowserPaneStatus.connecting;

  bool get isBusy =>
      status == BrowserPaneStatus.connecting ||
      status == BrowserPaneStatus.busy;

  BrowserPaneState copyWith({
    BrowserPaneStatus? status,
    String? connection,
    int? port,
    String? url,
    String? title,
    String? error,
    ElementCapture? capture,
    String? captureFile,
    List<BrowserTarget>? tabs,
    String? currentTargetId,
    String? sentToSession,
    bool clearError = false,
    bool clearCapture = false,
    bool clearSent = false,
  }) => BrowserPaneState(
    status: status ?? this.status,
    connection: connection ?? this.connection,
    port: port ?? this.port,
    url: url ?? this.url,
    title: title ?? this.title,
    error: clearError ? null : (error ?? this.error),
    capture: clearCapture ? null : (capture ?? this.capture),
    captureFile: clearCapture ? null : (captureFile ?? this.captureFile),
    tabs: tabs ?? this.tabs,
    currentTargetId: currentTargetId ?? this.currentTargetId,
    sentToSession: clearSent ? null : (sentToSession ?? this.sentToSession),
  );
}

/// Drives [BrowserService] for the pane.
///
/// Every action funnels through [_run], which is the only place a failure can
/// be turned into state: a [BrowserException]'s message goes onto the pane
/// unchanged, because those messages were written to be read by a person and
/// flattening them to "something went wrong" throws away the whole taxonomy.
class BrowserPaneController extends Notifier<BrowserPaneState> {
  StreamSubscription<void>? _watch;

  @override
  BrowserPaneState build() {
    final port = ref.watch(browserDebugPortProvider);
    final service = ref.read(browserServiceProvider);
    ref.onDispose(() => _watch?.cancel());
    if (service.isConnected) {
      final session = service.session!;
      _watchForDeath(session);
      return BrowserPaneState(
        status: BrowserPaneStatus.connected,
        connection: session.endpoint.description,
        port: session.endpoint.port,
        url: session.page.target.url,
        title: session.page.target.title,
        currentTargetId: session.page.target.id,
      );
    }
    return BrowserPaneState(port: port);
  }

  BrowserService get _service => ref.read(browserServiceProvider);

  /// Attaches to a browser on the pane's port, launching one if [spawn] and
  /// nothing is listening.
  Future<void> connect({bool spawn = true, String? url}) async {
    // Stop watching the session we are about to replace: a teardown we asked
    // for must not surface as "the browser disconnected".
    await _stopWatching();
    state = state.copyWith(
      status: BrowserPaneStatus.connecting,
      clearError: true,
    );
    try {
      final session = await _service.connect(
        port: state.port,
        spawnIfNeeded: spawn,
        url: url == null || url.isEmpty ? null : _normalizeUrl(url),
      );
      _watchForDeath(session);
      state = state.copyWith(
        status: BrowserPaneStatus.connected,
        connection: session.endpoint.description,
        currentTargetId: session.page.target.id,
      );
      await _readLocation();
      await refreshTabs();
    } on Object catch (error) {
      state = state.copyWith(
        status: BrowserPaneStatus.disconnected,
        error: _message(error),
      );
    }
  }

  Future<void> disconnect() async {
    await _stopWatching();
    await _service.disconnect();
    state = BrowserPaneState(port: state.port);
  }

  /// Goes to [url], connecting first if we are not attached yet.
  Future<void> navigate(String url) async {
    if (url.trim().isEmpty) return;
    if (!_service.isConnected) {
      await connect(url: url);
      return;
    }
    await _run(() async {
      await _service.navigate(_normalizeUrl(url));
      await _readLocation();
      await refreshTabs();
    });
  }

  /// Hands the page over to the user to point at an element.
  Future<void> pickElement() async {
    if (!_service.isConnected) return;
    state = state.copyWith(
      status: BrowserPaneStatus.picking,
      clearError: true,
      clearCapture: true,
      clearSent: true,
    );
    try {
      final capture = await _service.pickElement();
      state = state.copyWith(
        status: BrowserPaneStatus.connected,
        capture: capture,
        captureFile: _writeScreenshot(capture),
        url: capture.pageUrl,
        title: capture.pageTitle,
      );
    } on Object catch (error) {
      state = state.copyWith(
        status: _service.isConnected
            ? BrowserPaneStatus.connected
            : BrowserPaneStatus.disconnected,
        error: _message(error),
      );
    }
  }

  void cancelPick() {
    _service.cancelPick();
    if (state.status == BrowserPaneStatus.picking) {
      state = state.copyWith(status: BrowserPaneStatus.connected);
    }
  }

  /// Re-reads the browser's tab list.
  Future<void> refreshTabs() async {
    if (!_service.isConnected) return;
    try {
      final targets = await _service.listTargets();
      state = state.copyWith(
        tabs: [
          for (final target in targets)
            if (target.isDrivablePage) target,
        ],
      );
    } on Object {
      // A tab list we could not read is not worth failing the pane over; the
      // dropdown simply keeps what it had.
    }
  }

  /// Drives a different tab in the same browser.
  Future<void> selectTab(String targetId) async {
    if (targetId == state.currentTargetId) return;
    await _stopWatching();
    await _run(() async {
      final session = await _service.connect(
        port: state.port,
        spawnIfNeeded: false,
        targetId: targetId,
      );
      _watchForDeath(session);
      state = state.copyWith(
        connection: session.endpoint.description,
        currentTargetId: targetId,
        clearCapture: true,
      );
      await _readLocation();
    });
  }

  /// The captured element as prompt text, with the screenshot's path when we
  /// managed to write one — an agent can open the file and look at it.
  String? capturePrompt() {
    final capture = state.capture;
    if (capture == null) return null;
    final file = state.captureFile;
    return file == null
        ? capture.toPromptText()
        : '${capture.toPromptText()}\n\nScreenshot file: $file';
  }

  void noteSent(String message) =>
      state = state.copyWith(sentToSession: message);

  void clearCapture() =>
      state = state.copyWith(clearCapture: true, clearSent: true);

  void clearError() => state = state.copyWith(clearError: true);

  Future<void> _run(Future<void> Function() action) async {
    state = state.copyWith(status: BrowserPaneStatus.busy, clearError: true);
    try {
      await action();
      state = state.copyWith(status: BrowserPaneStatus.connected);
    } on Object catch (error) {
      state = state.copyWith(
        status: _service.isConnected
            ? BrowserPaneStatus.connected
            : BrowserPaneStatus.disconnected,
        error: _message(error),
      );
    }
  }

  Future<void> _readLocation() async {
    try {
      state = state.copyWith(
        url: await _service.currentUrl(),
        title: await _service.currentTitle(),
      );
    } on BrowserException {
      // Where we are is a nicety; a failure here must not mask the action that
      // just succeeded.
    }
  }

  Future<void> _stopWatching() async {
    final watch = _watch;
    _watch = null;
    await watch?.cancel();
  }

  /// Notices the browser going away, so the pane stops claiming a connection
  /// it no longer has.
  void _watchForDeath(BrowserSession session) {
    _watch = session.done.asStream().listen((_) {
      if (_service.isConnected) return;
      state = state.copyWith(
        status: BrowserPaneStatus.disconnected,
        error: describeBrowserFailure(BrowserFailure.disconnected),
        tabs: const [],
      );
    });
  }

  /// Written synchronously: it is a few kilobytes, and the pick's result
  /// should land in one state change rather than leaving the pane in a
  /// half-updated state while the disk catches up.
  String? _writeScreenshot(ElementCapture capture) {
    final png = capture.screenshotPng;
    if (png == null) return null;
    try {
      final directory = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}karmashala'
        '${Platform.pathSeparator}captures',
      );
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'element_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      file.writeAsBytesSync(png, flush: true);
      return file.path;
    } on Object {
      return null;
    }
  }

  static String _message(Object error) => switch (error) {
    BrowserException(:final message) => message,
    _ => '$error',
  };

  /// Lets the user type `localhost:3000` instead of a full URL.
  ///
  /// Note the `//`: a bare scheme test would read `localhost:3000` as the
  /// scheme `localhost`, and the browser would refuse it. Only the schemes
  /// that legitimately have no authority are listed separately.
  static String _normalizeUrl(String input) {
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
}

final browserPaneControllerProvider =
    NotifierProvider<BrowserPaneController, BrowserPaneState>(
      BrowserPaneController.new,
    );
