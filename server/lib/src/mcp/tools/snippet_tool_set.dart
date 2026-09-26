import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:karmashala_snippets/store.dart';

import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// The terminal pane a snippet would be typed into, as `snippets_list`
/// reports it: the app's to know, since panes and focus are its UI.
class SnippetPane {
  const SnippetPane({
    required this.paneId,
    required this.title,
    required this.shellId,
    required this.isAgentPane,
    required this.live,
  });

  final String paneId;
  final String title;
  final String? shellId;
  final bool isAgentPane;
  final bool live;
}

/// The pane [paneId] names — or, for null, the one in front — or null when
/// there is none.
typedef SnippetPaneLookup = FutureOr<SnippetPane?> Function(String? paneId);

/// `snippets_list`, `snippet_add`: the commands the user keeps, read from the
/// store and saved through the data API, so the palette shows an agent's
/// snippet at once. `snippet_insert`, which types into a pane, is the app's.
/// There is deliberately no delete.
class SnippetToolSet extends ServerToolSet {
  SnippetToolSet(this._context, {SnippetPaneLookup? pane})
    : _pane = pane ?? _noPane,
      _snippets = CommandSnippetDao(_context.database);

  final ServerToolContext _context;
  final SnippetPaneLookup _pane;
  final CommandSnippetDao _snippets;

  /// The shells a snippet may be tagged for: `TerminalShell`'s names, which
  /// `karmashala_terminal_core` (a Flutter package) owns.
  static const List<String> shells = [
    'powerShell',
    'commandPrompt',
    'wsl',
    'posix',
    'ssh',
  ];

  static SnippetPane? _noPane(String? _) => null;

  @override
  List<Map<String, Object?>> get schemas => snippetToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(
    () => switch (tool) {
      'snippets_list' => _list(arguments['paneId'] as String?),
      'snippet_add' => _add(
        label: arguments['label'] as String?,
        command: (arguments['command'] as String?) ?? '',
        shell: arguments['shell'] as String?,
        submit: arguments['submit'] == true,
      ),
      _ => throw ArgumentError('Unknown tool: $tool'),
    },
  );

  /// Every snippet, and which of them the named pane would be offered.
  /// `fitsPane` is per row: filtering silently would look like the snippet
  /// was never saved.
  Future<Object?> _list(String? paneId) async {
    final target = await _pane(
      paneId == null || paneId.isEmpty ? null : paneId,
    );
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
        for (final snippet in _snippets.list()..sort(compareSnippets))
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
    if (shell != null && shell.isNotEmpty && !shells.contains(shell)) {
      throw ArgumentError(
        'No shell "$shell". Use one of ${shells.join(', ')}, or omit it for '
        'a snippet that fits any shell.',
      );
    }
    final snippet = _context.write(
      SnippetAdd(
        id: _context.newId(),
        label: (label == null || label.trim().isEmpty) ? flattened : label,
        command: flattened,
        shellId: shell == null || shell.isEmpty ? null : shell,
        submit: submit,
      ),
    );
    return <String, Object?>{
      'id': snippet.id,
      'label': snippet.label,
      'command': snippet.command,
      'shell': snippet.shellId,
      'submit': snippet.submit,
    };
  }
}

/// The schemas for [SnippetToolSet], as the app served them.
const List<Map<String, Object?>> snippetToolSchemas = [
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
];
