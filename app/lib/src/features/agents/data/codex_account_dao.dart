import 'dart:convert';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/usage.dart';

class CodexAccountDao {
  CodexAccountDao(this._db);

  final AppDatabase _db;

  CodexAccount upsert(CodexAccount account) {
    final existing = _db.query(
      'SELECT id FROM codex_accounts WHERE account_id = ?;',
      [account.accountId],
    );
    final saved = existing.isEmpty
        ? account
        : account.copyWith(id: existing.single['id']! as String);
    _db.execute(
      'INSERT INTO codex_accounts '
      '(id, account_id, email, plan_type, auth_json, captured_env_id, captured_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(account_id) DO UPDATE SET '
      'email=excluded.email, plan_type=excluded.plan_type, '
      'auth_json=excluded.auth_json, captured_env_id=excluded.captured_env_id, '
      'captured_at=excluded.captured_at;',
      [
        saved.id,
        saved.accountId,
        saved.email,
        saved.planType,
        saved.authJson,
        saved.capturedEnvironmentId,
        isoFromDate(saved.capturedAt),
      ],
    );
    return saved;
  }

  List<CodexAccount> getAll() => _db
      .query('SELECT * FROM codex_accounts ORDER BY email, account_id;')
      .map(_fromRow)
      .toList();

  void delete(String id) =>
      _db.execute('DELETE FROM codex_accounts WHERE id = ?;', [id]);

  CodexAccount _fromRow(Map<String, Object?> row) => CodexAccount(
    id: row['id']! as String,
    accountId: row['account_id']! as String,
    email: row['email'] as String?,
    planType: row['plan_type'] as String?,
    auth: jsonDecode(row['auth_json']! as String) as Map<String, dynamic>,
    capturedEnvironmentId: row['captured_env_id'] as String?,
    capturedAt: dateFromIso(row['captured_at']),
  );
}
