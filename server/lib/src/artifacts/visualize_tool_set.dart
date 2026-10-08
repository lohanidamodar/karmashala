import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_core/visuals.dart';
import 'package:karmashala_store/database.dart';

import '../mcp/tools/server_tool_set.dart';
import 'session_environment.dart';

/// `visualize`: a chart, table, diagram, image, metric tiles, progress or a
/// JSON tree drawn in the caller's thread mid-turn, and updated in place by
/// its id. Kept with the session, so it is there when the thread reopens.
class VisualizeToolSet extends ServerToolSet {
  VisualizeToolSet(this._visuals, {required AppDatabase database})
    : _environments = SessionEnvironments(database);

  final VisualBoard _visuals;
  final SessionEnvironments _environments;

  @override
  List<Map<String, Object?>> get schemas => visualizeToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => switch (tool) {
    'visualize' => runTool(() => _draw(arguments, callerSessionId)),
    _ => null,
  };

  Future<Object?> _draw(Map<String, dynamic> args, String? caller) async {
    if (caller == null || caller.isEmpty) {
      throw ArgumentError(
        'A visual is drawn in the calling session\'s thread, and this caller '
        'is not running inside a session.',
      );
    }
    final kindName = args['kind'] as String?;
    final kind = kindName == null ? null : VisualKind.parse(kindName.trim());
    if (kindName != null && kind == null) {
      throw ArgumentError(
        'kind is ${VisualKind.values.map((k) => k.name).join(', ')} — not '
        '"$kindName".',
      );
    }
    final VisualDrawn drawn;
    try {
      drawn = await _visuals.draw(
        sessionId: caller,
        environmentId: _environments.of(caller),
        id: args['id'] as String?,
        kind: kind,
        title: args['title'] as String?,
        data: args['data'],
        append: args['append'] == true,
      );
    } on FormatException catch (error) {
      throw ArgumentError(
        'data ${error.message}. Nothing was drawn; fix it and call again.',
      );
    }
    final visual = drawn.visual;
    return {
      'id': visual.id,
      'kind': visual.kind,
      'title': ?visual.title,
      'revision': visual.revision,
      'drawn': drawn.created
          ? 'In your thread now. Call visualize again with id '
                '"${visual.id}" to update it in place.'
          : 'Updated in place (revision ${visual.revision}).',
      'note': ?drawn.note,
    };
  }
}

const List<Map<String, Object?>> visualizeToolSchemas = [
  {
    'name': 'visualize',
    'description':
        'Draw a visual in your own thread, mid-turn, where you call it: a '
        'chart, a table, a mermaid diagram, an image, metric tiles, a '
        'progress bar or a JSON tree. Call again with the same id to update '
        'it in place — a progress bar that moves, a chart that grows '
        '(append: true adds points or rows), a table that fills. It is kept '
        'with the session. Use it for something small and live; a full page, '
        'a report or a file the person opens goes to artifact_show instead. '
        'Data by kind — chart: {"type": "bar"|"line", "unit", "data": '
        '[{"label", "value"}] or [{"x", "y"}], or "series": [{"name", '
        '"data"}]}; table: {"columns": [...], "rows": [[...]]} or a list of '
        'objects; diagram: the mermaid text (flowchart or sequenceDiagram); '
        'image: {"path": absolute path on your host} or {"url"}; metric: '
        '[{"label", "value", "unit", "delta"}]; progress: {"value", "max", '
        '"label", "steps": [{"label", "status"}]}; tree: any JSON. A bad '
        'spec is refused with the field to fix. Caps: '
        '${VisualCaps.points} points, ${VisualCaps.rows} rows, '
        '${VisualCaps.columns} columns, a 5 MiB image.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'string',
          'enum': [
            'chart',
            'table',
            'diagram',
            'image',
            'metric',
            'progress',
            'tree',
          ],
          'description': 'Required for a new visual; an update keeps its own.',
        },
        'data': {
          'description':
              'The visual itself, shaped by kind (see the tool description). '
              'JSON text is read too.',
        },
        'title': {'type': 'string', 'description': 'Drawn above it.'},
        'id': {
          'type': 'string',
          'description':
              'Your handle for it: letters, digits, ".", "_", "-". The same '
              'id again updates that visual in place. Omit for a one-off; '
              'the answer names the id it was given.',
        },
        'append': {
          'type': 'boolean',
          'description':
              'Add data\'s points to a chart\'s series, or its rows to a '
              'table, instead of replacing. Past the caps the oldest go.',
        },
      },
    },
  },
];
