import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/terminal_instance.dart';
import '../domain/terminal_profile.dart';

/// The production factory: each terminal tab is backed by a real ConPTY.
final terminalInstanceFactoryProvider = Provider<TerminalInstanceFactory>(
  (ref) => createPtyTerminalInstance,
);

/// Open terminal tabs and which one is active.
class TerminalSessionsState {
  const TerminalSessionsState({this.sessions = const [], this.activeId});

  final List<TerminalInstance> sessions;
  final String? activeId;

  bool get isEmpty => sessions.isEmpty;

  TerminalInstance? get active {
    for (final s in sessions) {
      if (s.id == activeId) return s;
    }
    return null;
  }
}

/// Manages the set of open terminal tabs: opening new ones for a chosen
/// [TerminalProfile], switching between them, and closing them (disposing the
/// backing PTY). Tab buffers stay alive while open so scrollback is preserved.
class TerminalSessionsController extends Notifier<TerminalSessionsState> {
  int _seq = 0;

  // The live instances, owned here (not read from `state` during onDispose,
  // which Riverpod forbids).
  final List<TerminalInstance> _open = [];

  @override
  TerminalSessionsState build() {
    ref.onDispose(() {
      for (final s in _open) {
        s.dispose();
      }
      _open.clear();
    });
    return const TerminalSessionsState();
  }

  /// Opens a new tab running [profile] (optionally starting at [workingDirectory])
  /// and makes it active. Returns the new tab's id.
  String open(TerminalProfile profile, {String? workingDirectory}) {
    final id = 't${_seq++}';
    final factory = ref.read(terminalInstanceFactoryProvider);
    _open.add(
      factory(id: id, profile: profile, workingDirectory: workingDirectory),
    );
    state = TerminalSessionsState(sessions: List.of(_open), activeId: id);
    return id;
  }

  void activate(String id) {
    if (state.activeId == id) return;
    state = TerminalSessionsState(sessions: state.sessions, activeId: id);
  }

  /// Closes the tab [id], disposing its PTY. If it was active, the previous tab
  /// becomes active (or none, if it was the last).
  void close(String id) {
    TerminalInstance? closed;
    _open.removeWhere((s) {
      if (s.id == id) {
        closed = s;
        return true;
      }
      return false;
    });
    closed?.dispose();
    var activeId = state.activeId;
    if (activeId == id) {
      activeId = _open.isEmpty ? null : _open.last.id;
    }
    state = TerminalSessionsState(sessions: List.of(_open), activeId: activeId);
  }
}

final terminalSessionsControllerProvider =
    NotifierProvider<TerminalSessionsController, TerminalSessionsState>(
      TerminalSessionsController.new,
    );

/// Whether the terminal panel is visible.
class TerminalVisibleController extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
  void set(bool value) => state = value;
}

final terminalVisibleProvider =
    NotifierProvider<TerminalVisibleController, bool>(
      TerminalVisibleController.new,
    );
