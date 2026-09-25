import './claude_account.dart';

/// The *live* logged-in state of one Claude installation, read from its
/// on-disk files (`.claude.json` for identity, `.credentials.json` for the
/// token). This is the "who is logged in right now" view shown in settings; it
/// is distinct from a saved [ClaudeAccount] snapshot.
class ClaudeAuthSnapshot {
  const ClaudeAuthSnapshot({
    required this.environmentId,
    this.email,
    this.keychainRefusal,
    this.readFailure,
    this.organizationName,
    this.organizationUuid,
    this.subscriptionType,
    this.rateLimitTier,
    this.accessTokenExpiresAt,
  });

  /// An empty snapshot for an installation with no credentials on disk.
  ///
  /// [keychainRefusal] is the one kind of emptiness that is not a signed-out
  /// account: macOS was asked for the credential and said no. It is a whole
  /// sentence, with the age of the reading in it, because "not signed in" is
  /// the wrong thing to tell someone whose credential is sitting there behind
  /// a *Deny* they clicked.
  const ClaudeAuthSnapshot.signedOut(
    this.environmentId, {
    this.keychainRefusal,
    this.readFailure,
  }) : email = null,
       organizationName = null,
       organizationUuid = null,
       subscriptionType = null,
       rateLimitTier = null,
       accessTokenExpiresAt = null;

  final String environmentId;

  /// Why there is no account when a file was there and could not be used —
  /// unreadable, or not JSON. Null for a signed-out installation.
  final String? readFailure;
  final String? email;
  final String? organizationName;
  final String? organizationUuid;
  final String? subscriptionType;
  final String? rateLimitTier;
  final DateTime? accessTokenExpiresAt;

  /// Why there is no account, when the reason is a Keychain refusal rather
  /// than a signed-out installation. Null everywhere else, including on a
  /// Keychain that simply holds nothing.
  final String? keychainRefusal;

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
