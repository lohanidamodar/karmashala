import 'dart:async';

import 'package:karmashala_browser/browser.dart' show ElementCapture;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../notifications/application/notification_providers.dart';
import '../data/browser_data.dart';

/// Everything the browser pane renders: the server's browser, and what this
/// pane picked and sent.
class BrowserPaneState {
  const BrowserPaneState({
    this.browser = const BrowserState(),
    this.error,
    this.capture,
    this.captureFile,
    this.sentToSession,
  });

  /// The Chrome the server drives, as it last said.
  final BrowserState browser;

  /// The failure to show — a refusal this pane got, or the server's last.
  final String? error;
  final ElementCapture? capture;

  /// Where the server wrote the capture's picture, on its own machine.
  final String? captureFile;

  /// A short confirmation of the last "send to session", shown then dropped.
  final String? sentToSession;

  BrowserStatus get status => browser.status;
  String? get connection => browser.connection;
  int get port => browser.port;
  String get url => browser.url;
  String get title => browser.title;
  List<BrowserTab> get tabs => browser.tabs;
  String? get currentTargetId => browser.currentTargetId;

  /// A server with no window: screenshots only, nothing to pick in.
  bool get headless => browser.headless;
  bool get isConnected => browser.isConnected;
  bool get isBusy => browser.isBusy;

  BrowserPaneState copyWith({
    BrowserState? browser,
    String? error,
    ElementCapture? capture,
    String? captureFile,
    String? sentToSession,
    bool clearError = false,
    bool clearCapture = false,
    bool clearSent = false,
  }) => BrowserPaneState(
    browser: browser ?? this.browser,
    error: clearError ? null : (error ?? this.error),
    capture: clearCapture ? null : (capture ?? this.capture),
    captureFile: clearCapture ? null : (captureFile ?? this.captureFile),
    sentToSession: clearSent ? null : (sentToSession ?? this.sentToSession),
  );
}

/// The pane's side of the server's browser: every action is a request, and
/// what the browser then is arrives as the server's change, to every pane.
class BrowserPaneController extends Notifier<BrowserPaneState> {
  @override
  BrowserPaneState build() {
    final data = ref.watch(browserDataProvider);
    final changes = data.changes.listen(_follow);
    ref.onDispose(changes.cancel);
    return BrowserPaneState(browser: data.state, error: data.state.error);
  }

  BrowserData get _data => ref.read(browserDataProvider);

  void _follow(BrowserState browser) {
    final changedError = browser.error != state.browser.error;
    state = state.copyWith(
      browser: browser,
      error: changedError ? browser.error : null,
      clearError: changedError && browser.error == null,
    );
  }

  Future<void> connect({bool spawn = true, String? url}) =>
      _run(() => _data.connect(spawn: spawn, url: url));

  Future<void> disconnect() => _run(_data.disconnect);

  /// Goes to [url]; the server connects first when nothing is attached.
  Future<void> navigate(String url) async {
    if (url.trim().isEmpty) return;
    await _run(() => _data.navigate(url.trim()));
  }

  /// Hands the page to the person to point at an element, and takes the
  /// window back. Refused in words on a headless server.
  Future<void> pickElement() async {
    if (!state.isConnected) return;
    state = state.copyWith(
      clearError: true,
      clearCapture: true,
      clearSent: true,
    );
    try {
      final pick = await _data.pick();
      state = state.copyWith(
        capture: pick.capture,
        captureFile: pick.captureFile,
      );
      ref.read(windowRaiseRequestProvider.notifier).bump();
    } on DataRefused catch (refusal) {
      state = state.copyWith(error: refusal.message);
    }
  }

  void cancelPick() => unawaited(_data.cancelPick().catchError((Object _) {}));

  /// Re-reads the browser's tab list; a list that could not be read keeps
  /// what it had.
  Future<void> refreshTabs() async {
    if (!state.isConnected) return;
    try {
      _follow(await _data.tabs());
    } on DataRefused {
      // The dropdown keeps what it had.
    }
  }

  /// Drives a different tab in the same browser.
  Future<void> selectTab(String targetId) async {
    if (targetId == state.currentTargetId) return;
    state = state.copyWith(clearCapture: true);
    await _run(() => _data.selectTab(targetId));
  }

  /// The captured element as prompt text, with the picture's path on the
  /// server's machine — where the agents that read it run.
  String? capturePrompt() {
    final capture = state.capture;
    if (capture == null) return null;
    return BrowserPick(capture, captureFile: state.captureFile).promptText;
  }

  void noteSent(String message) =>
      state = state.copyWith(sentToSession: message);

  void clearCapture() =>
      state = state.copyWith(clearCapture: true, clearSent: true);

  void clearError() => state = state.copyWith(clearError: true);

  Future<void> _run(Future<BrowserState> Function() action) async {
    state = state.copyWith(clearError: true);
    try {
      _follow(await action());
    } on DataRefused catch (refusal) {
      state = state.copyWith(error: refusal.message);
    }
  }
}

final browserPaneControllerProvider =
    NotifierProvider<BrowserPaneController, BrowserPaneState>(
      BrowserPaneController.new,
    );
