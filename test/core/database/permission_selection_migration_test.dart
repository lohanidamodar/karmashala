import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v35* database can be populated and then migrated.
///
/// The rewrite is the only part of v35 a fresh database cannot exercise: there
/// are no rows in one to rewrite.
Database _migratedTo(int upTo) {
  final db = sqlite3.openInMemory();
  final versions = schemaMigrations.keys.where((v) => v <= upTo).toList()
    ..sort();
  for (final version in versions) {
    schemaMigrations[version]!(db);
    db.execute('PRAGMA user_version = $version;');
  }
  return db;
}

void _seedInstallation(Database db, String id, String agentId) {
  db.execute(
    'INSERT INTO agent_installations '
    '(id, agent_kind, environment_id, executable_path, created_at) '
    'VALUES (?, ?, ?, ?, ?);',
    [id, agentId, 'env-1', 'C:/bin/$agentId.exe', '2026-08-01'],
  );
}

void _seedSession(Database db, String id, String install, String? mode) {
  db.execute(
    'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
    'use_worktree, status, created_at, permission_mode) '
    'VALUES (?, ?, ?, ?, 0, ?, ?, ?);',
    [id, 'repo-1', install, 'Session $id', 'running', '2026-08-01', mode],
  );
}

String? _modeOf(Database db, String id) =>
    db.select('SELECT permission_mode FROM sessions WHERE id = ?;', [id]).first
            .values
            .first
        as String?;

void main() {
  late Database db;

  setUp(() {
    db = _migratedTo(34);
    // Foreign keys would refuse a session with no repository row; the
    // migration is what is under test, not referential integrity.
    db.execute('PRAGMA foreign_keys = OFF;');
    _seedInstallation(db, 'i-claude', 'claudeCode');
    _seedInstallation(db, 'i-codex', 'codex');
    _seedInstallation(db, 'i-agy', 'antigravity');
  });

  tearDown(() => db.close());

  void migrate() {
    schemaMigrations[35]!(db);
    db.execute('PRAGMA user_version = 35;');
  }

  test('rewrites each agent\'s rows into its own vocabulary', () {
    _seedSession(db, 'c-ask', 'i-claude', 'ask');
    _seedSession(db, 'c-edit', 'i-claude', 'acceptEdits');
    _seedSession(db, 'c-bypass', 'i-claude', 'bypass');
    _seedSession(db, 'x-ask', 'i-codex', 'ask');
    _seedSession(db, 'x-bypass', 'i-codex', 'bypass');
    _seedSession(db, 'a-ask', 'i-agy', 'ask');
    _seedSession(db, 'a-bypass', 'i-agy', 'bypass');

    migrate();

    expect(_modeOf(db, 'c-ask'), 'mode=manual');
    expect(_modeOf(db, 'c-edit'), 'mode=acceptEdits');
    expect(_modeOf(db, 'c-bypass'), 'mode=bypassPermissions');
    expect(_modeOf(db, 'x-ask'), 'approval=on-request;sandbox=workspace-write');
    expect(_modeOf(db, 'x-bypass'), 'approval=on-request;sandbox=bypass-all');
    expect(_modeOf(db, 'a-ask'), 'mode=prompt');
    expect(_modeOf(db, 'a-bypass'), 'mode=skip-permissions');
  });

  test('the same legacy name goes different ways per agent', () {
    // The whole reason this is a migration rather than a rename: `ask` is
    // three different command lines depending on which CLI the row belongs to.
    _seedSession(db, 'c', 'i-claude', 'ask');
    _seedSession(db, 'x', 'i-codex', 'ask');
    _seedSession(db, 'a', 'i-agy', 'ask');

    migrate();

    expect({_modeOf(db, 'c'), _modeOf(db, 'x'), _modeOf(db, 'a')}, hasLength(3));
  });

  test('a null stays null — it means nobody chose, and still does', () {
    _seedSession(db, 'untouched', 'i-claude', null);
    migrate();
    expect(_modeOf(db, 'untouched'), isNull);
  });

  test('every rewritten value is one the descriptor actually declares', () {
    // The migration writes canonical strings by hand; this is what stops them
    // drifting from the axes those strings have to resolve against.
    _seedSession(db, 'c', 'i-claude', 'acceptEdits');
    _seedSession(db, 'x', 'i-codex', 'bypass');
    _seedSession(db, 'a', 'i-agy', 'accept-edits');
    _seedSession(db, 'a2', 'i-agy', 'acceptEdits');
    migrate();

    for (final (id, agentId) in [
      ('c', 'claudeCode'),
      ('x', 'codex'),
      ('a2', 'antigravity'),
    ]) {
      final support = AgentRegistry.builtIn.byId(agentId)!.launch.permission;
      final stored = _modeOf(db, id);
      expect(
        support.resolveStored(stored).canonical,
        stored,
        reason: '$agentId row $id stored $stored, which does not round-trip',
      );
      expect(support.unknownAxes(support.resolveStored(stored)), isEmpty);
    }
  });

  test('a value that was never one of the three is left alone', () {
    // Nothing today writes one, but a row from a future build must not be
    // silently rewritten into something older.
    _seedSession(db, 'future', 'i-claude', 'mode=plan');
    migrate();
    expect(_modeOf(db, 'future'), 'mode=plan');
  });

  test('running the migration twice changes nothing the second time', () {
    _seedSession(db, 'c', 'i-claude', 'ask');
    migrate();
    final once = _modeOf(db, 'c');
    schemaMigrations[35]!(db);
    expect(_modeOf(db, 'c'), once);
  });
}
