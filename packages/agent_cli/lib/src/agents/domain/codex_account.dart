import 'dart:convert';

/// A saved snapshot of the credential bundle Codex owns in `auth.json`.
class CodexAccount {
  const CodexAccount({
    required this.id,
    required this.accountId,
    required this.auth,
    required this.capturedAt,
    this.email,
    this.planType,
    this.capturedEnvironmentId,
  });

  final String id;
  final String accountId;
  final String? email;
  final String? planType;
  final Map<String, dynamic> auth;
  final String? capturedEnvironmentId;
  final DateTime capturedAt;

  String get authJson => jsonEncode(auth);

  CodexAccount copyWith({String? id}) => CodexAccount(
    id: id ?? this.id,
    accountId: accountId,
    email: email,
    planType: planType,
    auth: auth,
    capturedEnvironmentId: capturedEnvironmentId,
    capturedAt: capturedAt,
  );
}

/// The account currently authenticated in one Codex installation.
class CodexAuthSnapshot {
  const CodexAuthSnapshot({
    required this.environmentId,
    this.accountId,
    this.email,
    this.planType,
    this.accessTokenExpiresAt,
  });

  const CodexAuthSnapshot.signedOut(this.environmentId)
    : accountId = null,
      email = null,
      planType = null,
      accessTokenExpiresAt = null;

  final String environmentId;
  final String? accountId;
  final String? email;
  final String? planType;
  final DateTime? accessTokenExpiresAt;

  bool get isSignedIn => accountId != null;
}
