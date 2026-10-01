import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_launch/karmashala_launch.dart'
    show AgentPaneLaunch, terminalProfileFromId;
import 'package:karmashala_projects/store.dart' show RepositoryDao;
import 'package:karmashala_session_engine/store.dart'
    show ImportedSessionDao, SessionDao;
import 'package:karmashala_snippets/store.dart' show CommandSnippetDao;

import '../../sessions/launch/server_session_launcher.dart';
import '../../terminals/server_terminals.dart';
import 'launch_tool_set.dart' show kNoWindowOpen;
import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// Words for a tool whose whole effect is on a person's screen, with none.
String _noWindow(String what) =>
    'NOTHING WAS SHOWN: $kNoWindowOpen. $what needs a Karmashala window; '
    'open Karmashala on any device connected to this server and ask again.';

/// **`open_session`**, by the server (slice 5b): a session this server runs
/// is shown in the person's window; one that is not running is resumed here
/// first; an imported CLI session is opened in a terminal window of the
/// person's own machine, by that window.
class OpenSessionToolSet extends ServerToolSet {
  OpenSessionToolSet(this._context, {required this.launches})
    : _sessions = SessionDao(_context.database),
      _imported = ImportedSessionDao(_context.database);

  final ServerToolContext _context;
  final ServerSessionLauncher launches;
  final SessionDao _sessions;
  final ImportedSessionDao _imported;

  @override
  List<Map<String, Object?>> get schemas => openSessionToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => tool == 'open_session'
      ? runTool(() => _open(arguments['id'] as String?))
      : null;

  Future<Object?> _open(String? id) async {
    if (id == null) throw ArgumentError('Missing session id.');
    final native = _sessions.getById(id);
    if (native != null) {
      if (launches.runsHere(native.id)) {
        final shown = _show(native.id, native.title, null);
        return {
          'opened': native.title,
          'sessionId': native.id,
          'reattached': true,
          'where': _where(shown),
        };
      }
      final started = await launches.resume(native.id);
      final shown = _show(started.sessionId, started.session.title, started);
      return {
        'opened': started.session.title,
        'sessionId': started.sessionId,
        'reattached': started.adopted,
        // A directory that has gone resumes the agent at the checkout, and its
        // store is keyed by directory — hence an otherwise empty conversation.
        'note': ?started.workingDirectoryNotice,
        'where': _where(shown),
      };
    }
    final imported = _imported.getById(id);
    if (imported == null) throw StateError('Session not found: $id');
    // An imported entry can name a conversation one of ours still runs: show
    // that, rather than putting a second agent on it.
    for (final row in _sessions.getAllByExternalSessionId(imported.externalId)) {
      if (!launches.runsHere(row.id)) continue;
      final shown = _show(row.id, row.title, null);
      return {
        'opened': row.title,
        'sessionId': row.id,
        'reattached': true,
        'where': _where(shown),
      };
    }
    if (!_context.data.tellIntent(OpenImportedSession(imported.id))) {
      throw StateError(_noWindow('Opening an imported CLI session'));
    }
    // Named in the answer, because the caller cannot see the desktop: this
    // opens a window, and an automated caller cannot undo it.
    return {
      'opened': imported.displayTitle,
      'environmentId': imported.environmentId,
      'externalTerminal': 'the default terminal of the Karmashala window\'s '
          'machine',
      'note':
          'Asked the Karmashala window to open a new external terminal window '
          'on it. Close it yourself.',
    };
  }

  bool _show(String sessionId, String title, SessionStarted? started) =>
      _context.data.tellIntent(
        OpenSessionTab(
          sessionId: sessionId,
          title: title,
          launch: started?.launch,
        ),
      );

  static String _where(bool shown) => shown
      ? 'running in the Karmashala server, shown in a tab of the Karmashala '
            'window'
      : 'running in the Karmashala server; $kNoWindowOpen — a window shows it '
            'when it is opened';
}

/// **`snippet_insert`** (slice 5b): the server checks the snippet and, for a
/// terminal it runs, that the snippet fits the pane's shell; the window the
/// person last used types it — into the pane named, or the one in front of
/// them — and leaves it at the prompt.
class SnippetInsertToolSet extends ServerToolSet {
  SnippetInsertToolSet(this._context, {required this.terminals})
    : _snippets = CommandSnippetDao(_context.database);

  final ServerToolContext _context;
  final ServerTerminals terminals;
  final CommandSnippetDao _snippets;

  @override
  List<Map<String, Object?>> get schemas => snippetControlToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => tool == 'snippet_insert'
      ? runTool(
          () => _insert(
            id: arguments['id'] as String?,
            paneId: arguments['paneId'] as String?,
          ),
        )
      : null;

  Object? _insert({String? id, String? paneId}) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required. snippets_list has the ids.');
    }
    final snippet = _snippets.getById(id);
    if (snippet == null) throw StateError('No snippet with id $id.');
    final named = paneId == null || paneId.isEmpty ? null : paneId;
    final target = named ?? _context.data.focusedPaneId;
    final record = target == null
        ? null
        : terminals.records.where((r) => r.paneId == target).firstOrNull;
    if (named != null && record == null) {
      throw StateError('No terminal pane with id $named.');
    }
    final agentPane =
        record != null && AgentPaneLaunch.isAgentProfileId(record.profileId);
    if (record != null && !agentPane) {
      final shell = terminalProfileFromId(record.profileId)?.shell.name;
      if (!snippet.fitsShell(shell)) {
        throw StateError(
          'Snippet ${snippet.id} is tagged for ${snippet.shellId} and pane '
          '${record.paneId} is running ${shell ?? 'an unrecognised shell'}.',
        );
      }
    }
    if (!_context.data.tellIntent(
      InsertSnippet(snippetId: snippet.id, paneId: target),
    )) {
      throw StateError(_noWindow('Typing a snippet into a pane'));
    }
    final submitted = snippet.submit && !agentPane;
    return <String, Object?>{
      'id': snippet.id,
      'paneId': target ?? 'the pane in front of the person',
      'command': snippet.command,
      'submitted': submitted,
      'note': agentPane
          ? 'Asked the Karmashala window to type it into an agent pane, and '
                'NOT submit it: a carriage return there takes a turn in a live '
                'session, so submit is ignored in an agent pane whatever the '
                'snippet says.'
          : submitted
          ? 'Asked the Karmashala window to type and submit it, because this '
                'snippet is saved with submit=true. Nothing here waited for it '
                'or read an exit code — use terminal_run for that.'
          : 'Asked the Karmashala window to type it at the prompt and leave it '
                'there. It has NOT run: the user presses Enter. This is the '
                'point of the tool — use terminal_run if you meant to run '
                'something.',
    };
  }
}

/// **`session_draft`**: a message offered to a session, not sent — the window
/// the person last used leaves it in that session's message box, or types it
/// at its prompt without Enter. The person reviews it and sends it, or not.
class SessionDraftToolSet extends ServerToolSet {
  SessionDraftToolSet(this._context)
    : _sessions = SessionDao(_context.database);

  final ServerToolContext _context;
  final SessionDao _sessions;

  @override
  List<Map<String, Object?>> get schemas => sessionDraftToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => tool == 'session_draft'
      ? runTool(
          () => _draft(
            targetSessionOf(arguments, callerSessionId),
            (arguments['text'] as String?) ?? '',
          ),
        )
      : null;

  Object? _draft(String sessionId, String text) {
    if (text.trim().isEmpty) {
      throw ArgumentError('text is required and cannot be blank.');
    }
    final session = _sessions.getById(sessionId);
    if (session == null) throw StateError('No session with id $sessionId.');
    if (!_context.data.tellIntent(
      DraftForSession(sessionId: sessionId, text: text),
    )) {
      throw StateError(_noWindow('Drafting a message for a session'));
    }
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'sent': false,
      'note':
          'Offered to "${session.title}" in the Karmashala window the person '
          'last used: left in its message box, or typed at its prompt without '
          'Enter when its terminal is on screen. It has NOT been sent — the '
          'person reads it and sends it, edits it, or clears it. A second '
          'draft before they act is added under the first.',
    };
  }
}

const List<Map<String, Object?>> sessionDraftToolSchemas = [
  {
    'name': 'session_draft',
    'description':
        'Put a message in a session\'s message box for the PERSON to send — '
        'it is not sent. Use it to propose what a session should be told '
        'next and leave the decision to them; session_send is the one that '
        'sends. Omit sessionId to draft into your own session\'s box.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Which session, from list_sessions. Defaults to you.',
        },
        'text': {'type': 'string', 'description': 'The message to offer.'},
      },
      'required': ['text'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'sent': {'type': 'boolean'},
        'note': {'type': 'string'},
      },
      'required': ['sessionId', 'title', 'sent', 'note'],
    },
  },
];

/// **`select_checkout`** (slice 5b): the server checks the checkout; the
/// window the person last used points its Explorer, diff view and side panel
/// at it.
class SelectCheckoutToolSet extends ServerToolSet {
  SelectCheckoutToolSet(this._context)
    : _repositories = RepositoryDao(_context.database);

  final ServerToolContext _context;
  final RepositoryDao _repositories;

  @override
  List<Map<String, Object?>> get schemas => workspaceControlToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => tool == 'select_checkout'
      ? runTool(() => _select(arguments['repositoryId'] as String?))
      : null;

  Object? _select(String? repositoryId) {
    if (repositoryId == null || repositoryId.isEmpty) {
      throw ArgumentError(
        'repositoryId is required. list_checkouts has the ids.',
      );
    }
    final repository = _repositories.getById(repositoryId);
    if (repository == null) {
      throw StateError('No checkout with id $repositoryId.');
    }
    if (!_context.data.tellIntent(SelectCheckout(repository.id))) {
      throw StateError(_noWindow('Pointing the Explorer at a checkout'));
    }
    return <String, Object?>{
      'repositoryId': repository.id,
      'name': repository.name,
      'path': repository.path.path,
      'projectId': repository.projectId,
      'selected': true,
    };
  }
}

/// `open_session`, moved from the app with its words unchanged.
const List<Map<String, Object?>> openSessionToolSchemas = [
  {
    'name': 'open_session',
    'description':
        'Open one session by its id. A Karmashala session that is still '
        'running is reattached to a tab; anything else is resumed. An '
        'imported CLI session opens a new external terminal window every '
        'time this is called, and nothing here closes one — do not call it '
        'over a list of sessions.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'Session id from list_sessions.',
        },
      },
      'required': ['id'],
    },
  },
];

/// `snippet_insert`, moved from the app with its words unchanged.
const List<Map<String, Object?>> snippetControlToolSchemas = [
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

/// `select_checkout`, moved from the app with its words unchanged.
const List<Map<String, Object?>> workspaceControlToolSchemas = [
  {
    'name': 'select_checkout',
    'description':
        'Point Karmashala\'s Explorer, diff view and side panel at a '
        'checkout. This is what the user sees change on screen, so use it to '
        'show someone where you are working rather than to navigate for '
        'yourself.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {
          'type': 'string',
          'description': 'Which checkout, from list_checkouts.',
        },
      },
      'required': ['repositoryId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {'type': 'string'},
        'name': {'type': 'string'},
        'path': {'type': 'string'},
        'projectId': {'type': 'string'},
        'selected': {'type': 'boolean'},
      },
      'required': ['repositoryId', 'selected'],
    },
  },
];
