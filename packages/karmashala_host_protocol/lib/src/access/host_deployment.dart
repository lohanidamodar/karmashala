import 'package:meta/meta.dart';

import 'privileged_command.dart';

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

  /// `uname -s` says Darwin; the host is built and named for `macos`.
  bool get isDarwin => operatingSystem == 'darwin';

  /// The filename fragment the deployer looks for and uploads under. `macos`,
  /// not `darwin`, on a Mac: the name `dart build` and the bundles go by.
  String get targetKey =>
      '${isDarwin ? 'macos' : operatingSystem}-$architecture';

  static String normaliseArchitecture(String machine) =>
      switch (machine.toLowerCase()) {
        'x86_64' || 'amd64' || 'x64' => 'x64',
        'aarch64' || 'arm64' => 'arm64',
        final other => other,
      };

  Map<String, Object?> toJson() => {
    'operatingSystem': operatingSystem,
    'architecture': architecture,
    'libc': libc.name,
    'observedAt': observedAt.toUtc().toIso8601String(),
  };

  static HostPlatform fromJson(Map<String, Object?> json) => HostPlatform(
    operatingSystem: json['operatingSystem']! as String,
    architecture: json['architecture']! as String,
    libc: HostLibc.values.byName(json['libc']! as String),
    observedAt: DateTime.parse(json['observedAt']! as String),
  );

  @override
  String toString() => '$operatingSystem/$architecture (${libc.name})';
}

enum HostLibc { glibc, musl, unknown }

/// Why a machine is not going to run the host, in the words a person reads.
enum HostDeploymentStatus {
  /// Deployed (or already current) and answering `hello`.
  ready,

  /// The machine is fine but the server has no host bundle for it.
  noBinary,

  /// Not a machine this host runs on at all — musl, a BSD. Refused: there is
  /// no other way to reach one (no tmux fallback, owner 2026-09-27).
  unsupportedPlatform,

  /// Upload, chmod, or the home directory refused us.
  cannotInstall,

  /// Installed, but `serve` would not start or would not answer.
  cannotStart,

  /// It answered, and it speaks a protocol this server does not.
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
    this.availableTargets = const [],
    this.privileged,
    this.hostOutdated = false,
    this.liveSessionIds,
    this.hostUnresponsive = false,
    this.hostPid,
    this.noNewerHost = false,
    this.offeredVersion,
    this.bundleFolder,
  });

  factory HostDeployment.unknown(String reason, DateTime observedAt) =>
      HostDeployment(
        status: HostDeploymentStatus.unknown,
        observedAt: observedAt,
        reason: reason,
      );

  final HostDeploymentStatus status;
  final DateTime observedAt;

  /// One sentence, written for a person rather than a log.
  final String reason;

  final HostPlatform? platform;
  final String? remotePath;
  final String? hostVersion;
  final int? protocolVersion;

  /// Whether this deploy had to start `serve` itself. True means it holds none
  /// of the sessions it held before — what a pane needs to say they are gone.
  final bool restartedByUs;

  /// For [HostDeploymentStatus.noBinary]: the targets the server does carry,
  /// so the remedy can say what it has and what the machine wanted.
  final List<String> availableTargets;

  /// A step only root can take before this deploy can succeed — a missing
  /// `tar`, say — for a terminal on the machine. Never run from here.
  final PrivilegedCommand? privileged;

  /// The running host is not the build this one ships and was left running
  /// because it holds [liveSessionIds]. It still serves those.
  final bool hostOutdated;

  /// The sessions still running in an outdated host, by id. Null when it
  /// would not say, which must be treated as holding some.
  final List<String>? liveSessionIds;

  /// Something holds the host's socket and took the connection, but no welcome
  /// came inside the bound — busy, or stuck. A second host must not be started
  /// over it; only a restart the person asks for replaces it.
  final bool hostUnresponsive;

  /// The pid the answering host gave in its welcome; null when none answered.
  /// A different pid for the same socket is a different host: whatever the
  /// last one ran ended with it.
  final int? hostPid;

  /// For [HostDeploymentStatus.protocolMismatch]: the stale host is the one
  /// this server carries, so there is nothing newer to update it to.
  final bool noNewerHost;

  /// The version of the bundle the server carries for the machine.
  final String? offeredVersion;

  /// Where the server's operator can put a host bundle.
  final String? bundleFolder;

  bool get isReady => status == HostDeploymentStatus.ready;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'observedAt': observedAt.toUtc().toIso8601String(),
    'reason': reason,
    'platform': ?platform?.toJson(),
    'remotePath': ?remotePath,
    'hostVersion': ?hostVersion,
    'protocolVersion': ?protocolVersion,
    if (restartedByUs) 'restartedByUs': true,
    if (availableTargets.isNotEmpty) 'availableTargets': availableTargets,
    'privileged': ?privileged?.toJson(),
    if (hostOutdated) 'hostOutdated': true,
    'liveSessionIds': ?liveSessionIds,
    if (hostUnresponsive) 'hostUnresponsive': true,
    'hostPid': ?hostPid,
    if (noNewerHost) 'noNewerHost': true,
    'offeredVersion': ?offeredVersion,
    'bundleFolder': ?bundleFolder,
  };

  static HostDeployment fromJson(Map<String, Object?> json) => HostDeployment(
    status: HostDeploymentStatus.values.byName(json['status']! as String),
    observedAt: DateTime.parse(json['observedAt']! as String),
    reason: json['reason']! as String,
    platform: switch (json['platform']) {
      final Map<String, Object?> platform => HostPlatform.fromJson(platform),
      _ => null,
    },
    remotePath: json['remotePath'] as String?,
    hostVersion: json['hostVersion'] as String?,
    protocolVersion: json['protocolVersion'] as int?,
    restartedByUs: json['restartedByUs'] == true,
    availableTargets: [
      for (final target in json['availableTargets'] as List? ?? const [])
        target as String,
    ],
    privileged: switch (json['privileged']) {
      final Map<String, Object?> step => PrivilegedCommand.fromJson(step),
      _ => null,
    },
    hostOutdated: json['hostOutdated'] == true,
    liveSessionIds: switch (json['liveSessionIds']) {
      final List<Object?> ids => [for (final id in ids) id! as String],
      _ => null,
    },
    hostUnresponsive: json['hostUnresponsive'] == true,
    hostPid: json['hostPid'] as int?,
    noNewerHost: json['noNewerHost'] == true,
    offeredVersion: json['offeredVersion'] as String?,
    bundleFolder: json['bundleFolder'] as String?,
  );
}

/// Compares two filename versions segment by segment, as numbers: a string
/// sort puts `1.9.0` above `1.20.1`, which is the whole bug. A null sorts
/// below any version.
int compareHostVersions(String? a, String? b) {
  if (a == null || b == null) {
    return (a == null ? 0 : 1) - (b == null ? 0 : 1);
  }
  final left = a.split('.');
  final right = b.split('.');
  for (var i = 0; i < left.length || i < right.length; i++) {
    final l = i < left.length ? left[i] : '0';
    final r = i < right.length ? right[i] : '0';
    final ln = int.tryParse(l);
    final rn = int.tryParse(r);
    final order = ln != null && rn != null ? ln.compareTo(rn) : l.compareTo(r);
    if (order != 0) return order;
  }
  return 0;
}
