import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:karmashala_core/logging.dart';

/// **The keyboard goes back where it was when the window comes back**
/// (owner, 2026-09-30 and again 2026-10-01: after switching to another app
/// and back, the first key typed was lost; the second worked).
///
/// When the window loses focus Flutter parks the keyboard on the root scope
/// (`_ViewState.didChangeViewFocus`, and `FocusManager._appLifecycleChange`
/// does the same on `inactive`), and gives it back to the last focused node
/// when focus returns. Both give it back *asynchronously* — a request that
/// lands in a microtask, the lifecycle half a posted task later (the Windows
/// embedder's `WindowsLifecycleManager::OnWindowStateEvent`) — so nothing
/// guarantees the keyboard is back before the first key is dispatched. A key
/// that reaches a scope reaches no pane and no text field: nothing types it,
/// the engine hands it to a text-input client that was closed on the way
/// out, and it is gone.
///
/// This is an early key handler, so it runs before the focus tree is walked:
/// a key-down that finds the keyboard parked, with a node it was parked from
/// still mounted, puts focus back on that node *now* and lets the walk that
/// follows deliver the key to it. Only focus the window's going took is
/// given back: a scope focused on purpose (a click on empty chrome, an
/// unfocus) is left alone.
///
/// One info line per return to the window says where the first keys went —
/// the evidence for whether a key was lost before it ever reached the app.
class KeyboardFocusKeeper with WidgetsBindingObserver {
  KeyboardFocusKeeper._();

  static KeyboardFocusKeeper? _installed;
  static final _log = AppLogger.named('keyboard.focus');

  /// Installs the keeper once, for the process. Desktop only: a phone has no
  /// window that loses focus to another app's.
  static void install() {
    if (_installed != null) return;
    final keeper = _installed = KeyboardFocusKeeper._();
    WidgetsBinding.instance.addObserver(keeper);
    FocusManager.instance.addListener(keeper._onFocusChanged);
    FocusManager.instance.addEarlyKeyEventHandler(keeper._onKey);
  }

  /// The last node that held the keyboard itself, not a scope.
  FocusNode? _leaf;

  /// The node the window's losing focus took the keyboard from; cleared the
  /// moment any node holds it again.
  FocusNode? _parked;

  /// What the view last said. A key while this is false came before the
  /// window's focus event.
  bool _windowFocused = true;

  /// From the window's focus event to the keys that followed it.
  Stopwatch? _sinceFocus;
  int? _restoredAfterMs;
  final _firstKeys = <String>[];
  int _keyDowns = 0;
  bool _reporting = false;

  void _onFocusChanged() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary is FocusScopeNode) return;
    if (_reporting && _restoredAfterMs == null && primary == _parked) {
      _restoredAfterMs = _sinceFocus?.elapsedMilliseconds;
    }
    _leaf = primary;
    _parked = null;
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    switch (event.state) {
      case ViewFocusState.unfocused:
        _windowFocused = false;
        _parked = _leaf;
        _endReport();
      case ViewFocusState.focused:
        _windowFocused = true;
        _sinceFocus = Stopwatch()..start();
        _restoredAfterMs = null;
        _firstKeys.clear();
        _keyDowns = 0;
        _reporting = true;
    }
  }

  KeyEventResult _onKey(KeyEvent event) {
    final primary = FocusManager.instance.primaryFocus;
    final parked = _parked;
    final parkedNow = primary == null || primary is FocusScopeNode;
    final give =
        event is KeyDownEvent &&
        parkedNow &&
        parked != null &&
        _canTake(parked);
    _note(event, primary, gaveBack: give);
    if (!give) return KeyEventResult.ignored;
    _parked = null;
    parked.requestFocus();
    // Applied now, not in the microtask a request waits for: the focus walk
    // for this very key starts as soon as the early handlers return.
    FocusManager.instance.applyFocusChangesIfNeeded();
    return KeyEventResult.ignored;
  }

  static bool _canTake(FocusNode node) {
    final context = node.context;
    return context != null &&
        context.mounted &&
        node.canRequestFocus &&
        node.enclosingScope != null;
  }

  /// Adds [event] to the report of the first keys after a return, and logs
  /// it once the second key-down is in. Says whether a key was printable, not
  /// what it was: the first key after a switch can be a password's.
  void _note(KeyEvent event, FocusNode? primary, {required bool gaveBack}) {
    if (!_windowFocused && event is KeyDownEvent) {
      _log.info(
        'a key-down arrived before the window said it had focus; the '
        'keyboard was on ${_describe(primary)}',
      );
    }
    if (!_reporting) return;
    final character = event.character;
    final printable = character != null && character.isNotEmpty;
    final kind = switch (event) {
      KeyDownEvent() => 'down',
      KeyRepeatEvent() => 'repeat',
      _ => 'up',
    };
    final key = printable ? 'printable' : event.logicalKey.keyLabel;
    final where = gaveBack
        ? '${_describe(primary)}, given back to the node it had'
        : _describe(primary);
    _firstKeys.add(
      '$kind $key${event.synthesized ? ' (synthesized)' : ''} → $where'
      ' at ${_sinceFocus?.elapsedMilliseconds}ms',
    );
    if (event is KeyDownEvent) _keyDowns++;
    if (_keyDowns >= 2 || _firstKeys.length >= 6) _endReport();
  }

  void _endReport() {
    if (!_reporting) return;
    _reporting = false;
    if (_firstKeys.isEmpty) return;
    final restored = _restoredAfterMs;
    _log.info(
      'first keys after the window came back '
      '(keyboard ${restored == null ? 'not given back by Flutter before them' : 'given back at ${restored}ms'}): '
      '${_firstKeys.join('; ')}',
    );
    _firstKeys.clear();
  }

  String _describe(FocusNode? node) {
    if (node == null) return 'nothing';
    final label = node.debugLabel;
    final named = label == null ? '' : ' "$label"';
    if (node == FocusManager.instance.rootScope) return 'the root scope';
    if (node is FocusScopeNode) return 'a scope$named';
    if (node == _leaf) return 'the node it had before$named';
    return 'another node$named';
  }
}
