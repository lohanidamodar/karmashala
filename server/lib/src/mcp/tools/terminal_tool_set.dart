import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_launch/karmashala_launch.dart'
    show AgentPaneLaunch, TerminalProfile;

import '../../data/data_service.dart';
import '../../domain/host_session.dart';
import '../../domain/session_registry.dart';
import '../../domain/uuid.dart';
import '../../terminals/server_terminals.dart';
import 'server_tool_set.dart';
import 'terminal_command_run.dart';
import 'terminal_tool_schemas.dart';

/// What an agent is told when a terminal it opened has no window to show it.
const String kTerminalNoWindowNote =
    'No Karmashala window is open, so nobody sees it yet; it runs in the '
    'server, and a window opened later lists it.';

/// **The terminals, as an agent drives them — run by the server** (slice 5b):
/// `terminal_list`, `terminal_open`, `terminal_run`, `terminal_output`,
/// `terminal_close` over [ServerTerminals] and the server's own copy of each
/// screen. The server keeps no tabs: each terminal is a tab of one pane,
/// whose id is the pane id, and the window a person is using is asked to show
/// or close its tab ([DataService.tellIntent]). With every window closed the
/// tools work the same, and say that nobody sees them.
class TerminalToolSet extends ServerToolSet {
  TerminalToolSet({
    required this.terminals,
    required this.registry,
    required this.data,
    String Function()? newPaneId,
    this.defaultTimeout = const Duration(seconds: 60),
  }) : _newPaneId = newPaneId ?? newUuid;

  final ServerTerminals terminals;
  final SessionRegistry registry;
  final DataService data;
  final String Function() _newPaneId;

  /// How long `terminal_run` waits when the caller names no timeout.
  final Duration defaultTimeout;

  static const Duration _maxRunTimeout = Duration(minutes: 10);

  static const _names = {
    'terminal_list',
    'terminal_open',
    'terminal_run',
    'terminal_output',
    'terminal_close',
  };

  @override
  List<Map<String, Object?>> get schemas => terminalControlToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    if (!_names.contains(tool)) return null;
    return runTool(
      () => switch (tool) {
        'terminal_list' => _list(),
        'terminal_open' => _open(
          profileId: arguments['profileId'] as String?,
          workingDirectory: arguments['workingDirectory'] as String?,
        ),
        'terminal_run' => _run(
          arguments['paneId'] as String?,
          (arguments['command'] as String?) ?? '',
          timeoutSeconds: arguments['timeoutSeconds'] as num?,
        ),
        'terminal_output' => _output(
          arguments['paneId'] as String?,
          (arguments['lines'] as num?)?.round() ?? 40,
        ),
        _ => _close(
          arguments['tabId'] as String?,
          kill: arguments['kill'] == true,
        ),
      },
    );
  }

  /// Every terminal the server runs: its records, and the hosted runs its
  /// registry holds that no record names (a Flutter run, a worktree setup).
  List<_Terminal> _terminals() {
    final found = <_Terminal>[];
    final named = <String>{};
    for (final record in terminals.records) {
      named.add(record.sessionId);
      found.add(
        _Terminal(
          paneId: record.paneId,
          sessionId: record.sessionId,
          title: record.title,
          profileId: record.profileId,
          record: record,
          session: registry.find(record.sessionId),
        ),
      );
    }
    for (final session in registry.sessions) {
      if (named.contains(session.id)) continue;
      const local = 'karmashala_local_';
      if (!session.id.startsWith(local)) continue;
      found.add(
        _Terminal(
          paneId: session.id.substring(local.length),
          sessionId: session.id,
          title: session.facts?.title ?? session.id.substring(local.length),
          profileId: null,
          record: null,
          session: session,
        ),
      );
    }
    return found;
  }

  _Terminal? _find(String paneId) {
    for (final terminal in _terminals()) {
      if (terminal.paneId == paneId) return terminal;
    }
    return null;
  }

  Object? _list() {
    final all = _terminals();
    final focused = data.focusedPaneId;
    final active = all.any((t) => t.paneId == focused) ? focused : null;
    return <String, Object?>{
      'activeTabId': active,
      'tabs': <Object?>[
        for (final terminal in all)
          <String, Object?>{
            'id': terminal.paneId,
            'title': terminal.title,
            'active': terminal.paneId == active,
            'focusedPaneId': terminal.paneId,
            'panes': <Object?>[
              <String, Object?>{
                'paneId': terminal.paneId,
                'title': terminal.title,
                'profileId': terminal.profileId,
                // Null rather than "": a shell that never said where it is
                // is not at the root.
                'workingDirectory':
                    terminal.session?.facts?.workingDirectory ??
                    terminal.record?.workingDirectory,
                'live': terminal.live,
              },
            ],
          },
      ],
      // Every terminal keeps running in the server with or without a tab.
      'detached': const <Object?>[],
      'profiles': <Object?>[
        for (final profile in terminals.profiles())
          <String, Object?>{
            'id': profile.id,
            'label': profile.label,
            'shell': profile.shell.name,
            'wslDistribution': profile.wslDistribution,
          },
      ],
    };
  }

  Object? _open({String? profileId, String? workingDirectory}) {
    final profiles = terminals.profiles();
    if (profileId != null && profileId.isNotEmpty) {
      if (!profiles.any((profile) => profile.id == profileId)) {
        // An agent that asked for WSL and got PowerShell runs on the wrong
        // filesystem.
        throw ArgumentError(
          'No terminal profile "$profileId". Available: '
          '${profiles.map((p) => p.id).join(', ')}.',
        );
      }
    }
    final paneId = _newPaneId();
    final TerminalOpened opened;
    try {
      opened = terminals.open(
        TerminalOpen(
          paneId: paneId,
          profileId: profileId == null || profileId.isEmpty ? null : profileId,
          workingDirectory: workingDirectory,
          columns: 120,
          rows: 40,
        ),
      );
    } on DataRefused catch (refusal) {
      throw StateError(refusal.message);
    }
    final shown = data.tellIntent(
      OpenTerminalTab(paneId: paneId, title: opened.title),
    );
    return <String, Object?>{
      'tabId': paneId,
      'paneId': paneId,
      'profileId': opened.profileId,
      'workingDirectory': workingDirectory,
      'shown': shown,
      if (!shown) 'note': kTerminalNoWindowNote,
    };
  }

  Duration _timeout(num? seconds) {
    if (seconds == null) return defaultTimeout;
    final ms = (seconds * 1000).round().clamp(0, _maxRunTimeout.inMilliseconds);
    return Duration(milliseconds: ms);
  }

  /// Runs [command] in a terminal and waits for **that** command to finish,
  /// on the OSC 133 markers the server's screen reads. It never invents an
  /// exit code.
  Future<Object?> _run(
    String? paneId,
    String command, {
    num? timeoutSeconds,
  }) async {
    if (paneId == null || paneId.isEmpty) {
      throw ArgumentError('paneId is required. terminal_list has the ids.');
    }
    if (command.trim().isEmpty) {
      throw ArgumentError('command is required and cannot be blank.');
    }
    final terminal = _find(paneId);
    final session = terminal?.session;
    if (terminal == null || session == null) {
      throw StateError('No terminal pane with id $paneId.');
    }
    // An agent's terminal is not a shell: text typed into it is a *turn*.
    final agent = terminal.agentId;
    if (agent != null) {
      throw StateError(
        'Pane $paneId is running the $agent CLI, not a shell. '
        'Typing into it would land in that live agent session as if the user '
        'had typed it, and there is no command boundary to wait for. Talk to a '
        'session with session_send, or open a shell with terminal_open.',
      );
    }
    if (!terminal.live) {
      throw StateError(
        'That pane\'s process has exited; there is no shell to type into.',
      );
    }
    final integrated =
        (terminal.record?.shellIntegration ?? false) ||
        (session.facts?.markersSeen ?? false);
    // Begun *before* the keystroke: a fast command can finish inside the
    // same turn, and a watch started afterwards would miss its own end.
    final watch = integrated ? TerminalCommandRun.begin(session) : null;
    // A carriage return: a PTY line discipline reads CR as submit.
    session.typeAsHost(utf8.encode('$command\r'));
    if (watch == null) return _unwatched(terminal, command);

    final timeout = _timeout(timeoutSeconds);
    final outcome = await watch.awaitFinish(timeout);
    return <String, Object?>{
      'paneId': paneId,
      'command': command,
      'finished': outcome.finished,
      // Never invented. `null` is "we were not told", which is not zero.
      'exitCode': outcome.exitCode,
      'exitCodeKnown': outcome.exitCode != null,
      'durationMs': outcome.duration?.inMilliseconds,
      'output': outcome.output.lines,
      'note': _noteFor(outcome, paneId: paneId, timeout: timeout),
    };
  }

  Map<String, Object?> _unwatched(_Terminal terminal, String command) {
    final shell = _profileLabel(terminal.profileId);
    return <String, Object?>{
      'paneId': terminal.paneId,
      'command': command,
      'finished': false,
      'exitCode': null,
      'exitCodeKnown': false,
      'durationMs': null,
      'output': <String>[],
      'note':
          'Typed and submitted, but NOT waited for: this pane'
          '${shell == null ? '' : ' ($shell)'} has no OSC 133 shell '
          'integration, so it cannot report when a command ends or what it '
          'exited with. PowerShell and WSL panes can be integrated, but not '
          'until Settings > Terminal enables it, and only for a pane started '
          'after that — a pane that resumed a session-host session keeps '
          'whatever it was launched with; cmd.exe never can — it has no '
          'hook between reading a command and running it, and its PROMPT '
          'cannot carry a live exit code. The exit code is UNKNOWN — not 0, '
          'and not "probably fine". Read what happened with terminal_output '
          'paneId=${terminal.paneId}.',
    };
  }

  String? _profileLabel(String? profileId) {
    if (profileId == null) return null;
    for (final TerminalProfile profile in terminals.profiles()) {
      if (profile.id == profileId) return profile.label;
    }
    return null;
  }

  /// `500ms`, `60s` — never `60.0s`.
  static String _humanDuration(Duration timeout) =>
      timeout.inMilliseconds % 1000 == 0
      ? '${timeout.inSeconds}s'
      : '${timeout.inMilliseconds}ms';

  static String _noteFor(
    CommandRunOutcome outcome, {
    required String paneId,
    required Duration timeout,
  }) {
    final note = StringBuffer();
    switch (outcome.end) {
      case CommandRunEnd.finished:
        note.write(
          outcome.exitCode == null
              ? 'The command finished, but the shell reported no exit code — '
                    'an interrupted command ends that way. Treat the exit '
                    'status as UNKNOWN, not as success.'
              : 'Finished with exit code ${outcome.exitCode}.',
        );
      case CommandRunEnd.timedOut:
        note.write(
          'The command is still running in pane $paneId after '
          '${_humanDuration(timeout)}. What is here is what it has '
          'printed so far — NOT its whole output, and there is no exit code '
          'because it has not finished. Keep watching it with terminal_output '
          'paneId=$paneId, or leave it running.',
        );
        if (!outcome.markersSeen) {
          note.write(
            ' No OSC 133 marker has ever arrived in this pane, so the shell '
            'may not be running the integration at all rather than the command '
            'being slow.',
          );
        }
      case CommandRunEnd.paneExited:
        note.write(
          outcome.exitCode == null
              ? 'The pane\'s process exited while the command was running, and '
                    'nothing reported an exit code, so the command\'s status is '
                    'UNKNOWN — not 0. What is here is what it printed before '
                    'that.'
              : 'The pane\'s process exited while the command was running, with '
                    'code ${outcome.exitCode}. That is the SESSION\'s code, not '
                    'the command\'s: the shell died before it could report one. '
                    'What is here is what it printed before that.',
        );
    }
    if (!outcome.output.scoped) {
      note.write(
        ' No output could be attributed to this command specifically — it '
        'either printed before starting or has already scrolled out of the '
        'pane\'s history — so none is returned rather than somebody else\'s. '
        'terminal_output reads the pane as it stands.',
      );
    }
    if (outcome.output.omitted > 0) {
      note.write(
        ' The first ${outcome.output.omitted} lines were dropped; this is the '
        'tail.',
      );
    }
    return note.toString();
  }

  Object? _output(String? paneId, int lines) {
    if (paneId == null || paneId.isEmpty) {
      throw ArgumentError('paneId is required. terminal_list has the ids.');
    }
    final terminal = _find(paneId);
    if (terminal == null) {
      throw StateError('No terminal pane with id $paneId.');
    }
    final capped = lines <= 0 ? 40 : (lines > 500 ? 500 : lines);
    return <String, Object?>{
      'paneId': paneId,
      'title': terminal.title,
      'live': terminal.live,
      'lines': terminal.session?.tailText(capped) ?? const <String>[],
    };
  }

  /// Closes a terminal's tab and reports what happened to it: with [kill], or
  /// for an idle shell that printed nothing, the terminal is ended; anything
  /// else keeps running in the server.
  Future<Object?> _close(String? tabId, {required bool kill}) async {
    if (tabId == null || tabId.isEmpty) {
      throw ArgumentError('tabId is required. terminal_list has the ids.');
    }
    final terminal = _find(tabId);
    if (terminal == null) {
      throw StateError('No terminal tab with id $tabId.');
    }
    final end = kill || !terminal.live || _idleShell(terminal);
    if (end) {
      if (terminal.record != null) {
        try {
          await terminals.close(terminal.sessionId);
        } on DataRefused {
          // Already gone: that is what was asked.
        }
      } else {
        try {
          await registry.close(terminal.sessionId);
        } on UnknownSession {
          // Already gone.
        }
      }
    }
    data.tellIntent(CloseTerminalTab(terminal.paneId));
    return <String, Object?>{
      'tabId': tabId,
      'closed': true,
      'panes': <Object?>[
        <String, Object?>{
          'paneId': terminal.paneId,
          'outcome': end
              ? 'ended'
              : 'detached — still running, and listed by terminal_list',
        },
      ],
    };
  }

  /// A shell that is doing nothing and has shown nothing but its prompt:
  /// there is nothing to come back for.
  bool _idleShell(_Terminal terminal) {
    if (terminal.agentId != null) return false;
    final session = terminal.session;
    final facts = session?.facts;
    if (session == null || facts == null) return false;
    if (facts.commandRunning || facts.lastCommand != null) return false;
    final printed = session
        .tailText(HostSession.screenScrollbackLines)
        .where((line) => line.trim().isNotEmpty)
        .length;
    return printed <= 1;
  }
}

class _Terminal {
  _Terminal({
    required this.paneId,
    required this.sessionId,
    required this.title,
    required this.profileId,
    required this.record,
    required this.session,
  });

  final String paneId;
  final String sessionId;
  final String title;
  final String? profileId;
  final TerminalRecord? record;
  final HostSession? session;

  bool get live {
    final running = session;
    return running != null && !running.lifecycle.hasEnded;
  }

  /// The agent this terminal runs, when it is an agent's and not a shell:
  /// named by its profile (`agent:<id>`), or by a session row's id.
  String? get agentId {
    final profile = profileId;
    if (profile != null && AgentPaneLaunch.isAgentProfileId(profile)) {
      return profile.substring('agent:'.length);
    }
    if (sessionId.startsWith('karmashala_') &&
        !sessionId.startsWith('karmashala_local_')) {
      return 'agent';
    }
    return null;
  }
}
