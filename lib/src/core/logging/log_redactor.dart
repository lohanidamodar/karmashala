/// One thing that must not be written down, and what to write instead.
class RedactionRule {
  RedactionRule({
    required this.name,
    required this.pattern,
    required this.replacement,
  });

  /// What this rule protects, for the settings screen and for test failures.
  final String name;

  final RegExp pattern;

  /// May reference groups (`$1`) to keep the readable part of a match — the
  /// point of redaction is a log you can still read.
  final String replacement;

  String apply(String input) => input.replaceAllMapped(pattern, (match) {
    var out = replacement;
    for (var group = match.groupCount; group >= 1; group--) {
      out = out.replaceAll('\$$group', match.group(group) ?? '');
    }
    return out;
  });
}

/// Strips secrets and the user's name out of a log line.
///
/// **Not a UI concern.** `claude-auth`, `claude-accounts`, `ssh.hostkey` and
/// `remote` handle exactly the material that must not leave the machine, and
/// this surface adds a *copy* button and a *file on disk*. So redaction runs
/// once, on the way into the ring buffer, and every consumer — the panel, the
/// clipboard, the report, the log file — reads the sanitised text. There is no
/// path to any of them that skips it.
///
/// **False positives are the cheap failure.** A rule that redacts a harmless
/// word costs one confusing line; a rule that misses a token costs a leaked
/// credential in a pasted issue. Rules are written accordingly.
class LogRedactor {
  LogRedactor({List<RedactionRule>? rules}) : rules = rules ?? defaultRules;

  final List<RedactionRule> rules;

  /// [input] with every rule applied, in order. Idempotent: redacting an
  /// already-redacted line is a no-op, so a re-capture cannot mangle text.
  String apply(String input) {
    if (input.isEmpty) return input;
    var out = input;
    for (final rule in rules) {
      out = rule.apply(out);
    }
    return out;
  }

  /// Null-tolerant [apply], for the optional halves of a record.
  String? applyOrNull(String? input) => input == null ? null : apply(input);

  /// The shipped rules. Adding one is meant to be a two-line change.
  static final List<RedactionRule> defaultRules = [
    // A pasted private key is the worst thing that can end up in a log file.
    RedactionRule(
      name: 'private key',
      pattern: RegExp(
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
      ),
      replacement: '[redacted:private-key]',
    ),
    // `ssh.hostkey` logs these verbatim when a host key changes.
    RedactionRule(
      name: 'ssh host key',
      pattern: RegExp(
        r'\b(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp\d+)\s+[A-Za-z0-9+/]{20,}={0,3}',
      ),
      replacement: r'$1 [redacted:key]',
    ),
    RedactionRule(
      name: 'key fingerprint',
      pattern: RegExp(r'\bSHA256:[A-Za-z0-9+/]{20,}={0,3}'),
      replacement: 'SHA256:[redacted:key]',
    ),
    RedactionRule(
      name: 'vendor token',
      pattern: RegExp(
        r'\b(sk-ant-[A-Za-z0-9_-]{8,}'
        r'|sk-[A-Za-z0-9]{16,}'
        r'|gh[pousr]_[A-Za-z0-9]{16,}'
        r'|github_pat_[A-Za-z0-9_]{20,}'
        r'|xox[baprs]-[A-Za-z0-9-]{10,}'
        r'|AIza[A-Za-z0-9_-]{20,})',
      ),
      replacement: '[redacted:token]',
    ),
    RedactionRule(
      name: 'json web token',
      pattern: RegExp(
        r'\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}',
      ),
      replacement: '[redacted:token]',
    ),
    RedactionRule(
      name: 'bearer credential',
      pattern: RegExp(r'\b([Bb]earer|[Bb]asic)\s+[A-Za-z0-9._~+/=-]{8,}'),
      replacement: r'$1 [redacted:token]',
    ),
    // The catch-all: anything spelled like a secret being assigned. Deliberately
    // a short keyword list — a bare `auth:` would eat ordinary message text.
    RedactionRule(
      name: 'named secret',
      pattern: RegExp(
        r'\b(access[_-]?token|refresh[_-]?token|id[_-]?token|token'
        r'|secret|password|passphrase|api[_-]?key|apikey'
        r'|access[_-]?key|session[_-]?key|private[_-]?key'
        r'|pairing[_-]?code|device[_-]?key|client[_-]?secret)'
        r'(\s*[=:]\s*)'
        r'''("?)([^\s"',;}]{6,})\3''',
        caseSensitive: false,
      ),
      replacement: r'$1$2[redacted]',
    ),
    // The user's name, which is in every absolute path the app logs.
    RedactionRule(
      name: 'wsl home path',
      pattern: RegExp(
        r'(\\\\wsl(?:\.localhost|\$)\\[^\\]+\\home\\)([^\\\s"]+)',
        caseSensitive: false,
      ),
      replacement: r'$1<user>',
    ),
    RedactionRule(
      name: 'windows home path',
      pattern: RegExp(
        r'([A-Za-z]:\\Users\\)([^\\/:*?"<>|\s]+)',
        caseSensitive: false,
      ),
      replacement: r'$1<user>',
    ),
    RedactionRule(
      name: 'posix home path',
      pattern: RegExp(r'''(/(?:home|Users)/)([^/\s:"',]+)'''),
      replacement: r'$1<user>',
    ),
  ];
}
