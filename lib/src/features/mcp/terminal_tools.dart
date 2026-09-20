import 'package:riverpod/riverpod.dart';

import 'package:karmashala_terminal_core/geometry.dart';
import '../editor/application/editor_tab_actions.dart';
import '../editor/application/open_documents.dart';
import '../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import '../terminal/application/terminal_profiles.dart';

/// The terminal layout, as an agent can drive it — through the same
/// `TerminalSessionsController` the tab bar calls, so its panes are the user's.
class TerminalControlTools {
  TerminalControlTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{
    'terminal_list',
    'terminal_open',
    'terminal_run',
    'terminal_output',
    'terminal_close',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'terminal_list' => _list(),
        'terminal_open' => _open(
          profileId: args['profileId'] as String?,
          workingDirectory: args['workingDirectory'] as String?,
        ),
        'terminal_run' => _run(
          args['paneId'] as String?,
          (args['command'] as String?) ?? '',
          timeoutSeconds: args['timeoutSeconds'] as num?,
        ),
        'terminal_output' => _output(
          args['paneId'] as String?,
          (args['lines'] as num?)?.round() ?? 40,
        ),
        'terminal_close' => _close(
          args['tabId'] as String?,
          kill: args['kill'] == true,
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  TerminalSessionsController get _controller =>
      _container.read(terminalSessionsControllerProvider.notifier);

  Object? _list() {
    final state = _container.read(terminalSessionsControllerProvider);
    return <String, Object?>{
      'activeTabId': state.activeTabId,
      'tabs': <Object?>[
        for (final tab in state.tabs)
          <String, Object?>{
            'id': tab.id,
            'title': _controller.titleForTab(tab.id),
            'active': tab.id == state.activeTabId,
            'focusedPaneId': tab.focusedPaneId,
            'panes': <Object?>[
              for (final paneId in tab.layout.panes) _pane(paneId, state),
            ],
          },
      ],
      // Panes still running with no tab showing them: an agent that read only
      // the tabs would miss the work someone closed a tab on and left going.
      'detached': <Object?>[
        for (final detached in state.detached)
          <String, Object?>{
            'paneId': detached.paneId,
            'title': detached.title,
            'workingDirectory': detached.workingDirectory,
            'detachedAt': detached.detachedAt.toIso8601String(),
            'live': state.livenessOf(detached.paneId).isLive,
          },
      ],
      'profiles': <Object?>[
        for (final profile in _profiles())
          <String, Object?>{
            'id': profile.id,
            'label': profile.label,
            'shell': profile.shell.name,
            'wslDistribution': profile.wslDistribution,
          },
      ],
    };
  }

  Map<String, Object?> _pane(String paneId, TerminalSessionsState state) {
    final instance = _controller.instanceFor(paneId);
    return <String, Object?>{
      'paneId': paneId,
      'title': instance?.title ?? 'not recorded',
      'profileId': instance?.profileId,
      // Null rather than the empty string: a pane started with no explicit
      // directory inherited one we did not record, and "" would read as root.
      'workingDirectory': instance?.workingDirectory,
      'live': state.livenessOf(paneId).isLive,
    };
  }

  List<TerminalProfile> _profiles() =>
      _container.read(terminalProfilesProvider);

  Object? _open({String? profileId, String? workingDirectory}) {
    final profiles = _profiles();
    if (profileId != null && profileId.isNotEmpty) {
      final known = profiles.any((profile) => profile.id == profileId);
      if (!known) {
        // `resolveTerminalProfile` falls back to the first profile: an agent
        // that asked for WSL and got PowerShell runs on the wrong filesystem.
        throw ArgumentError(
          'No terminal profile "$profileId". Available: '
          '${profiles.map((p) => p.id).join(', ')}.',
        );
      }
    }
    final profile = resolveTerminalProfile(profileId, profiles);
    final tabId = _controller.openTab(
      profile,
      workingDirectory: workingDirectory,
    );
    final state = _container.read(terminalSessionsControllerProvider);
    final tab = state.tabs.firstWhere((tab) => tab.id == tabId);
    return <String, Object?>{
      'tabId': tabId,
      'paneId': tab.focusedPaneId,
      'profileId': profile.id,
      'workingDirectory': workingDirectory,
    };
  }

  /// How long a run waits for its command before answering "still running".
  static const Duration _defaultRunTimeout = Duration(seconds: 60);
  static const Duration _maxRunTimeout = Duration(minutes: 10);

  /// Runs [command] in a pane and waits for **that** command to finish, on the
  /// OSC 133 markers [CommandRunWatch] watches. It never invents an exit code.
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
    final instance = _controller.instanceFor(paneId);
    if (instance == null) {
      throw StateError('No terminal pane with id $paneId.');
    }
    // An agent pane is not a shell: text typed into it is a *turn*. There is no
    // shell to run a command in and no exit code to report.
    final agent = instance.agentLaunch;
    if (agent != null) {
      throw StateError(
        'Pane $paneId is running the ${agent.agentId} CLI, not a shell. '
        'Typing into it would land in that live agent session as if the user '
        'had typed it, and there is no command boundary to wait for. Talk to a '
        'session with session_send, or open a shell with terminal_open.',
      );
    }
    if (!_container
        .read(terminalSessionsControllerProvider)
        .livenessOf(paneId)
        .isLive) {
      throw StateError(
        'That pane\'s process has exited; there is no shell to type into.',
      );
    }

    // Begun *before* the keystroke: a fast command can finish inside the same
    // turn, and a watch started afterwards would miss its own end marker.
    final watch = CommandRunWatch.begin(instance);
    _type(instance, command);
    if (watch == null) return _unwatched(instance, command);

    final timeout = _timeout(timeoutSeconds);
    final outcome = await watch.awaitFinish(timeout);
    return <String, Object?>{
      'paneId': paneId,
      'command': command,
      'finished': outcome.finished,
      // Never invented. `null` is "we were not told", which is not zero.
      'exitCode': outcome.exitCode,
      // The code, not the shape of the ending. The `paneExited` note below is
      // the other half of this line — change them together or not at all.
      'exitCodeKnown': outcome.exitCode != null,
      'durationMs': outcome.duration?.inMilliseconds,
      'output': outcome.output.lines,
      'note': _noteFor(outcome, paneId: paneId, timeout: timeout),
    };
  }

  /// A carriage return, as `SessionLauncher.sendTo` uses: a PTY line discipline
  /// reads CR as submit and leaves a bare LF sitting on the line.
  void _type(TerminalInstance instance, String command) => instance.terminal
    ..textInput(command)
    ..textInput('\r');

  Duration _timeout(num? seconds) {
    if (seconds == null) return _defaultRunTimeout;
    final ms = (seconds * 1000).round().clamp(0, _maxRunTimeout.inMilliseconds);
    return Duration(milliseconds: ms);
  }

  /// The answer for a pane whose shell cannot say when a command ended: it types
  /// and returns, and says so. The one thing not on offer is a fabricated zero.
  Map<String, Object?> _unwatched(TerminalInstance instance, String command) {
    final shell = _profiles()
        .where((profile) => profile.id == instance.profileId)
        .firstOrNull
        ?.label;
    return <String, Object?>{
      'paneId': instance.id,
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
          'until Settings > Terminal enables it; cmd.exe never can — it has no '
          'hook between reading a command and running it, and its PROMPT '
          'cannot carry a live exit code. The exit code is UNKNOWN — not 0, '
          'and not "probably fine". Read what happened with terminal_output '
          'paneId=${instance.id}.',
    };
  }

  /// `500ms`, `60s` — never `60.0s`.
  String _humanDuration(Duration timeout) => timeout.inMilliseconds % 1000 == 0
      ? '${timeout.inSeconds}s'
      : '${timeout.inMilliseconds}ms';

  String _noteFor(
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
    final instance = _controller.instanceFor(paneId);
    if (instance == null) {
      throw StateError('No terminal pane with id $paneId.');
    }
    final capped = lines <= 0 ? 40 : (lines > 500 ? 500 : lines);
    return <String, Object?>{
      'paneId': paneId,
      'title': instance.title,
      'live': _container
          .read(terminalSessionsControllerProvider)
          .livenessOf(paneId)
          .isLive,
      'lines': terminalTailLines(instance.terminal, lines: capped),
    };
  }

  /// Closes a tab and reports what actually happened to each pane, read back
  /// rather than claimed; `kill` skips the detach policy and ends every one.
  Object? _close(String? tabId, {required bool kill}) {
    if (tabId == null || tabId.isEmpty) {
      throw ArgumentError('tabId is required. terminal_list has the ids.');
    }
    final before = _container.read(terminalSessionsControllerProvider);
    final tab = before.tabs.where((tab) => tab.id == tabId).firstOrNull;
    if (tab == null) {
      throw StateError('No terminal tab with id $tabId.');
    }
    final panes = List<String>.from(tab.layout.panes);
    // No dialog to put to an agent, so an unsaved buffer is reported rather
    // than silently dropped — and released, or it would outlive every tab that
    // could show it and be served to whoever opened that file next.
    final dirty = _container.read(dirtyDocumentPathsProvider);
    final unsaved = [
      for (final paneId in panes)
        if (editorPanePath(paneId) case final path?)
          if (dirty.contains(path)) path,
    ];
    final files = [for (final paneId in panes) ?editorPanePath(paneId)];
    _controller.closeTab(tabId, detach: !kill);
    _container.read(editorTabActionsProvider).release(files);

    final after = _container.read(terminalSessionsControllerProvider);
    final stillDetached = <String>{
      for (final session in after.detached) session.paneId,
    };
    return <String, Object?>{
      'tabId': tabId,
      'closed': true,
      if (unsaved.isNotEmpty) 'unsavedEditsDiscarded': unsaved,
      'panes': <Object?>[
        for (final paneId in panes)
          <String, Object?>{
            'paneId': paneId,
            'outcome': stillDetached.contains(paneId)
                ? 'detached — still running, and listed by terminal_list'
                : 'ended',
          },
      ],
    };
  }
}

/// The schemas for [TerminalControlTools].
const List<Map<String, dynamic>> terminalControlToolSchemas = [
  {
    'name': 'terminal_list',
    'description':
        'The terminal layout: every tab, the panes in each, which pane is '
        'focused, and the panes still running with no tab showing them '
        '(detached). Also lists the shell profiles this machine offers, which '
        'is where terminal_open gets its profileId. Start here — every other '
        'terminal tool takes an id from this one.',
    // An empty `properties` as well as `additionalProperties: false`: the spec
    // accepts either, and this repo asserts every schema carries a properties map.
    'inputSchema': {
      'type': 'object',
      'properties': <String, dynamic>{},
      'additionalProperties': false,
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'activeTabId': {
          'type': ['string', 'null'],
        },
        'tabs': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'title': {'type': 'string'},
              'active': {'type': 'boolean'},
              'focusedPaneId': {'type': 'string'},
              'panes': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'paneId': {'type': 'string'},
                    'title': {'type': 'string'},
                    'profileId': {
                      'type': ['string', 'null'],
                    },
                    'workingDirectory': {
                      'type': ['string', 'null'],
                    },
                    'live': {'type': 'boolean'},
                  },
                  'required': ['paneId', 'live'],
                },
              },
            },
            'required': ['id', 'panes'],
          },
        },
        'detached': {
          'type': 'array',
          'items': {'type': 'object'},
        },
        'profiles': {
          'type': 'array',
          'items': {'type': 'object'},
        },
      },
      'required': ['tabs', 'detached', 'profiles'],
    },
  },
  {
    'name': 'terminal_open',
    'description':
        'Open a new terminal tab and return its tab and pane ids. The tab '
        'appears in Karmashala\'s own tab bar, so the user can see and take '
        'over whatever runs in it. Pass profileId to choose the shell — an '
        'unknown one is refused rather than quietly substituted, because a WSL '
        'command run in PowerShell is not a smaller version of the same thing.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'profileId': {
          'type': 'string',
          'description':
              'A profile id from terminal_list. Defaults to the first one, '
              'which is PowerShell on Windows.',
        },
        'workingDirectory': {
          'type': 'string',
          'description':
              'Where the shell starts. Must be a path the chosen shell can '
              'reach: a WSL profile needs a Linux path, a Windows one needs a '
              'Windows path.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'tabId': {'type': 'string'},
        'paneId': {'type': 'string'},
        'profileId': {'type': 'string'},
        'workingDirectory': {
          'type': ['string', 'null'],
        },
      },
      'required': ['tabId', 'paneId', 'profileId'],
    },
  },
  {
    'name': 'terminal_run',
    'description':
        'Run a command in a terminal pane and WAIT for it to finish, then '
        'return that command\'s own output and its exit code — one round trip, '
        'the way your own shell tool works. Prefer this over spawning a shell '
        'of your own: the pane is Karmashala\'s, so the user can watch it, take '
        'it over, and keep it after you are gone. Read `finished` and '
        '`exitCodeKnown` before you believe anything: a command still running '
        'at the timeout comes back finished=false with the partial output it '
        'has printed so far (pass a small timeoutSeconds for a dev server you '
        'mean to leave running), and a pane whose shell has no OSC 133 '
        'integration — PowerShell is the only one that has it today — comes '
        'back at once with exitCodeKnown=false, because it cannot know. No '
        'exit code is ever invented. Refuses a pane that is running an agent '
        'CLI: that is somebody\'s live session, not a shell. Whatever the '
        'command does is the command\'s business — this tool cannot tell a '
        'build from an rm -rf.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {
          'type': 'string',
          'description': 'Which pane, from terminal_list.',
        },
        'command': {'type': 'string', 'description': 'The command to run.'},
        'timeoutSeconds': {
          'type': 'number',
          'description':
              'How long to wait for the command before answering "still '
              'running" with what it has printed (default 60, max 600). '
              'Nothing is killed on timeout — the command keeps running in the '
              'pane.',
        },
      },
      'required': ['paneId', 'command'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {'type': 'string'},
        'command': {'type': 'string'},
        'finished': {'type': 'boolean'},
        'exitCode': {
          'type': ['number', 'null'],
        },
        'exitCodeKnown': {'type': 'boolean'},
        'durationMs': {
          'type': ['number', 'null'],
        },
        'output': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'note': {'type': 'string'},
      },
      'required': [
        'paneId',
        'command',
        'finished',
        'exitCodeKnown',
        'output',
        'note',
      ],
    },
  },
  {
    'name': 'terminal_output',
    'description':
        'Read the recent output of a terminal pane — the screen as it stands, '
        'newest last. This is what a pane shows, not a log: lines that '
        'scrolled out of the buffer are gone.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {
          'type': 'string',
          'description': 'Which pane, from terminal_list.',
        },
        'lines': {
          'type': 'number',
          'description': 'How many trailing lines (default 40, max 500).',
        },
      },
      'required': ['paneId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {'type': 'string'},
        'title': {'type': 'string'},
        'live': {'type': 'boolean'},
        'lines': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['paneId', 'lines'],
    },
  },
  {
    'name': 'terminal_close',
    'description':
        'Close a terminal tab. A pane that is doing something — an agent '
        'session, a running command, a shell with real history — is DETACHED '
        'rather than ended: it keeps running and appears under "detached" in '
        'terminal_list, which is how a long build survives its tab being '
        'tidied away. An idle shell that has printed nothing is ended, because '
        'there is nothing to come back for. The result says which happened to '
        'each pane. Pass kill=true to skip that entirely and end them all — '
        'DESTRUCTIVE, and nothing brings back what they were part-way through.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'tabId': {
          'type': 'string',
          'description': 'Which tab, from terminal_list.',
        },
        'kill': {
          'type': 'boolean',
          'description':
              'End the panes\' processes instead of detaching them. Default '
              'false.',
        },
      },
      'required': ['tabId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'tabId': {'type': 'string'},
        'closed': {'type': 'boolean'},
        'panes': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'paneId': {'type': 'string'},
              'outcome': {'type': 'string'},
            },
            'required': ['paneId', 'outcome'],
          },
        },
      },
      'required': ['tabId', 'closed', 'panes'],
    },
  },
];
