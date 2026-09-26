import 'dart:async';

import 'package:karmashala_host/lifecycle_client.dart'
    show PaneFacts, PaneTailsWantedMessage;

import '../../sessions/application/host_lifecycle/host_lifecycle_source.dart';
import '../../sessions/application/host_lifecycle/host_lifecycle_subscriber.dart';

/// One terminal pane, as this app sees it: the facts the server is told
/// ([PaneFactsReporter]) and the launched-session rebind reads. A plain value
/// rather than a `TerminalInstance`, so both are drivable with no PTY.
class AdoptablePane {
  const AdoptablePane({
    required this.paneId,
    required this.workingDirectory,
    required this.isLive,
    required this.hostsLaunchedSession,
    this.lastCommandId,
    this.lastCommandLine,
    this.lastCommandRunning = true,
  });

  final String paneId;

  /// Where the pane was opened, or null for a pane with no recorded
  /// directory — which the server can never match to a checkout.
  final String? workingDirectory;

  final bool isLive;

  /// Whether the app opened this pane to run a session it already has a row
  /// for: the *launched* case, never adopted.
  final bool hostsLaunchedSession;

  /// The newest OSC 133 command block's id, or null for a shell with no
  /// integration (`cmd.exe`, WSL bash today) or one that has run nothing.
  final String? lastCommandId;

  /// That block's command line, once the shell said it is running.
  final String? lastCommandLine;

  /// Whether that block still runs — the only thing separating an exited
  /// `claude --help` from a `claude` at its prompt. True when the shell is
  /// mute.
  final bool lastCommandRunning;
}

/// Tells the server this app's terminal panes, as facts: only this app sees
/// a pane's OSC 133 command blocks and its shell's directory. The server
/// decides what they mean — it adopts a session a person started by hand in
/// one, and reads the resume line an agent printed there. Rides the host
/// link ([HostLinkPeer]); [report] is called each status cycle and sends
/// only when a pane changed, or when the server asked for tails.
class PaneFactsReporter implements HostLinkPeer {
  PaneFactsReporter({required this.readPanes, required this.readTail});

  /// Every pane the terminal layout tracks.
  final List<AdoptablePane> Function() readPanes;

  /// The bottom [lines] rows of one pane's screen, or null for a pane whose
  /// buffer is a replayed record (nothing ran in it) or that is gone.
  final List<String>? Function(String paneId, int lines) readTail;

  void Function(List<PaneFacts> panes)? _send;
  StreamSubscription<PaneTailsWantedMessage>? _wants;
  Set<String> _wanted = const {};
  var _lines = 0;
  List<PaneFacts>? _last;

  /// Reports sent, over this reporter's life.
  int sent = 0;

  @override
  void attached(HostLifecycleFeed feed) {
    unawaited(_wants?.cancel());
    _send = feed.reportPanes;
    _last = null;
    _wanted = const {};
    _wants = feed.paneTailsWanted.listen((want) {
      _wanted = want.paneIds.toSet();
      _lines = want.lines;
      // At once: the server reads a screen as it is now.
      report();
    });
    report();
  }

  @override
  void detached() {
    unawaited(_wants?.cancel());
    _wants = null;
    _send = null;
    _last = null;
    _wanted = const {};
  }

  /// Sends the panes when they changed since the last report, or when the
  /// server asked for tails. Cheap otherwise: one read of the layout and one
  /// comparison.
  void report() {
    final send = _send;
    if (send == null) return;
    final wanted = _wanted;
    _wanted = const {};
    final facts = [
      for (final pane in readPanes())
        PaneFacts(
          paneId: pane.paneId,
          workingDirectory: pane.workingDirectory,
          live: pane.isLive,
          hostsLaunchedSession: pane.hostsLaunchedSession,
          lastCommandId: pane.lastCommandId,
          lastCommandLine: pane.lastCommandLine,
          lastCommandRunning: pane.lastCommandRunning,
          tail: wanted.contains(pane.paneId)
              ? readTail(pane.paneId, _lines)
              : null,
        ),
    ];
    final bare = [for (final pane in facts) pane.withoutTail()];
    final withTails = facts.any((pane) => pane.tail != null);
    if (!withTails && _same(_last, bare)) return;
    _last = bare;
    sent++;
    send(facts);
  }

  static bool _same(List<PaneFacts>? a, List<PaneFacts> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
