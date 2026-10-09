import 'dart:convert';

import 'package:karmashala_store/database.dart';

import '../domain/pipeline.dart';
import '../domain/pipeline_run.dart';
import '../service/pipeline_ports.dart';

/// Saved pipelines and pipeline runs (v92). A run is one JSON document: its
/// definition as it started and a record per stage attempt.
class PipelineDao implements PipelineRecords {
  PipelineDao(this._db);

  final AppDatabase _db;

  @override
  List<PipelineDefinition> definitions() => [
    for (final row in _db.query(
      'SELECT definition FROM pipelines ORDER BY name COLLATE NOCASE, id;',
    ))
      ?_definition(row['definition']),
  ];

  @override
  PipelineDefinition? definition(String id) {
    final rows = _db.query('SELECT definition FROM pipelines WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _definition(rows.first['definition']);
  }

  @override
  void saveDefinition(PipelineDefinition definition, DateTime at) =>
      _db.execute(
        'INSERT INTO pipelines (id, name, definition, updated_at) '
        'VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
        'name = excluded.name, definition = excluded.definition, '
        'updated_at = excluded.updated_at;',
        [
          definition.id,
          definition.name,
          jsonEncode(definition.copyWith(builtIn: false).toJson()),
          isoFromDate(at),
        ],
      );

  @override
  void deleteDefinition(String id) =>
      _db.execute('DELETE FROM pipelines WHERE id = ?;', [id]);

  @override
  PipelineRun? run(String id) {
    final rows = _db.query('SELECT run FROM pipeline_runs WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _run(rows.first['run']);
  }

  @override
  List<PipelineRun> runs({int limit = 50}) => [
    for (final row in _db.query(
      'SELECT run FROM pipeline_runs ORDER BY created_at DESC, id LIMIT ?;',
      [limit],
    ))
      ?_run(row['run']),
  ];

  @override
  List<PipelineRun> active() => [
    for (final row in _db.query(
      'SELECT run FROM pipeline_runs WHERE state IN (?, ?) '
      'ORDER BY created_at, id;',
      [
        PipelineRunState.running.storedName,
        PipelineRunState.waiting.storedName,
      ],
    ))
      ?_run(row['run']),
  ];

  @override
  void putRun(PipelineRun run) => _db.execute(
    'INSERT INTO pipeline_runs '
    '(id, repository_id, state, run, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
    'state = excluded.state, run = excluded.run, '
    'updated_at = excluded.updated_at;',
    [
      run.id,
      run.repositoryId,
      run.state.storedName,
      jsonEncode(run.toJson()),
      isoFromDate(run.createdAt),
      isoFromDate(run.updatedAt),
    ],
  );

  static PipelineDefinition? _definition(Object? column) {
    try {
      final json = jsonDecode(column! as String);
      return json is Map
          ? PipelineDefinition.fromJson(json.cast<String, Object?>())
          : null;
    } on Object {
      return null;
    }
  }

  static PipelineRun? _run(Object? column) {
    try {
      final json = jsonDecode(column! as String);
      return json is Map
          ? PipelineRun.fromJson(json.cast<String, Object?>())
          : null;
    } on Object {
      return null;
    }
  }
}
