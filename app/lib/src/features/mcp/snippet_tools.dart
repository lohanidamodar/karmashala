import 'package:riverpod/riverpod.dart';

import '../snippets/application/snippet_insertion.dart';
import '../snippets/application/snippet_providers.dart';
import '../snippets/domain/command_snippet.dart';
import '../terminal/application/terminal_sessions_controller.dart';

/// `snippet_insert`: the commands the user keeps — `terminal_run` runs one,
/// this parks one at a prompt for the person to press Enter. It types into
/// one of this app's panes, so it is the app's; listing and saving snippets
/// are the server's (`SnippetToolSet`). There is deliberately no delete.
class SnippetControlTools {
  SnippetControlTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{'snippet_insert'};

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
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

  /// Types a snippet into a pane and stops, unless the snippet itself submits.
  /// A caller cannot override [CommandSnippet.submit]; it is the saver's flag.
  Object? _insert({String? id, String? paneId}) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required. snippets_list has the ids.');
    }
    final snippet = _container
        .read(commandSnippetsProvider.notifier)
        .getById(id);
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
