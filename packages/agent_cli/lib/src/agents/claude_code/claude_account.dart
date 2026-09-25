import 'dart:convert';

/// A saved snapshot of a Claude Code account: the OAuth token bundle plus the
/// identity record, captured from a Claude installation so the account can be
/// restored (switched back to) later without re-authenticating.
///
/// [claudeAiOauth] is the `claudeAiOauth` object from `.credentials.json` and
/// [oauthAccount] is the `oauthAccount` object from `.claude.json`. Both are
/// kept verbatim (as decoded maps) so a switch restores exactly what Claude
/// Code wrote; the remaining fields are denormalized copies for display and
/// identity.
class ClaudeAccount {
  const ClaudeAccount({
    required this.id,
    required this.email,
    required this.claudeAiOauth,
    required this.capturedAt,
    this.organizationUuid,
    this.organizationName,
    this.subscriptionType,
    this.rateLimitTier,
    this.oauthAccount,
    this.capturedEnvironmentId,
  });

  final String id;
  final String email;

  /// The `claudeAiOauth` token bundle (accessToken, refreshToken, expiresAt, …).
  final Map<String, dynamic> claudeAiOauth;

  /// The `oauthAccount` identity record from `.claude.json`, if it was present.
  final Map<String, dynamic>? oauthAccount;

  final String? organizationUuid;
  final String? organizationName;
  final String? subscriptionType;
  final String? rateLimitTier;

  /// Id of the environment this account was captured from (informational).
  final String? capturedEnvironmentId;

  final DateTime capturedAt;

  /// When the stored access token expires, if known.
  DateTime? get accessTokenExpiresAt {
    final raw = claudeAiOauth['expiresAt'];
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    return null;
  }

  ClaudeAccount copyWith({
    String? id,
    String? email,
    Map<String, dynamic>? claudeAiOauth,
    Map<String, dynamic>? oauthAccount,
    String? organizationUuid,
    String? organizationName,
    String? subscriptionType,
    String? rateLimitTier,
    String? capturedEnvironmentId,
    DateTime? capturedAt,
  }) => ClaudeAccount(
    id: id ?? this.id,
    email: email ?? this.email,
    claudeAiOauth: claudeAiOauth ?? this.claudeAiOauth,
    oauthAccount: oauthAccount ?? this.oauthAccount,
    organizationUuid: organizationUuid ?? this.organizationUuid,
    organizationName: organizationName ?? this.organizationName,
    subscriptionType: subscriptionType ?? this.subscriptionType,
    rateLimitTier: rateLimitTier ?? this.rateLimitTier,
    capturedEnvironmentId: capturedEnvironmentId ?? this.capturedEnvironmentId,
    capturedAt: capturedAt ?? this.capturedAt,
  );

  /// Encodes [claudeAiOauth] for storage.
  String get claudeAiOauthJson => jsonEncode(claudeAiOauth);

  /// Encodes [oauthAccount] for storage, or `null` when absent.
  String? get oauthAccountJson =>
      oauthAccount == null ? null : jsonEncode(oauthAccount);
}
