import 'package:agent_cli/process.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_store/database.dart';

import '../mcp/tools/server_tool_set.dart';
import 'server_artifacts.dart';
import 'session_environment.dart';

/// `artifact_show`, `artifact_list` and `artifact_update`: what an agent made,
/// shown as a card in its own thread and kept by revision. A path is read on
/// the session's own host, so a WSL or SSH session names its file as it
/// wrote it.
class ArtifactToolSet extends ServerToolSet {
  ArtifactToolSet(this._artifacts, {required AppDatabase database})
    : _environments = SessionEnvironments(database);

  final ServerArtifacts _artifacts;
  final SessionEnvironments _environments;

  ArtifactLibrary get _library => _artifacts.library;

  @override
  List<Map<String, Object?>> get schemas => artifactToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => switch (tool) {
    'artifact_show' => runTool(() => _show(arguments, callerSessionId)),
    'artifact_list' => runTool(() => _list(arguments, callerSessionId)),
    'artifact_update' => runTool(() => _update(arguments, callerSessionId)),
    _ => null,
  };

  Future<Object?> _show(Map<String, dynamic> args, String? caller) async {
    final sessionId = _caller(caller);
    final path = (args['path'] as String?)?.trim();
    final content = args['content'] as String?;
    final artifact = await _library.show(
      sessionId: sessionId,
      source: path == null || path.isEmpty
          ? null
          : EnvironmentPath(
              environmentId: _environments.of(sessionId),
              path: path,
            ),
      content: content,
      title: args['title'] as String?,
      kind: _kind(args['kind']),
      mode: _mode(args['mode']),
    );
    return {
      'artifact': _summary(artifact),
      'shown':
          'A card for it is in your thread now; the person opens it from '
          'there. Rewrite the file to make a new revision — it is picked up '
          'on its own.',
    };
  }

  Object? _list(Map<String, dynamic> args, String? caller) {
    final sessionId = targetSessionOf(args, caller);
    return {
      'artifacts': [
        for (final artifact in _library.forSession(sessionId))
          _summary(artifact),
      ],
    };
  }

  Future<Object?> _update(Map<String, dynamic> args, String? caller) async {
    final sessionId = _caller(caller);
    final id = (args['artifactId'] as String?)?.trim();
    if (id == null || id.isEmpty) {
      throw ArgumentError('artifactId is required — artifact_list has them.');
    }
    final existing = _library.byId(id);
    if (existing == null || existing.sessionId != sessionId) {
      throw StateError(
        'No artifact $id in this session. artifact_list names this '
        'session\'s artifacts; another session\'s are its own to change.',
      );
    }
    var artifact = existing;
    if (existing.hasSource) {
      artifact = await _library.refresh(id) ?? existing;
    }
    final title = args['title'] as String?;
    final mode = _mode(args['mode']);
    final content = args['content'] as String?;
    if (title != null || mode != null || content != null) {
      artifact = await _library.update(
        id,
        title: title,
        mode: mode,
        content: content,
      );
    }
    return {'artifact': _summary(artifact)};
  }

  String _caller(String? caller) {
    if (caller == null || caller.isEmpty) {
      throw ArgumentError(
        'An artifact is shown in the calling session\'s thread, and this '
        'caller is not running inside a session.',
      );
    }
    return caller;
  }

  static ArtifactKind? _kind(Object? value) {
    if (value == null) return null;
    return ArtifactKind.parse(value as String?) ??
        (throw ArgumentError(
          'kind is ${ArtifactKind.values.map((k) => k.name).join(', ')} — '
          'not "$value".',
        ));
  }

  static ArtifactMode? _mode(Object? value) {
    if (value == null) return null;
    return ArtifactMode.parse(value as String?) ??
        (throw ArgumentError('mode is inline or wide — not "$value".'));
  }

  static Map<String, Object?> _summary(Artifact a) => {
    'id': a.id,
    'title': a.title,
    'kind': a.kind.name,
    'mode': a.mode.name,
    'revision': a.revision,
    'fileName': a.fileName,
    'path': ?a.source?.path,
    'size': a.size,
    if (a.sourceState != ArtifactSourceState.present)
      'sourceState': a.sourceState.name,
    'sourceProblem': ?a.sourceProblem,
    'createdAt': a.createdAt.toIso8601String(),
  };
}

const List<Map<String, Object?>> artifactToolSchemas = [
  {
    'name': 'artifact_show',
    'description':
        'Show the person something you made, as a card in your thread that '
        'opens inside Karmashala: an HTML page (charts, reports, interactive '
        'demos — sandboxed, with no network unless the person allows it), an '
        'SVG, a mermaid diagram, markdown, an image or a PDF. Pass the '
        'absolute path of a file you wrote on your own host; rewriting that '
        'file later makes a new revision and every open view reloads. Or '
        'pass short text as content with its kind. Showing the same path '
        'again refreshes that artifact rather than adding another.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Absolute path of the file, as your shell spells it.',
        },
        'content': {
          'type': 'string',
          'description':
              'The text itself, instead of a path: html, svg, mermaid or '
              'markdown. Needs kind.',
        },
        'title': {
          'type': 'string',
          'description': 'What the card is called. Defaults to the file name.',
        },
        'kind': {
          'type': 'string',
          'enum': ['html', 'svg', 'mermaid', 'markdown', 'image', 'pdf'],
          'description': 'Inferred from the file name when a path is given.',
        },
        'mode': {
          'type': 'string',
          'enum': ['inline', 'wide'],
          'description': 'wide asks for the full width. Defaults to inline.',
        },
      },
    },
  },
  {
    'name': 'artifact_list',
    'description':
        'The artifacts a session has shown, oldest first: id, title, kind, '
        'mode, revision, and the path it is read from.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Whose artifacts. Defaults to yours.',
        },
      },
    },
  },
  {
    'name': 'artifact_update',
    'description':
        'Change one of your artifacts: its title or mode, or — for one '
        'shown as content — its text, which is a new revision. One shown '
        'from a file is re-read now, so a rewrite is picked up at once.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'artifactId': {'type': 'string'},
        'title': {'type': 'string'},
        'mode': {
          'type': 'string',
          'enum': ['inline', 'wide'],
        },
        'content': {'type': 'string'},
      },
      'required': ['artifactId'],
    },
  },
];
