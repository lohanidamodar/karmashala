import 'dart:typed_data';

import 'package:meta/meta.dart';

/// What `uname -sm` and the libc probe said about a machine.
@immutable
class HostPlatform {
  const HostPlatform({
    required this.operatingSystem,
    required this.architecture,
    required this.libc,
    required this.observedAt,
  });

  /// Lower-cased `uname -s`: linux, darwin, freebsd…
  final String operatingSystem;

  /// Normalised `uname -m`: x64, arm64, or whatever it actually said.
  final String architecture;

  /// glibc, musl, or unknown — a reading, never a guess. musl machines are out
  /// of scope: the binaries are glibc-linked ELF, so there is nothing to send.
  final HostLibc libc;
  final DateTime observedAt;

  bool get isLinux => operatingSystem == 'linux';

  /// The filename fragment the deployer looks for and uploads under.
  String get targetKey => '$operatingSystem-$architecture';

  static String normaliseArchitecture(String machine) => switch (machine.toLowerCase()) {
    'x86_64' || 'amd64' || 'x64' => 'x64',
    'aarch64' || 'arm64' => 'arm64',
    final other => other,
  };

  @override
  String toString() => '$operatingSystem/$architecture (${libc.name})';
}

enum HostLibc { glibc, musl, unknown }

/// Why a machine is not going to run the host, in the words the pane shows.
enum HostDeploymentStatus {
  /// Deployed (or already current) and answering `hello`.
  ready,

  /// The machine is fine but there is no binary for it in this build.
  noBinary,

  /// Not a machine this host runs on at all — musl, macOS, a BSD.
  unsupportedPlatform,

  /// Upload, chmod, or the home directory refused us.
  cannotInstall,

  /// Installed, but `serve` would not start or would not answer.
  cannotStart,

  /// It answered, and it speaks a protocol this app does not.
  protocolMismatch,

  /// We could not even ask. The reading is missing, which is not the same as
  /// a negative one.
  unknown,
}

/// One reading about one machine's host, with the time it was taken. Nothing
/// here is a cached fact: a host that answered an hour ago may be gone.
@immutable
class HostDeployment {
  const HostDeployment({
    required this.status,
    required this.observedAt,
    required this.reason,
    this.platform,
    this.remotePath,
    this.hostVersion,
    this.protocolVersion,
    this.restartedByUs = false,
  });

  factory HostDeployment.unknown(String reason, DateTime observedAt) =>
      HostDeployment(status: HostDeploymentStatus.unknown, observedAt: observedAt, reason: reason);

  final HostDeploymentStatus status;
  final DateTime observedAt;

  /// One sentence, written for a pane notice rather than a log.
  final String reason;

  final HostPlatform? platform;
  final String? remotePath;
  final String? hostVersion;
  final int? protocolVersion;

  /// Whether this deploy had to start `serve` itself. True means it holds none
  /// of the sessions it held before — what a pane needs to say they are gone.
  final bool restartedByUs;

  bool get isReady => status == HostDeploymentStatus.ready;

  /// Whether the pane should use the tmux wrapper instead. Everything that is
  /// not `ready` falls back — and says so.
  bool get fallsBackToTmux => !isReady;
}

/// A compiled host binary and the version it reports.
@immutable
class HostBinary {
  const HostBinary({
    required this.bytes,
    required this.version,
    required this.source,
    this.candidates = 1,
  });

  final Uint8List bytes;

  /// Taken from the filename, which the build script stamps. It is compared
  /// against what the *remote* binary answers, never trusted on its own.
  final String version;

  /// Where it came from, so a failure names a path a person can look at.
  final String source;

  /// How many files matched this target where [source] was found. More than one
  /// means older builds sit beside it, so a notice can say which was taken.
  final int candidates;
}
