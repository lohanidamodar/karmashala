import 'dart:convert';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/usage.dart';

/// Data-access for saved [ClaudeAccount] rows. Hand-written SQL, no codegen.
class ClaudeAccountDao {
  ClaudeAccountDao(this._db);

  final AppDatabase _db;

  /// Inserts [account], or replaces the existing row with the same natural
  /// identity `(email, organization_uuid)`.
  ClaudeAccount upsert(ClaudeAccount account) {
    // SQLite counts NULLs as distinct in a UNIQUE constraint, so the table
    // alone cannot deduplicate an account whose organization is unknown.
    final existing = _db.query(
      'SELECT id FROM claude_accounts '
      'WHERE email = ? AND organization_uuid IS ? LIMIT 1;',
      [account.email, account.organizationUuid],
    );
    final saved = existing.isEmpty
        ? account
        : account.copyWith(id: existing.first['id']! as String);
    if (existing.isNotEmpty) {
      _db.execute(
        'UPDATE claude_accounts SET '
        'organization_name = ?, subscription_type = ?, rate_limit_tier = ?, '
        'claude_ai_oauth = ?, oauth_account = ?, captured_env_id = ?, '
        'captured_at = ? WHERE id = ?;',
        [
          saved.organizationName,
          saved.subscriptionType,
          saved.rateLimitTier,
          saved.claudeAiOauthJson,
          saved.oauthAccountJson,
          saved.capturedEnvironmentId,
          isoFromDate(saved.capturedAt),
          saved.id,
        ],
      );
      return saved;
    }
    _db.execute(
      'INSERT INTO claude_accounts '
      '(id, email, organization_uuid, organization_name, subscription_type, '
      ' rate_limit_tier, claude_ai_oauth, oauth_account, captured_env_id, '
      ' captured_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(email, organization_uuid) DO UPDATE SET '
      'organization_name = excluded.organization_name, '
      'subscription_type = excluded.subscription_type, '
      'rate_limit_tier = excluded.rate_limit_tier, '
      'claude_ai_oauth = excluded.claude_ai_oauth, '
      'oauth_account = excluded.oauth_account, '
      'captured_env_id = excluded.captured_env_id, '
      'captured_at = excluded.captured_at;',
      [
        saved.id,
        saved.email,
        saved.organizationUuid,
        saved.organizationName,
        saved.subscriptionType,
        saved.rateLimitTier,
        saved.claudeAiOauthJson,
        saved.oauthAccountJson,
        saved.capturedEnvironmentId,
        isoFromDate(saved.capturedAt),
      ],
    );
    return saved;
  }

  List<ClaudeAccount> getAll() {
    final rows = _db.query(
      'SELECT * FROM claude_accounts ORDER BY email, organization_name;',
    );
    return rows.map(_fromRow).toList();
  }

  ClaudeAccount? getById(String id) {
    final rows = _db.query('SELECT * FROM claude_accounts WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  void delete(String id) {
    _db.execute('DELETE FROM claude_accounts WHERE id = ?;', [id]);
  }

  ClaudeAccount _fromRow(Map<String, Object?> row) {
    final oauthAccountRaw = row['oauth_account'] as String?;
    return ClaudeAccount(
      id: row['id']! as String,
      email: row['email']! as String,
      organizationUuid: row['organization_uuid'] as String?,
      organizationName: row['organization_name'] as String?,
      subscriptionType: row['subscription_type'] as String?,
      rateLimitTier: row['rate_limit_tier'] as String?,
      claudeAiOauth:
          jsonDecode(row['claude_ai_oauth']! as String) as Map<String, dynamic>,
      oauthAccount: oauthAccountRaw == null
          ? null
          : jsonDecode(oauthAccountRaw) as Map<String, dynamic>,
      capturedEnvironmentId: row['captured_env_id'] as String?,
      capturedAt: dateFromIso(row['captured_at']),
    );
  }
}
