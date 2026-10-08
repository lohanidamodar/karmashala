/// GitHub access on a server (Settings → Source control → GitHub) and the
/// secrets agents ask the owner for. **No value here ever carries a token or
/// a secret**: a token travels client → server in `github.token.save` only,
/// and a secret in `secrets.provide` only.
library;

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String? _text(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// Where one host's GitHub access comes from, and what the person chose.
class GithubHostAccess {
  const GithubHostAccess({
    required this.host,
    required this.status,
    this.source,
    this.login,
    this.off = false,
    this.account,
    this.ghAccounts = const [],
    this.ghActiveAccount,
  });

  final String host;

  /// The plain sentence: "Using gh as @login", "No GitHub access: …".
  final String status;

  /// `settings`, `environment` or `gh`; null when there is no access.
  final String? source;
  final String? login;

  /// Turned off in Settings: Karmashala uses no GitHub on this host.
  final bool off;

  /// The gh account chosen for this host; null follows gh's active one.
  final String? account;

  /// The accounts gh is signed in to on this host.
  final List<String> ghAccounts;
  final String? ghActiveAccount;

  Map<String, Object?> toJson() => {
    'host': host,
    'status': status,
    'source': ?source,
    'login': ?login,
    if (off) 'off': true,
    'account': ?account,
    if (ghAccounts.isNotEmpty) 'ghAccounts': ghAccounts,
    'ghActiveAccount': ?ghActiveAccount,
  };

  factory GithubHostAccess.fromJson(Map<String, Object?> json) =>
      GithubHostAccess(
        host: json['host']! as String,
        status: json['status'] as String? ?? '',
        source: _text(json['source']),
        login: _text(json['login']),
        off: json['off'] == true,
        account: _text(json['account']),
        ghAccounts: [
          for (final login in (json['ghAccounts'] as List?) ?? const [])
            if (login is String) login,
        ],
        ghActiveAccount: _text(json['ghActiveAccount']),
      );
}

/// A token pasted in Settings — when, and who it last tested as. Never the
/// token.
class GithubSavedToken {
  const GithubSavedToken({
    required this.host,
    required this.savedAt,
    this.login,
    this.checkedAt,
  });

  final String host;
  final DateTime savedAt;

  /// Who `GET /user` said the token is, at [checkedAt].
  final String? login;
  final DateTime? checkedAt;

  Map<String, Object?> toJson() => {
    'host': host,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'login': ?login,
    'checkedAt': ?checkedAt?.toUtc().toIso8601String(),
  };

  factory GithubSavedToken.fromJson(Map<String, Object?> json) =>
      GithubSavedToken(
        host: json['host']! as String,
        savedAt:
            _time(json['savedAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        login: _text(json['login']),
        checkedAt: _time(json['checkedAt']),
      );
}

/// Everything Settings → Source control → GitHub shows.
class GithubAccessStatus {
  const GithubAccessStatus({
    this.hosts = const [],
    this.savedTokens = const [],
    this.ghProblem,
  });

  final List<GithubHostAccess> hosts;
  final List<GithubSavedToken> savedTokens;

  /// Why gh's accounts could not be listed: not installed, older than 2.81.
  final String? ghProblem;

  GithubSavedToken? savedFor(String host) =>
      savedTokens.where((t) => t.host == host).firstOrNull;

  Map<String, Object?> toJson() => {
    'hosts': [for (final host in hosts) host.toJson()],
    'savedTokens': [for (final token in savedTokens) token.toJson()],
    'ghProblem': ?ghProblem,
  };

  factory GithubAccessStatus.fromJson(Map<String, Object?> json) =>
      GithubAccessStatus(
        hosts: [
          for (final item in (json['hosts'] as List?) ?? const [])
            if (item is Map)
              GithubHostAccess.fromJson(item.cast<String, Object?>()),
        ],
        savedTokens: [
          for (final item in (json['savedTokens'] as List?) ?? const [])
            if (item is Map)
              GithubSavedToken.fromJson(item.cast<String, Object?>()),
        ],
        ghProblem: _text(json['ghProblem']),
      );
}

/// What `GET /user` said of a token.
class GithubTokenCheck {
  const GithubTokenCheck({
    required this.host,
    required this.ok,
    this.login,
    this.message,
  });

  final String host;
  final bool ok;
  final String? login;

  /// Why it failed, in GitHub's or Karmashala's words.
  final String? message;

  Map<String, Object?> toJson() => {
    'host': host,
    'ok': ok,
    'login': ?login,
    'message': ?message,
  };

  factory GithubTokenCheck.fromJson(Map<String, Object?> json) =>
      GithubTokenCheck(
        host: json['host']! as String,
        ok: json['ok'] == true,
        login: _text(json['login']),
        message: _text(json['message']),
      );
}

/// An agent asking the owner for a secret: shown as a private card in its
/// session's thread until answered.
class SecretRequest {
  const SecretRequest({
    required this.id,
    required this.sessionId,
    required this.label,
    required this.reason,
    required this.requestedAt,
  });

  final String id;
  final String sessionId;

  /// What the secret is, in the agent's words: "Webhook signing secret".
  final String label;

  /// Why the agent needs it.
  final String reason;
  final DateTime requestedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'label': label,
    'reason': reason,
    'requestedAt': requestedAt.toUtc().toIso8601String(),
  };

  factory SecretRequest.fromJson(Map<String, Object?> json) => SecretRequest(
    id: json['id']! as String,
    sessionId: json['sessionId']! as String,
    label: json['label'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
    requestedAt:
        _time(json['requestedAt']) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}
