/// One user-declared environment variable, and the vault that holds them.
/// Named `env_secrets` so it is never misread as the `environments` feature.
library;

/// How widely a variable applies. Only [all] is offered today; the others are
/// in the model so narrowing later is a picker, not a data move.
enum EnvVarScope {
  /// Every terminal Karmashala launches.
  all,

  /// One execution environment (a WSL distribution, the Windows host).
  environment,

  /// One project.
  project;

  static EnvVarScope byName(Object? value) {
    for (final scope in EnvVarScope.values) {
      if (scope.name == value) return scope;
    }
    return EnvVarScope.all;
  }
}

/// Longest value accepted, in UTF-16 code units. Here to keep a paste accident
/// from producing a launch that fails unreadably, not as a security boundary.
const int kMaxEnvValueLength = 8192;

/// Names Karmashala refuses, because setting them breaks the launch itself:
/// `WSLENV`, the `KARMASHALA_*` plumbing, and what the shells need to start.
const Set<String> kReservedEnvNames = {
  'WSLENV',
  'PATH',
  'SYSTEMROOT',
  'WINDIR',
  'COMSPEC',
  'USERPROFILE',
  'HOME',
  'TEMP',
  'TMP',
};

/// The prefix the app reserves for its own launch variables.
const String kReservedEnvPrefix = 'KARMASHALA_';

final RegExp _namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Why [name] cannot be used, or `null` when it can. A whole sentence, because
/// it is rendered verbatim under the field.
String? envNameRefusal(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'Enter a name.';
  if (!_namePattern.hasMatch(trimmed)) {
    return 'Use letters, digits and underscores, starting with a letter or '
        'underscore.';
  }
  final upper = trimmed.toUpperCase();
  if (upper.startsWith(kReservedEnvPrefix)) {
    return '$kReservedEnvPrefix names belong to Karmashala — they carry the '
        'session id and port base into the agent, and overwriting one breaks '
        'the session.';
  }
  if (kReservedEnvNames.contains(upper)) {
    return '$trimmed is needed to start the shell itself, so Karmashala will '
        'not replace it.';
  }
  return null;
}

/// Why [value] cannot be used, or `null` when it can.
String? envValueRefusal(String value) {
  if (value.codeUnits.contains(0)) {
    return 'A value cannot contain a null character — Windows would cut the '
        'environment off at it.';
  }
  if (value.length > kMaxEnvValueLength) {
    return 'Too long: ${value.length} characters, limit $kMaxEnvValueLength.';
  }
  return null;
}

/// One variable, as stored and as injected. [value] is the plaintext; nothing
/// here has a `toString` that could put it in a log line, deliberately.
class EnvVariable {
  const EnvVariable({
    required this.id,
    required this.name,
    required this.value,
    required this.secret,
    required this.updatedAt,
    this.enabled = true,
    this.scope = EnvVarScope.all,
    this.scopeId,
  });

  final String id;
  final String name;

  /// The plaintext value. **Never rendered for a [secret] variable** — the
  /// settings surface shows "Set" and an updated date, and offers Replace.
  final String value;

  /// Whether the value is hidden in the UI and fed to the log redactor. It does
  /// **not** change how the value is stored or injected.
  final bool secret;

  /// Off means "keep the definition, stop injecting it" — the alternative to
  /// deleting a value you would then have to type again.
  final bool enabled;

  final EnvVarScope scope;

  /// The environment or project id [scope] narrows to; null for
  /// [EnvVarScope.all].
  final String? scopeId;

  final DateTime updatedAt;

  EnvVariable copyWith({
    String? name,
    String? value,
    bool? secret,
    bool? enabled,
    EnvVarScope? scope,
    String? scopeId,
    DateTime? updatedAt,
  }) => EnvVariable(
    id: id,
    name: name ?? this.name,
    value: value ?? this.value,
    secret: secret ?? this.secret,
    enabled: enabled ?? this.enabled,
    scope: scope ?? this.scope,
    scopeId: scopeId ?? this.scopeId,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// The record without its value, for the JSON the vault writes. The value is
  /// added by `EnvVault` after the cipher has had it, so no path can serialise
  /// a plaintext by accident.
  Map<String, dynamic> toJsonWithoutValue() => {
    'id': id,
    'name': name,
    'secret': secret,
    'enabled': enabled,
    'scope': scope.name,
    if (scopeId != null) 'scopeId': scopeId,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// Rebuilds a record from [json] and an already-decrypted [value]. Tolerant on
  /// purpose: one odd row must not leave every terminal without its variables.
  static EnvVariable? fromJson(Map<String, dynamic> json, String value) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || envNameRefusal(name) != null) return null;
    if (envValueRefusal(value) != null) return null;
    return EnvVariable(
      id: id,
      name: name,
      value: value,
      secret: json['secret'] == true,
      enabled: json['enabled'] != false,
      scope: EnvVarScope.byName(json['scope']),
      scopeId: json['scopeId'] is String ? json['scopeId'] as String : null,
      updatedAt:
          DateTime.tryParse('${json['updatedAt']}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// How the values in a vault are protected at rest. A fact about the file on
/// disk, recorded per vault, not a preference the build hoped for.
enum EnvProtection {
  /// File permissions only: an ACL restricted to this account on Windows,
  /// `0600` on POSIX. The values themselves are plaintext in the file.
  filePermissions,

  /// File permissions **and** a cipher whose key lives outside the vault, in a
  /// non-roaming per-user location.
  localKey;

  /// One sentence for the settings page. Neither spelling claims protection
  /// from a process running as this user, because there is none.
  String get summary => switch (this) {
    EnvProtection.filePermissions =>
      'Stored in a file only your account can open. The values are not '
          'encrypted, so a copy of that file taken off this machine is '
          'readable.',
    EnvProtection.localKey =>
      'Encrypted in a file only your account can open, with a key kept '
          'outside it in local (non-roaming) storage. A copy of the vault '
          'taken off this machine is useless without that key.',
  };
}

/// Everything the vault file holds: the master switch and the variables. The
/// switch lives here so the feature has exactly one store.
class EnvVaultData {
  const EnvVaultData({
    this.enabled = true,
    this.variables = const [],
    this.protection = EnvProtection.filePermissions,
    this.canStoreSecrets = true,
    this.problem,
  });

  /// The empty vault: nothing configured, nothing injected, nothing wrong.
  static const EnvVaultData empty = EnvVaultData();

  /// A vault that could not be read or could not be hardened.
  const EnvVaultData.unavailable(
    String this.problem, {
    this.canStoreSecrets = false,
  }) : enabled = true,
       variables = const [],
       protection = EnvProtection.filePermissions;

  /// The master switch. Off stops injection without deleting anything.
  final bool enabled;

  final List<EnvVariable> variables;

  final EnvProtection protection;

  /// Whether a **secret** variable can be saved at all — false when the
  /// directory ACL could not be applied. Plain variables still save.
  final bool canStoreSecrets;

  /// What went wrong, for the banner. Null when nothing did.
  final String? problem;

  EnvVaultData copyWith({
    bool? enabled,
    List<EnvVariable>? variables,
    EnvProtection? protection,
    bool? canStoreSecrets,
    String? problem,
    bool clearProblem = false,
  }) => EnvVaultData(
    enabled: enabled ?? this.enabled,
    variables: variables ?? this.variables,
    protection: protection ?? this.protection,
    canStoreSecrets: canStoreSecrets ?? this.canStoreSecrets,
    problem: clearProblem ? null : (problem ?? this.problem),
  );
}
