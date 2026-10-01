/// The environment variables a server lays over every terminal it starts
/// (slice 5a): the rules a name and a value must meet, and what a client is
/// told of one — its name and when it was set, **never its value**. The vault
/// is write-only: a client sets or removes a value and cannot read it back.
library;

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

/// The prefix Karmashala reserves for its own launch variables.
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

/// Why a rename of [from] to [to] cannot be done, given the names [taken] (the
/// names the vault holds now), or `null` when it can. [to]'s own rules are
/// [envNameRefusal]'s.
String? envRenameRefusal(String from, String to, Iterable<String> taken) {
  final source = from.trim();
  final target = to.trim();
  if (!taken.contains(source)) return '$source is not set any more.';
  if (target != source && taken.contains(target)) {
    return '$target is already set. Remove it first, or choose another name.';
  }
  return null;
}

/// One variable the server holds, as any client may know it: the name and
/// when its value was last set. There is no value field, by design.
final class EnvVariableName {
  const EnvVariableName({required this.name, required this.updatedAt});

  final String name;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'name': name,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static EnvVariableName fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final at = json['updatedAt'];
    final parsed = at is String ? DateTime.tryParse(at) : null;
    if (name is! String || parsed == null) {
      throw const FormatException('not an environment variable name');
    }
    return EnvVariableName(name: name, updatedAt: parsed.toUtc());
  }

  @override
  bool operator ==(Object other) =>
      other is EnvVariableName &&
      other.name == name &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(name, updatedAt);

  @override
  String toString() => 'EnvVariableName($name)';
}
