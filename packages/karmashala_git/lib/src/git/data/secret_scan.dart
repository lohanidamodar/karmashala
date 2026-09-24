import 'dart:convert';

import 'package:agent_cli/process.dart';

/// One possible secret gitleaks found. The secret itself is never held:
/// the scan runs with `--redact`.
class SecretFinding {
  const SecretFinding({
    required this.file,
    required this.line,
    required this.rule,
    required this.commit,
  });

  final String file;
  final int line;
  final String rule;
  final String commit;

  String get label =>
      '$file:$line (${rule.isEmpty ? 'secret' : rule}'
      '${commit.isEmpty ? '' : ', ${commit.length > 7 ? commit.substring(0, 7) : commit}'})';
}

/// What a scan of the commits a push would send found.
sealed class SecretScan {
  const SecretScan();
}

/// gitleaks is not installed where the repository lives; nothing was scanned.
class SecretScanUnavailable extends SecretScan {
  const SecretScanUnavailable();
}

class SecretScanClean extends SecretScan {
  const SecretScanClean();
}

class SecretScanFound extends SecretScan {
  const SecretScanFound(this.findings);
  final List<SecretFinding> findings;
}

/// gitleaks ran and did not give an answer.
class SecretScanFailed extends SecretScan {
  const SecretScanFailed(this.reason);
  final String reason;
}

/// The argv that scans only what a push would send: commits reachable from
/// `HEAD` that no remote-tracking ref already has, which is right for a
/// tracked branch and an unpublished one alike.
List<String> gitleaksOutgoingArguments(String repoPath) => [
  'git',
  '--no-banner',
  '--no-color',
  '--redact',
  '--log-opts=HEAD --not --remotes',
  '--report-format',
  'json',
  '--report-path',
  '-',
  repoPath,
];

/// Reads a finished gitleaks run. Exit 0 is clean and 1 is findings (its
/// default `--exit-code`); 127 is a POSIX shell that could not find it.
SecretScan secretScanFrom(CommandResult result) {
  if (result.exitCode == 127) return const SecretScanUnavailable();
  if (result.exitCode == 0) return const SecretScanClean();
  if (result.exitCode != 1) {
    final said = result.stderr.trim().split('\n').lastOrNull ?? '';
    return SecretScanFailed(
      'gitleaks exited ${result.exitCode}${said.isEmpty ? '' : ': $said'}',
    );
  }
  try {
    final report = jsonDecode(result.stdout) as List<Object?>;
    return SecretScanFound([
      for (final entry in report.whereType<Map<String, Object?>>())
        SecretFinding(
          file: entry['File'] as String? ?? '',
          line: (entry['StartLine'] as num?)?.toInt() ?? 0,
          rule: entry['RuleID'] as String? ?? '',
          commit: entry['Commit'] as String? ?? '',
        ),
    ]);
  } on FormatException {
    return const SecretScanFailed(
      'gitleaks reported findings in a form this app could not read',
    );
  }
}
