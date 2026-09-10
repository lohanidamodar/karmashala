import 'package:riverpod/riverpod.dart';

import '../snippets/application/snippet_insertion.dart';
import '../snippets/application/snippet_providers.dart';
import '../snippets/domain/command_snippet.dart';
import '../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

/// The commands the user keeps: `terminal_run` runs one, this parks one at a
/// prompt for the person to press Enter. There is deliberately no delete.
class SnippetControlTools {
  SnippetControlTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{
    'snippets_list',
    'snippet_add',
    'snippet_insert',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'snippets_list' => _list(args['paneId'] as String?),
        'snippet_add' => _add(
          label: args['label'] as String?,
          command: (args['command'] as String?) ?? '',
          shell: args['shell'] as String?,
          submit: args['submit'] == true,
        ),
        'snippet_insert' => _insert(
          id: args['id'] as String?,
          paneId: args['paneId'] as String?,
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  TerminalSessionsController get _terminals =>
      _container.read(terminalSessionsControllerProvider.notifier);

  TerminalSessionsState get _state =>
      _container.read(terminalSessionsControllerProvider);

  /// Every snippet, and which of them a named pane would be offered. `fitsPane`
  /// is per row: filtering silently would look like the snippet was never saved.
  Object? _list(String? paneId) {
    final snippets = _container.read(commandSnippetsProvider);
    final target = paneId == null || paneId.isEmpty
        ? resolveSnippetTarget(_terminals, _state)
        : snippetTargetFor(_terminals, _state, paneId);
    return <String, Object?>{
      'pane': target == null
          ? null
          : <String, Object?>{
              'paneId': target.paneId,
              'title': target.title,
              'shell': target.shellId,
              'isAgentPane': target.isAgentPane,
              'live': target.live,
            },
      'snippets': <Object?>[
        for (final snippet in snippets)
          <String, Object?>{
            'id': snippet.id,
            'label': snippet.label,
            'command': snippet.command,
            // Null means "any shell", which is the commonest answer and is not
            // the same as "unknown".
            'shell': snippet.shellId,
            'submit': snippet.submit,
            'fitsPane': target == null
                ? null
                : snippet.fitsShell(target.shellId),
            'createdAt': snippet.createdAt.toIso8601String(),
          },
      ],
    };
  }

  /// Saves a snippet, keeping [command] as given but flattened to one line.
  /// [submit] must be asked for: a command that runs itself is a decision.
  Object? _add({
    String? label,
    required String command,
    String? shell,
    required bool submit,
  }) {
    final flattened = singleLine(command);
    if (flattened.isEmpty) {
      throw ArgumentError('command is required and cannot be blank.');
    }
    if (shell != null && shell.isNotEmpty && !_isKnownShell(shell)) {
      throw ArgumentError(
        'No shell "$shell". Use one of '
        '${TerminalShell.values.map((s) => s.name).join(', ')}, or omit it for '
        'a snippet that fits any shell.',
      );
    }
    final snippet = _container
        .read(commandSnippetsProvider.notifier)
        .add(
          label: (label == null || label.trim().isEmpty) ? flattened : label,
          command: flattened,
          shellId: shell == null || shell.isEmpty ? null : shell,
          submit: submit,
        );
    return <String, Object?>{
      'id': snippet.id,
      'label': snippet.label,
      'command': snippet.command,
      'shell': snippet.shellId,
      'submit': snippet.submit,
    };
  }

  bool _isKnownShell(String shell) =>
      TerminalShell.values.any((value) => value.name == shell);

  /// Types a snippet into a pane and stops, unless the snippet itself submits.
  /// A caller cannot override [CommandSnippet.submit]; it is the saver's flag.
  Object? _insert({String? id, String? paneId}) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required. snippets_list has the ids.');
    }
    final snippet = _container.read(commandSnippetDaoProvider).getById(id);
    if (snippet == null) {
      throw StateError('No snippet with id $id.');
    }
    final target = paneId == null || paneId.isEmpty
        ? resolveSnippetTarget(_terminals, _state)
        : snippetTargetFor(_terminals, _state, paneId);
    if (target == null) {
      throw StateError(
        paneId == null || paneId.isEmpty
            ? 'No terminal pane is active. Open one with terminal_open, or '
                  'pass a paneId from terminal_list.'
            : 'No terminal pane with id $paneId.',
      );
    }
    if (!snippet.fitsShell(target.shellId)) {
      // Refused rather than typed anyway, for `terminal_open`'s reason: a WSL
      // one-liner run in PowerShell is not a smaller version of the same thing.
      throw StateError(
        'Snippet ${snippet.id} is tagged for ${shellTagLabel(snippet.shellId)} '
        'and pane ${target.paneId} is running '
        '${shellTagLabel(target.shellId)}.',
      );
    }
    final result = insertSnippet(
      terminals: _terminals,
      state: _state,
      snippet: snippet,
      paneId: target.paneId,
    );
    if (!result.delivered) {
      throw StateError(result.message ?? 'The snippet was not delivered.');
    }
    return <String, Object?>{
      'id': snippet.id,
      'paneId': target.paneId,
      'command': snippet.command,
      'submitted': result.outcome == SnippetOutcome.submitted,
      'note': switch (result.outcome) {
        SnippetOutcome.submitted =>
          'Typed and submitted, because this snippet is saved with submit=true. '
              'Nothing here waited for it or read an exit code — use '
              'terminal_run for that.',
        SnippetOutcome.typedIntoAgentPane =>
          'Typed into an agent pane and NOT submitted. A carriage return there '
              'takes a turn in a live session as if the user had pressed it, '
              'so submit is ignored in an agent pane whatever the snippet says.',
        _ =>
          'Typed at the prompt and left there. It has NOT run: the user presses '
              'Enter. This is the point of the tool — use terminal_run if you '
              'meant to run something.',
      },
    };
  }
}

/// The schemas for [SnippetControlTools].
const List<Map<String, dynamic>> snippetControlToolSchemas = [
  {
    'name': 'snippets_list',
    'description':
        'The commands the user keeps: their saved snippets, each with the '
        'shell it is tagged for and whether picking it also presses Enter. '
        'Read this to find out how this person actually runs their tests, '
        'builds and tools before inventing a command line of your own. Also '
        'reports the pane a snippet would go into — the focused one, or the '
        'paneId you pass — and, per snippet, whether it fits that pane\'s '
        'shell. Nothing is filtered out: a WSL snippet is listed in a '
        'PowerShell pane with fitsPane=false, because hiding it would look '
        'like it was never saved.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {
          'type': 'string',
          'description':
              'Which pane to answer fitsPane for, from terminal_list. Defaults '
              'to the focused pane.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'pane': {
          'type': ['object', 'null'],
        },
        'snippets': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'label': {'type': 'string'},
              'command': {'type': 'string'},
              'shell': {
                'type': ['string', 'null'],
              },
              'submit': {'type': 'boolean'},
              'fitsPane': {
                'type': ['boolean', 'null'],
              },
            },
            'required': ['id', 'label', 'command', 'submit'],
          },
        },
      },
      'required': ['snippets'],
    },
  },
  {
    'name': 'snippet_add',
    'description':
        'Save a command as a snippet, so the user can pick it from the palette '
        'or the terminal toolbar instead of retyping it. Worth doing when you '
        'and the user have just worked out the incantation for something — the '
        'exact test command, the right build flags. Tag it with the shell it '
        'is written for (powerShell, commandPrompt, wsl, posix) and it will '
        'only be offered in a pane running that shell; leave the tag off for '
        'something that works everywhere. submit defaults to false and should '
        'stay false: a snippet is typed at the prompt for the user to read and '
        'press Enter on, and turning that off for somebody else\'s saved '
        'command is not a default you get to choose.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description':
              'The command. Flattened to a single line — a stored newline '
              'would be a submit nobody asked for.',
        },
        'label': {
          'type': 'string',
          'description':
              'What it is called in the picker. Defaults to the command '
              'itself.',
        },
        'shell': {
          'type': 'string',
          'description':
              'powerShell, commandPrompt, wsl or posix. Omit for any shell. An '
              'unknown value is refused rather than dropped.',
        },
        'submit': {
          'type': 'boolean',
          'description':
              'Whether picking it also presses Enter. Default false, and leave '
              'it there unless the user asked for a command that runs itself.',
        },
      },
      'required': ['command'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'label': {'type': 'string'},
        'command': {'type': 'string'},
        'shell': {
          'type': ['string', 'null'],
        },
        'submit': {'type': 'boolean'},
      },
      'required': ['id', 'label', 'command', 'submit'],
    },
  },
  {
    'name': 'snippet_insert',
    'description':
        'Type a saved snippet into a terminal pane and STOP — the command sits '
        'at the prompt and the user presses Enter. Use it to put a line in '
        'front of somebody rather than to run one: if you mean to run a '
        'command and read its output, that is terminal_run. The only exception '
        'is a snippet the user themselves saved with submit=true, which does '
        'run; you cannot ask for that from here. Refuses a snippet tagged for a '
        'different shell than the pane is running, and never submits into a '
        'pane hosting an agent CLI, where a carriage return would take a turn '
        'in a live session.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'Which snippet, from snippets_list.',
        },
        'paneId': {
          'type': 'string',
          'description':
              'Which pane, from terminal_list. Defaults to the focused one — '
              'the pane the user is looking at.',
        },
      },
      'required': ['id'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'paneId': {'type': 'string'},
        'command': {'type': 'string'},
        'submitted': {'type': 'boolean'},
        'note': {'type': 'string'},
      },
      'required': ['id', 'paneId', 'command', 'submitted', 'note'],
    },
  },
];
