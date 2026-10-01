import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_store/database.dart';

import '../domain/uuid.dart';
import 'checkout_project.dart';

/// The `flutter_run_configurations` rows (v61): named launches per project.
class FlutterRunConfigurations {
  FlutterRunConfigurations(
    this._db, {
    DateTime Function()? clock,
    String Function()? newId,
  }) : _now = clock ?? (() => DateTime.now().toUtc()),
       _newId = newId ?? newUuid;

  final AppDatabase _db;
  final DateTime Function() _now;
  final String Function() _newId;

  /// [projectId]'s configurations by name; every project's when null.
  List<FlutterRunConfiguration> list({String? projectId}) => [
    for (final row
        in projectId == null
            ? _db.query(
                'SELECT * FROM flutter_run_configurations ORDER BY name;',
              )
            : _db.query(
                'SELECT * FROM flutter_run_configurations WHERE project_id = ? '
                'ORDER BY name;',
                [projectId],
              ))
      _fromRow(row),
  ];

  FlutterRunConfiguration? byId(String id) {
    final rows = _db.query(
      'SELECT * FROM flutter_run_configurations WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Matched by name without regard to case, as a person types it.
  FlutterRunConfiguration? named(String projectId, String name) {
    final rows = _db.query(
      'SELECT * FROM flutter_run_configurations WHERE project_id = ? '
      'AND lower(name) = lower(?);',
      [projectId, name.trim()],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Inserts [draft], or replaces the row with its id. An empty id is a new
  /// one. Refuses a name another configuration of the project already has.
  FlutterRunConfiguration save(FlutterRunConfiguration draft) {
    draft.validate();
    final clash = named(draft.projectId, draft.name);
    final existing = draft.id.isEmpty ? null : byId(draft.id);
    if (clash != null && clash.id != draft.id) {
      throw FlutterRunConfigurationInvalid(
        'This project already has a run configuration called "${clash.name}".',
      );
    }
    final now = _now();
    final saved = draft.copyWith(
      id: existing?.id ?? (draft.id.isEmpty ? _newId() : draft.id),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    _db.execute(
      'INSERT OR REPLACE INTO flutter_run_configurations (id, project_id, '
      'name, project_directory, target, flavor, build_mode, dart_defines, '
      'dart_define_files, device_id, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        saved.id,
        saved.projectId,
        saved.name.trim(),
        saved.projectDirectory,
        saved.target,
        saved.flavor,
        saved.buildMode.name,
        jsonEncode(saved.dartDefines),
        jsonEncode(saved.dartDefineFiles),
        saved.deviceId,
        saved.createdAt!.toIso8601String(),
        saved.updatedAt!.toIso8601String(),
      ],
    );
    return saved;
  }

  /// Whether a row was there to delete.
  bool delete(String id) {
    final there = byId(id) != null;
    _db.execute('DELETE FROM flutter_run_configurations WHERE id = ?;', [id]);
    return there;
  }

  static FlutterRunConfiguration _fromRow(Map<String, Object?> row) {
    List<String> list(Object? json) => [
      for (final value in jsonDecode(json as String? ?? '[]') as List<Object?>)
        '$value',
    ];
    return FlutterRunConfiguration(
      id: row['id']! as String,
      projectId: row['project_id']! as String,
      name: row['name']! as String,
      projectDirectory: row['project_directory'] as String?,
      target: row['target'] as String?,
      flavor: row['flavor'] as String?,
      buildMode:
          FlutterBuildMode.fromName(row['build_mode']) ??
          FlutterBuildMode.debug,
      dartDefines: list(row['dart_defines']),
      dartDefineFiles: list(row['dart_define_files']),
      deviceId: row['device_id'] as String?,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? ''),
    );
  }
}

/// A `flutter run` resolved against a configuration: what to launch, where,
/// and with which flags.
typedef ConfiguredRun = ({
  EnvironmentPath project,
  String? deviceId,
  List<String> arguments,
  FlutterRunConfiguration? configuration,
});

/// Resolves a run from a checkout, an optional configuration (by id or by
/// name) and what the caller said explicitly. Explicit wins: a device or
/// sub-project named here replaces the configuration's, and explicit flags
/// are appended after its own (see [FlutterRunConfiguration.runArguments]).
ConfiguredRun resolveConfiguredRun({
  required CheckoutRows rows,
  required FlutterRunConfigurations? configurations,
  required String checkoutId,
  String? configuration,
  String? projectDirectory,
  String? deviceId,
  List<String> explicit = const [],
}) {
  // The usual "checkoutId is required" refusal, before a lookup can word it.
  if (checkoutId.trim().isEmpty) projectOfCheckout(rows, const {});
  FlutterRunConfiguration? chosen;
  final wanted = configuration?.trim() ?? '';
  if (wanted.isNotEmpty) {
    final store =
        configurations ??
        (throw StateError('This server keeps no run configurations.'));
    final repository =
        rows.repository(checkoutId) ??
        (throw StateError(
          'No checkout with id $checkoutId. list_checkouts has them.',
        ));
    chosen =
        store.byId(wanted) ??
        store.named(repository.projectId, wanted) ??
        (throw ArgumentError(
          'No run configuration "$wanted" in this project. '
          'flutter_run_config with action "list" names the ones there are.',
        ));
    if (chosen.projectId != repository.projectId) {
      throw ArgumentError(
        'Run configuration "${chosen.name}" belongs to another project.',
      );
    }
  }
  final directory = (projectDirectory?.trim().isNotEmpty ?? false)
      ? projectDirectory
      : chosen?.projectDirectory;
  final project = projectOfCheckout(rows, {
    'checkoutId': checkoutId,
    'projectDirectory': ?directory,
  });
  final device = (deviceId?.trim().isNotEmpty ?? false)
      ? deviceId!.trim()
      : chosen?.deviceId;
  return (
    project: project,
    deviceId: device,
    arguments: chosen?.runArguments(explicit: explicit) ?? explicit,
    configuration: chosen,
  );
}
