import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/claude_account.dart';

/// Data-access for saved [ClaudeAccount] rows. Hand-written SQL, no codegen.
class ClaudeAccountDao {
  ClaudeAccountDao(this._db);

  final AppDatabase _db;

  /// Inserts [account], or replaces the existing row with the same natural
  /// identity `(email, organization_uuid)`.
  void upsert(ClaudeAccount account) {
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
        account.id,
        account.email,
        account.organizationUuid,
        account.organizationName,
        account.subscriptionType,
        account.rateLimitTier,
        account.claudeAiOauthJson,
        account.oauthAccountJson,
        account.capturedEnvironmentId,
        isoFromDate(account.capturedAt),
      ],
    );
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
