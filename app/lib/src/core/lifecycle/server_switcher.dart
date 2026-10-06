import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_remote/client.dart' show CompanionPairing;
import 'package:riverpod/riverpod.dart';

import '../server/machines.dart';
import 'app_lifecycle.dart';
import 'server_session.dart';

/// The process's one [ServerSwitcher], handed to every session's container
/// (`ServerSession.open`'s overrides). Null where nothing switches (a test).
final serverSwitcherProvider = Provider<ServerSwitcher?>((ref) => null);

/// What the window's root shows: one server's app, the switch in between,
/// or an open that failed with the ways out of it.
sealed class ServerRoot {
  const ServerRoot();
}

/// A server session is open; the app is its container's.
final class ServingServer extends ServerRoot {
  const ServingServer(this.session);
  final ServerSession session;
}

/// Between two sessions: the old one is closing or the next opening.
final class SwitchingServer extends ServerRoot {
  const SwitchingServer(this.name);

  /// The server being switched to, as the screen names it.
  final String name;
}

/// No server session, and none to open: a client that cannot host a server
/// and has no machine chosen. The root shows pairing; a pairing's
/// [ServerSwitcher.switchTo] opens the first session.
final class NoServer extends ServerRoot {
  const NoServer();
}

/// Opening [target] threw. No session is open; the screen offers
/// [previous] — the server in use before — again, another try, or Quit.
final class ServerOpenFailed extends ServerRoot {
  const ServerOpenFailed({
    required this.target,
    required this.error,
    required this.previous,
  });
  final CompanionPairing? target;
  final Object error;
  final CompanionPairing? previous;
}

/// How a [ServerSwitcher.switchTo] ended.
enum ServerSwitchOutcome {
  /// The next server's session is open and the window shows it.
  switched,

  /// Already that server's; nothing done.
  unchanged,

  /// A before-quit guard (unsaved edits, running sessions) kept the session.
  kept,

  /// Another switch is running; one at a time.
  busy,

  /// A quit is in progress; no switch starts, and none finishes into it.
  quitting,

  /// Opening the next server threw; the window shows [ServerOpenFailed].
  failed,

  /// The old session did not close in time: the app relaunches instead.
  relaunched,
}

/// How a switch names a server: "this computer", or its host's name.
String serverNameForSwitch(CompanionPairing? remote) {
  if (remote == null) return 'this computer';
  final name = remote.displayName.trim();
  return name.isEmpty ? 'the server' : name;
}

/// **Switching the server this window is a client of, in process** (plan
/// step 14). A switch is:
///
/// 1. the before-quit guards asked and flushed, the layout saved
///    ([AppLifecycle.prepareToLeave]);
/// 2. the root shows [SwitchingServer], and a frame passes, so no widget
///    reads the old container after it is disposed;
/// 3. the old session left and closed ([AppLifecycle.leaveSession]); one
///    that does not close within its budget falls back to a relaunch;
/// 4. the choice written (`Machines.use`);
/// 5. the next session opened, and the lifecycle and system integration
///    retargeted ([AppLifecycle.adoptSession]);
/// 6. the root shows the new container's app, keyed by its session, and the
///    per-server acts after the first frame start
///    ([ServerSession.startAfterRunApp]).
///
/// What survives is the process's: the window, the tray, the hotkey, the
/// keymap, logging and the memory census. Everything else — every pane,
/// provider and link of the old server — goes, as it did with a relaunch.
/// Only one switch runs at a time, and none while a quit is in progress
/// (the phone's `CompanionSwitcher` rule).
class ServerSwitcher {
  ServerSwitcher({
    required this._open,
    required this._machines,
    required this._nextFrame,
    required this._quit,
    this._relaunch,
    this._onOpened,
    this.hostsServer = true,
    AppLogger? logger,
  }) : _log = logger ?? AppLogger.named('server_switch');

  /// Whether this client has a server of its own to open. Without one, a
  /// switch to null ends in [NoServer], never a local session.
  final bool hostsServer;

  final Future<ServerSession> Function(CompanionPairing? remote) _open;
  final Machines _machines;

  /// Completes once a frame has been drawn, bounded: the old tree must be
  /// gone before its container is.
  final Future<void> Function() _nextFrame;
  final Future<void> Function() _quit;

  /// Restarts the process into the chosen server; null where the app cannot
  /// restart itself, which then carries on in process.
  final Future<void> Function()? _relaunch;
  final void Function(CompanionPairing? remote)? _onOpened;
  final AppLogger _log;

  late final AppLifecycle _lifecycle;
  late final ValueNotifier<ServerRoot> _root;
  CompanionPairing? _active;
  Future<ServerSwitchOutcome>? _switching;
  int _switches = 0;

  /// Takes over the session bootstrap opened for [remote].
  void start(
    ServerSession session, {
    required CompanionPairing? remote,
    required AppLifecycle lifecycle,
  }) {
    _lifecycle = lifecycle;
    _active = remote;
    _root = ValueNotifier<ServerRoot>(ServingServer(session));
  }

  /// Starts with no session: [NoServer], until a pairing switches to one.
  void startWithoutServer({required AppLifecycle lifecycle}) {
    _lifecycle = lifecycle;
    _active = null;
    _root = ValueNotifier<ServerRoot>(const NoServer());
  }

  /// What the window's root shows.
  ValueListenable<ServerRoot> get root => _root;

  /// The paired machines, for the pairing [NoServer] shows.
  Machines get machines => _machines;

  /// The server in use, or null for this computer's own.
  CompanionPairing? get active => _active;

  /// Whether a switch is running.
  bool get isSwitching => _switching != null;

  /// Ends the app from the failure screen, where no session is open.
  Future<void> quit() => _quit();

  /// Makes [next] — null for this computer's own server — the one this
  /// window is a client of, without relaunching.
  Future<ServerSwitchOutcome> switchTo(CompanionPairing? next) {
    final refused = _refusal();
    if (refused != null) return Future.value(refused);
    if (_root.value is ServingServer &&
        next?.hostId.value == _active?.hostId.value) {
      return Future.value(ServerSwitchOutcome.unchanged);
    }
    // No session to leave: straight to opening.
    if (_root.value is NoServer) {
      if (next == null) return Future.value(ServerSwitchOutcome.unchanged);
      return _run(() async {
        await _choose(next);
        return _openInto(next, previous: null);
      });
    }
    return _run(() => _switch(next));
  }

  /// From [ServerOpenFailed]: opens [target], with no session to leave.
  Future<ServerSwitchOutcome> retry(CompanionPairing? target) {
    final refused = _refusal();
    if (refused != null) return Future.value(refused);
    final failed = _root.value;
    if (failed is! ServerOpenFailed) {
      return Future.value(ServerSwitchOutcome.unchanged);
    }
    return _run(() async {
      await _choose(target);
      return _openInto(target, previous: failed.previous);
    });
  }

  ServerSwitchOutcome? _refusal() {
    if (_lifecycle.isShuttingDown) return ServerSwitchOutcome.quitting;
    if (_switching != null) return ServerSwitchOutcome.busy;
    return null;
  }

  Future<ServerSwitchOutcome> _run(Future<ServerSwitchOutcome> Function() go) {
    final running = go();
    _switching = running;
    return running.whenComplete(() => _switching = null);
  }

  Future<ServerSwitchOutcome> _switch(CompanionPairing? next) async {
    final previous = _active;
    final from = serverNameForSwitch(previous);
    final to = next != null || hostsServer
        ? serverNameForSwitch(next)
        : 'the pairing screen';
    _log.info('switch: $from → $to requested.');
    if (!await _lifecycle.prepareToLeave()) {
      _log.info('switch: kept $from — a before-quit guard said no.');
      return ServerSwitchOutcome.kept;
    }
    if (_lifecycle.isShuttingDown) return ServerSwitchOutcome.quitting;

    final watch = Stopwatch()..start();
    // The old tree goes first: nothing may read its container once disposed.
    _root.value = SwitchingServer(to);
    await _settle();

    final closed = await _lifecycle.leaveSession();
    // Quit came while the old session closed: that quit finishes the job.
    if (_lifecycle.isShuttingDown) return ServerSwitchOutcome.quitting;
    await _choose(next);
    if (!closed) {
      final relaunch = _relaunch;
      if (relaunch != null) {
        _log.warning(
          'switch: the session for $from did not close within '
          '${kSwitchCloseBudget.inSeconds} s; relaunching into $to instead.',
        );
        try {
          await relaunch();
          return ServerSwitchOutcome.relaunched;
        } on Object catch (error, stack) {
          _log.warning(
            'switch: the relaunch failed; opening in process.',
            error,
            stack,
          );
        }
      } else {
        _log.warning(
          'switch: the session for $from did not close within '
          '${kSwitchCloseBudget.inSeconds} s; opening $to anyway.',
        );
      }
    }
    final outcome = await _openInto(next, previous: previous);
    _log.info(
      'switch: $from → $to ${outcome.name} in ${watch.elapsedMilliseconds} '
      'ms, in process.',
    );
    return outcome;
  }

  /// Opens [target] into the empty root: the new session adopted and shown,
  /// or [ServerOpenFailed] with [previous] as the way back.
  Future<ServerSwitchOutcome> _openInto(
    CompanionPairing? target, {
    required CompanionPairing? previous,
  }) async {
    if (target == null && !hostsServer) {
      _active = null;
      _root.value = const NoServer();
      _log.info('switch: no machine in use; showing pairing.');
      return ServerSwitchOutcome.switched;
    }
    final name = serverNameForSwitch(target);
    _root.value = SwitchingServer(name);
    final ServerSession session;
    try {
      session = await _open(target);
    } on Object catch (error, stack) {
      _log.warning('switch: opening $name failed.', error, stack);
      // The choice goes back to what worked, so a relaunch meets that.
      await _choose(previous);
      if (!_lifecycle.isShuttingDown) {
        _root.value = ServerOpenFailed(
          target: target,
          error: error,
          previous: previous,
        );
      }
      return ServerSwitchOutcome.failed;
    }
    if (_lifecycle.isShuttingDown) {
      // Quit came while it opened: nothing is shown, and it is released.
      unawaited(session.close(teardownBudget: Duration.zero));
      return ServerSwitchOutcome.quitting;
    }
    await _lifecycle.adoptSession(session);
    _active = target;
    _root.value = ServingServer(session);
    _onOpened?.call(target);
    session.startAfterRunApp(_lifecycle, afterFirstFrame: _nextFrame);
    _switches++;
    // The leak check's reading: resident size after each switch, in the log
    // the owner reads (plan step 14, "Verify by hand").
    final resident = readProcessResident().resident / (1 << 20);
    _log.info(
      'switch #$_switches: now a client of $name; resident '
      '${resident.toStringAsFixed(1)} MB.',
    );
    return ServerSwitchOutcome.switched;
  }

  /// Waits for the frame that unmounts the old tree; bounded by [_nextFrame].
  Future<void> _settle() async {
    try {
      await _nextFrame();
    } on Object catch (error) {
      _log.warning('switch: waiting for a frame failed: $error');
    }
  }

  Future<void> _choose(CompanionPairing? remote) async {
    try {
      await _machines.use(remote?.hostId.value);
    } on Object catch (error) {
      // The switch still happens; only the next launch's choice is stale.
      _log.warning('switch: recording the choice failed: $error');
    }
  }
}
