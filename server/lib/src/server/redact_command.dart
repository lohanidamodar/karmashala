import 'dart:convert';
import 'dart:io';

import 'package:karmashala_core/logging.dart' show AgentRedactor;
import 'package:karmashala_host_protocol/host_paths.dart';
import 'package:karmashala_store/database.dart' show kStoreFileName;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../serve/client_command.dart' show HostClient;
import 'server_data_directory.dart';

/// The stored text agent output reaches, as `(table, column, isJson)`.
const List<(String, String, bool)> kRedactedColumns = [
  ('session_events', 'payload', true),
  ('session_messages', 'text', false),
  ('session_messages', 'thinking', false),
  ('session_messages', 'tool_json', true),
  ('conversation_turns', 'text', false),
  ('session_queued_messages', 'text', false),
  ('session_delegations', 'report_text', false),
  ('activity_log', 'detail', false),
];

// Cleanup keeps every character it does not mask.
const int _whole = 1 << 30;

String? _redacted(String value, {required bool isJson}) {
  if (isJson) {
    try {
      final decoded = jsonDecode(value);
      final out = AgentRedactor.jsonText(value, limit: _whole);
      return out == jsonEncode(decoded) ? null : out;
    } on FormatException {
      // Not JSON after all: redacted as text below.
    }
  }
  final out = AgentRedactor.text(value, limit: _whole);
  return out == value ? null : out;
}

/// Rows of [db] holding a secret, by `table.column`; with [apply] they are
/// rewritten masked. Counts only: no value leaves this function.
Map<String, int> redactStoreRows(Database db, {required bool apply}) {
  final found = <String, int>{};
  void scan() {
    for (final (table, column, isJson) in kRedactedColumns) {
      final columns = db
          .select('PRAGMA table_info("$table");')
          .map((row) => row['name'])
          .toSet();
      if (!columns.contains(column)) continue;
      final rows = db.select(
        'SELECT rowid AS rid, "$column" AS v FROM "$table" '
        'WHERE "$column" IS NOT NULL;',
      );
      var changed = 0;
      for (final row in rows) {
        final value = row['v'];
        if (value is! String) continue;
        final masked = _redacted(value, isJson: isJson);
        if (masked == null) continue;
        changed++;
        if (apply) {
          db.execute('UPDATE "$table" SET "$column" = ? WHERE rowid = ?;', [
            masked,
            row['rid'],
          ]);
        }
      }
      if (changed > 0) found['$table.$column'] = changed;
    }
  }

  if (!apply) {
    scan();
    return found;
  }
  // FTS5 keeps a masked row's old terms in its segments until they merge, so
  // each index is rebuilt from the masked text, and `secure_delete` zeroes
  // the pages the old segments leave free.
  db.execute('PRAGMA secure_delete = ON;');
  db.execute('BEGIN IMMEDIATE;');
  try {
    scan();
    if (found.isNotEmpty) {
      for (final row in db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND sql LIKE 'CREATE VIRTUAL TABLE % USING fts5(%';",
      )) {
        final name = row['name']! as String;
        db.execute('INSERT INTO "$name" ("$name") VALUES (\'rebuild\');');
      }
    }
    db.execute('COMMIT;');
  } catch (_) {
    db.execute('ROLLBACK;');
    rethrow;
  }
  return found;
}

/// Lines of each log in [logs] holding a secret, by file name; with [apply]
/// each such file is rewritten masked.
Map<String, int> redactLogFiles(Directory logs, {required bool apply}) {
  final found = <String, int>{};
  if (!logs.existsSync()) return found;
  final files = logs.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final lines = file.readAsLinesSync();
    var changed = 0;
    final out = [
      for (final line in lines) AgentRedactor.text(line, limit: _whole),
    ];
    for (var i = 0; i < lines.length; i++) {
      if (out[i] != lines[i]) changed++;
    }
    if (changed == 0) continue;
    found[p.basename(file.path)] = changed;
    if (apply) {
      final partial = File('${file.path}.redacting');
      partial.writeAsStringSync('${out.join('\n')}\n', flush: true);
      partial.renameSync(file.path);
    }
  }
  return found;
}

/// `karmashala_host redact-secrets`: says which server logs and stored rows
/// hold secrets agents printed, by place and count; `--apply` masks them.
Future<int> runRedactSecrets(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  Map<String, String>? environment,
}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final env = environment ?? const {};
  final apply = args.contains('--apply');
  final named = args
      .where((a) => a.startsWith('--data-dir='))
      .map((a) => a.substring('--data-dir='.length))
      .firstOrNull;
  final dataDirectory = named ?? defaultServerDataDirectory(environment: env);
  final store = p.join(dataDirectory, kStoreFileName);

  if (apply) {
    final paths = hostPathsFor('redact-secrets', environment: env);
    final client = await HostClient.connect(
      paths.socketPath,
      answerWithin: const Duration(seconds: 2),
    );
    if (client != null) {
      await client.close();
      errSink.writeln(
        'karmashala_host redact-secrets: a server is running at '
        '${paths.socketPath}. Stop it first (karmashala_host stop), so '
        'nothing is written while its logs are rewritten.',
      );
      return 3;
    }
  }

  final logs = redactLogFiles(
    Directory(p.join(dataDirectory, 'logs')),
    apply: apply,
  );
  var rows = <String, int>{};
  if (File(store).existsSync()) {
    final db = sqlite3.open(
      store,
      mode: apply ? OpenMode.readWrite : OpenMode.readOnly,
    );
    try {
      db.execute('PRAGMA busy_timeout = 5000;');
      rows = redactStoreRows(db, apply: apply);
    } finally {
      db.close();
    }
  }

  if (logs.isEmpty && rows.isEmpty) {
    sink.writeln('no secrets found in $dataDirectory');
    return 0;
  }
  for (final MapEntry(:key, :value) in logs.entries) {
    sink.writeln('logs/$key: $value line(s)');
  }
  for (final MapEntry(:key, :value) in rows.entries) {
    sink.writeln('$key: $value row(s)');
  }
  sink.writeln(
    apply
        ? 'masked.'
        : 'nothing changed. Run again with --apply to mask these in place '
              '(stop the server first; this cannot be undone).',
  );
  return 0;
}
