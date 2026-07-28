import 'claude_account.dart';

/// The *live* logged-in state of one Claude installation, read from its
/// on-disk files (`.claude.json` for identity, `.credentials.json` for the
/// token). This is the "who is logged in right now" view shown in settings; it
/// is distinct from a saved [ClaudeAccount] snapshot.
class ClaudeAuthSnapshot {
  const ClaudeAuthSnapshot({
    required this.environmentId,
    this.email,
    this.organizationName,
    this.organizationUuid,
    this.subscriptionType,
    this.rateLimitTier,
    this.accessTokenExpiresAt,
  });

  /// An empty snapshot for an installation with no credentials on disk.
  const ClaudeAuthSnapshot.signedOut(this.environmentId)
    : email = null,
      organizationName = null,
      organizationUuid = null,
      subscriptionType = null,
      rateLimitTier = null,
      accessTokenExpiresAt = null;

  final String environmentId;
  final String? email;
  final String? organizationName;
  final String? organizationUuid;
  final String? subscriptionType;
  final String? rateLimitTier;
  final DateTime? accessTokenExpiresAt;

  /// Whether a signed-in account was found for this installation.
  bool get isSignedIn => email != null;

  /// Whether [account] is the one currently logged in. Matched by email and,
  /// when both sides know it, organization — so the same email in two orgs
  /// stays distinct.
  bool matches(ClaudeAccount account) {
    if (!isSignedIn || account.email != email) return false;
    if (organizationUuid != null && account.organizationUuid != null) {
      return organizationUuid == account.organizationUuid;
    }
    return true;
  }
}
