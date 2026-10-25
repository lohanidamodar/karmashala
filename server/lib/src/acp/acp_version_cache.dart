import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';

/// What an installation's executable looks like now — size and modification
/// time — or null when it cannot be read, which is never cached.
typedef AcpInstallFingerprint =
    Future<String?> Function(
      AgentInstallation installation,
      ExecutionEnvironment environment,
      CommandRunner runner,
    );

/// The version each ACP installation reported, kept beside its executable's
/// fingerprint, so an unchanged agent is not started again to be asked.
class AcpVersionCache {
  /// [file] keeps it across restarts; without one it lives in memory.
  AcpVersionCache({
    this.file,
    this.runnerEntryLife = kVersionReadingFreshFor,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String? file;

  /// How long a reading through a runner such as npx stands: its executable
  /// is the runner's, and the package it fetches changes without it.
  final Duration runnerEntryLife;
  final DateTime Function() _now;

  Map<String, _Entry>? _entries;

  /// The key for [installation]: its environment, executable and leading
  /// arguments, which two descriptors of one binary share.
  static String keyOf(AgentInstallation installation) => [
    installation.executable.environmentId,
    installation.executable.path,
    ...installation.leadingArguments,
  ].join('\n');

  String? versionFor(AgentInstallation installation, String fingerprint) {
    final entry = _load()[keyOf(installation)];
    if (entry == null || entry.fingerprint != fingerprint) return null;
    if (installation.leadingArguments.isNotEmpty &&
        _now().difference(entry.readAt) > runnerEntryLife) {
      return null;
    }
    return entry.version;
  }

  void remember(
    AgentInstallation installation,
    String fingerprint,
    String version,
  ) {
    _load()[keyOf(installation)] = _Entry(fingerprint, version, _now());
    _save();
  }

  Map<String, _Entry> _load() {
    if (_entries case final loaded?) return loaded;
    final entries = <String, _Entry>{};
    final path = file;
    if (path != null) {
      try {
        final decoded = jsonDecode(File(path).readAsStringSync());
        if (decoded is Map) {
          for (final MapEntry(:key, :value) in decoded.entries) {
            if (_Entry.fromJson(value) case final entry?) {
              entries['$key'] = entry;
            }
          }
        }
      } on Object {
        // Missing or unreadable: every agent is asked once more.
      }
    }
    return _entries = entries;
  }

  void _save() {
    final path = file;
    if (path == null) return;
    try {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            for (final MapEntry(:key, :value) in _load().entries)
              key: value.toJson(),
          }),
        );
    } on Object {
      // Kept in memory; the next start asks again.
    }
  }
}

final class _Entry {
  const _Entry(this.fingerprint, this.version, this.readAt);

  final String fingerprint;
  final String version;
  final DateTime readAt;

  static _Entry? fromJson(Object? json) {
    if (json is! Map) return null;
    final fingerprint = json['fingerprint'];
    final version = json['version'];
    final readAt = DateTime.tryParse('${json['readAt']}');
    if (fingerprint is! String || version is! String || readAt == null) {
      return null;
    }
    return _Entry(fingerprint, version, readAt);
  }

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'version': version,
    'readAt': readAt.toUtc().toIso8601String(),
  };
}

/// Size and modification time of [installation]'s executable: read off this
/// machine's disk, or with `stat` inside a WSL distribution.
Future<String?> acpInstallFingerprint(
  AgentInstallation installation,
  ExecutionEnvironment environment,
  CommandRunner runner,
) async {
  final path = installation.executable.path;
  switch (environment.kind) {
    case EnvironmentKind.windowsNative || EnvironmentKind.localPosix:
      try {
        final stat = await File(path).stat();
        if (stat.type == FileSystemEntityType.notFound) return null;
        return '${stat.size}:${stat.modified.millisecondsSinceEpoch ~/ 1000}';
      } on Object {
        return null;
      }
    case EnvironmentKind.wsl:
      try {
        final result = await runner.run(
          CommandRequest(
            executable: 'stat',
            arguments: ['-L', '-c', '%s:%Y', path],
            timeout: const Duration(seconds: 20),
          ),
        );
        final said = result.stdout.trim();
        return result.ok && said.isNotEmpty ? said : null;
      } on Object {
        return null;
      }
    case EnvironmentKind.ssh:
      return null;
  }
}
