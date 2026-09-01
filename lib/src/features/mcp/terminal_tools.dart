import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../terminal/application/terminal_sessions_controller.dart';
import '../terminal/data/terminal_grid_text.dart';
import '../terminal/domain/terminal_profile.dart';
import '../terminal/application/terminal_profiles.dart';

/// The terminal workspace, as an agent can drive it.
///
/// These go through `TerminalSessionsController` — the same object the tab bar
/// calls — rather than spawning anything of their own. A pane an agent opened
/// and a pane the user opened are the same pane: it appears in the tab bar, it
/// persists across a restart, and closing it detaches or ends it under the same
/// rules. An agent that shelled out to its own subprocess would get none of
/// that, and the user would have no way to see what it was running.
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
      // Panes still running with no tab showing them. An agent looking for
      // "what is running" that only read the tabs would miss exactly the work
      // someone closed a tab on and left going.
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
      // directory inherited one we did not record, and saying "" would read as
      // the root.
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
        // `resolveTerminalProfile` falls back to the first profile, which is
        // right when restoring a workspace and wrong here: an agent that asked
        // for a WSL shell and silently got PowerShell would run its commands
        // against the wrong filesystem.
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

  /// Types [command] into a pane and presses return.
  ///
  /// This is typing, not executing: there is no exit code to wait for and no
  /// completion to report, because a terminal pane has no such notion. Read the
  /// result with `terminal_output`.
  Object? _run(String? paneId, String command) {
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
    if (!_container
        .read(terminalSessionsControllerProvider)
        .livenessOf(paneId)
        .isLive) {
      throw StateError(
        'That pane\'s process has exited; there is no shell to type into.',
      );
    }
    // A carriage return, for the same reason `SessionLauncher.sendTo` uses one:
    // a PTY line discipline reads CR as submit and leaves a bare LF sitting on
    // the line.
    instance.terminal
      ..textInput(command)
      ..textInput('\r');
    return <String, Object?>{
      'paneId': paneId,
      'typed': command,
      'note':
          'The command was typed and submitted. Nothing here waits for it or '
          'reads its exit code — call terminal_output to see what happened.',
    };
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

  /// Closes a tab. Whether its panes survive is the app's decision, not this
  /// tool's, and the answer is measured rather than claimed.
  ///
  /// `shouldDetachOnClose` keeps an agent session or a running command and
  /// releases an idle shell that has printed nothing anyone would come back
  /// for. So "close detaches" is true of the panes that matter and false of the
  /// ones that do not — which means the honest thing to return is which
  /// actually happened to each pane, read back afterwards.
  ///
  /// `kill` is the other thing entirely: it skips the policy and ends every
  /// pane. That is why it is a separate argument and not the meaning of close.
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
    _controller.closeTab(tabId, detach: !kill);

    final after = _container.read(terminalSessionsControllerProvider);
    final stillDetached = <String>{
      for (final session in after.detached) session.paneId,
    };
    return <String, Object?>{
      'tabId': tabId,
      'closed': true,
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
        'The terminal workspace: every tab, the panes in each, which pane is '
        'focused, and the panes still running with no tab showing them '
        '(detached). Also lists the shell profiles this machine offers, which '
        'is where terminal_open gets its profileId. Start here — every other '
        'terminal tool takes an id from this one.',
    // An empty `properties` as well as `additionalProperties: false`. The spec
    // accepts either spelling for a tool with no arguments; this repo asserts
    // that every served schema carries a properties map, so it gets both.
    'inputSchema': {
      'type': 'object',
      'properties': <String, dynamic>{},
      'additionalProperties': false,
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'activeTabId': {'type': ['string', 'null']},
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
                    'profileId': {'type': ['string', 'null']},
                    'workingDirectory': {'type': ['string', 'null']},
                    'live': {'type': 'boolean'},
                  },
                  'required': ['paneId', 'live'],
                },
              },
            },
            'required': ['id', 'panes'],
          },
        },
        'detached': {'type': 'array', 'items': {'type': 'object'}},
        'profiles': {'type': 'array', 'items': {'type': 'object'}},
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
        'workingDirectory': {'type': ['string', 'null']},
      },
      'required': ['tabId', 'paneId', 'profileId'],
    },
  },
  {
    'name': 'terminal_run',
    'description':
        'Type a command into a terminal pane and press return. This TYPES; it '
        'does not wait. There is no exit code and no completion — a pane is a '
        'shell, not a job runner — so call terminal_output afterwards to read '
        'what happened. Whatever the command does is the command\'s business: '
        'this tool cannot tell a build from an rm -rf.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {
          'type': 'string',
          'description': 'Which pane, from terminal_list.',
        },
        'command': {'type': 'string', 'description': 'The command to type.'},
      },
      'required': ['paneId', 'command'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {'type': 'string'},
        'typed': {'type': 'string'},
        'note': {'type': 'string'},
      },
      'required': ['paneId', 'typed'],
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
        'lines': {'type': 'array', 'items': {'type': 'string'}},
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
