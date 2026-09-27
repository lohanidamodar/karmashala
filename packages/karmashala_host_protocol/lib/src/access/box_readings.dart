import 'package:meta/meta.dart';

import '../protocol/session_lifecycle.dart';
import '../protocol/session_summary.dart';
import 'host_deployment.dart';
import 'privileged_command.dart';

// What the server reads off a box it reaches over SSH (slice 5d), as values a
// client is told: the host installed there, its relay, the port a phone
// dials and a pairing window. Each carries the time it was taken; none is
// re-taken on its own (PROJECT.md §19).

DateTime _time(Object? value) => DateTime.parse(value! as String);
String _stamp(DateTime value) => value.toUtc().toIso8601String();
PrivilegedCommand? _step(Object? json) => switch (json) {
  final Map<String, Object?> step => PrivilegedCommand.fromJson(step),
  _ => null,
};

/// Where one machine's session host stands, as a person would say it.
enum HostInstallState {
  /// Nothing of ours is on the machine, and the server has a bundle for it.
  notInstalled,

  /// The server's host — or, when it carries none, some host — is
  /// installed. Running or stopped is a second fact.
  installed,

  /// A host from another version is what is installed or running.
  outdated,

  /// Nothing is installed and nothing can be: no bundle for the machine, or a
  /// machine the host does not run on.
  cannotInstall,

  /// The machine could not be asked. A missing reading, not a negative one.
  unknown,
}

/// One reading of one machine's session host, with the time it was taken.
@immutable
class HostInstallReading {
  const HostInstallReading({
    required this.state,
    required this.observedAt,
    required this.reason,
    this.platform,
    this.installedVersion,
    this.offeredVersion,
    this.running = false,
    this.sessionsHeld,
    this.remotePath,
    this.deployment,
    this.availableTargets = const [],
  });

  final HostInstallState state;
  final DateTime observedAt;

  /// One sentence: what was found, or what the last action did.
  final String reason;

  final HostPlatform? platform;

  /// The version in effect on the machine: the running one, else the
  /// server's when it is there, else the newest installed. From the filename.
  final String? installedVersion;

  /// The version the server would install, or null when it has no bundle for
  /// the machine.
  final String? offeredVersion;

  final bool running;

  /// How many sessions the running host holds; null when it is not running or
  /// would not say. Stop and Remove end them.
  final int? sessionsHeld;

  /// The executable in effect, which Start runs.
  final String? remotePath;

  /// The deploy this reading followed, when one ran and did not end ready —
  /// what `explainHostDeployment` turns into a sentence and a remedy.
  final HostDeployment? deployment;

  final List<String> availableTargets;

  bool get canInstall => offeredVersion != null;

  /// Whether what is on the machine is a *later* build than the server
  /// carries. Installing the server's is then not an update, and is not
  /// called one.
  bool get hostIsNewer =>
      state == HostInstallState.outdated &&
      installedVersion != null &&
      offeredVersion != null &&
      compareHostVersions(installedVersion, offeredVersion) > 0;

  /// `installed 1.25.0 (running)` — what follows "Karmashala host:".
  String get label => switch (state) {
    HostInstallState.notInstalled => 'not installed',
    HostInstallState.installed =>
      'installed ${installedVersion ?? 'unversioned'} '
          '(${running ? 'running' : 'stopped'})',
    HostInstallState.outdated when hostIsNewer =>
      'newer than the server\'s ($installedVersion; the server carries '
          '$offeredVersion), ${running ? 'running' : 'stopped'}',
    HostInstallState.outdated =>
      'older than the server\'s (${installedVersion ?? 'unversioned'} → '
          '${offeredVersion ?? 'unknown'}), ${running ? 'running' : 'stopped'}',
    HostInstallState.cannotInstall => 'can\'t install: $reason',
    HostInstallState.unknown => 'unknown: $reason',
  };

  /// This reading with what the last action said.
  HostInstallReading after(String said, {HostDeployment? deployment}) =>
      HostInstallReading(
        state: state,
        observedAt: observedAt,
        reason: said,
        platform: platform,
        installedVersion: installedVersion,
        offeredVersion: offeredVersion,
        running: running,
        sessionsHeld: sessionsHeld,
        remotePath: remotePath,
        deployment: deployment,
        availableTargets: availableTargets,
      );

  Map<String, Object?> toJson() => {
    'state': state.name,
    'observedAt': _stamp(observedAt),
    'reason': reason,
    'platform': ?platform?.toJson(),
    'installedVersion': ?installedVersion,
    'offeredVersion': ?offeredVersion,
    if (running) 'running': true,
    'sessionsHeld': ?sessionsHeld,
    'remotePath': ?remotePath,
    'deployment': ?deployment?.toJson(),
    if (availableTargets.isNotEmpty) 'availableTargets': availableTargets,
  };

  static HostInstallReading fromJson(Map<String, Object?> json) =>
      HostInstallReading(
        state: HostInstallState.values.byName(json['state']! as String),
        observedAt: _time(json['observedAt']),
        reason: json['reason']! as String,
        platform: switch (json['platform']) {
          final Map<String, Object?> platform => HostPlatform.fromJson(
            platform,
          ),
          _ => null,
        },
        installedVersion: json['installedVersion'] as String?,
        offeredVersion: json['offeredVersion'] as String?,
        running: json['running'] == true,
        sessionsHeld: json['sessionsHeld'] as int?,
        remotePath: json['remotePath'] as String?,
        deployment: switch (json['deployment']) {
          final Map<String, Object?> deployment => HostDeployment.fromJson(
            deployment,
          ),
          _ => null,
        },
        availableTargets: [
          for (final target in json['availableTargets'] as List? ?? const [])
            target as String,
        ],
      );
}

/// How the relay on one box ended up, separated by who can fix it.
enum SshRelayStatus {
  /// Running from the server's bundle, and its health check answered from
  /// the server's computer.
  running,

  /// Nothing is running. Not a fault: never started, stopped, or the box
  /// restarted — like `serve`, the relay does not come back by itself.
  stopped,

  /// Running, from a bundle other than the one the server deployed.
  /// Starting it replaces it, which is what "Update" means.
  outdated,

  /// Running on the box and not answering from the server. A firewall,
  /// usually one in a provider's console; the reading carries its words.
  unreachable,

  /// It would not start: an old bundle with no `relay` command, a busy port,
  /// a token file that could not be made private.
  cannotStart,

  /// The machine could not be asked. A missing reading, not a negative one.
  unknown,
}

/// One reading about one box's relay, with the time it was taken.
class SshRelayReading {
  const SshRelayReading({
    required this.status,
    required this.observedAt,
    required this.reason,
    required this.port,
    this.command,
    this.privileged,
    this.outsideTheMachine = false,
    this.url,
    this.runningPath,
  });

  final SshRelayStatus status;
  final DateTime observedAt;

  /// One sentence, with its remedy when it has one. Never holds the token.
  final String reason;

  /// What to run by hand, when that is the remedy.
  final String? command;

  /// [command] as a step for a terminal on the box, when `sudo` there wants a
  /// password. Built from the port alone — never the token.
  final PrivilegedCommand? privileged;

  /// Whether what shuts the port is a firewall no command on the box can see.
  final bool outsideTheMachine;

  /// `ws://<address>:<port>/k/<token>` — what remote access serves through
  /// and a pairing carries. **Holds the access token: never log it, and
  /// [toString] leaves it out.**
  final Uri? url;

  final int port;

  /// The executable the running relay was started from.
  final String? runningPath;

  bool get isServing => status == SshRelayStatus.running;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'observedAt': _stamp(observedAt),
    'reason': reason,
    'port': port,
    'command': ?command,
    'privileged': ?privileged?.toJson(),
    if (outsideTheMachine) 'outsideTheMachine': true,
    'url': ?url?.toString(),
    'runningPath': ?runningPath,
  };

  static SshRelayReading fromJson(Map<String, Object?> json) =>
      SshRelayReading(
        status: SshRelayStatus.values.byName(json['status']! as String),
        observedAt: _time(json['observedAt']),
        reason: json['reason']! as String,
        port: json['port']! as int,
        command: json['command'] as String?,
        privileged: _step(json['privileged']),
        outsideTheMachine: json['outsideTheMachine'] == true,
        url: switch (json['url']) {
          final String url => Uri.tryParse(url),
          _ => null,
        },
        runningPath: json['runningPath'] as String?,
      );

  @override
  String toString() =>
      'SshRelayReading(${status.name}, port $port${url == null ? '' : ', url held'})';
}

/// Where a phone reaches one box, and how sure the server is that it can.
///
/// **Nothing here discovers an address.** The person typed it to reach the
/// box over SSH; a host asked for its own public address would be guessing
/// past NAT, several interfaces and a provider's floating IP.
class CompanionEndpoint {
  const CompanionEndpoint({
    required this.address,
    required this.port,
    required this.hostName,
    required this.reachable,
    required this.reason,
    this.command,
    this.privileged,
    this.outsideTheMachine = false,
  });

  /// The same address the SSH connection used — `SshHost.host`, verbatim.
  final String address;

  /// The companion port, which is **not** the SSH port.
  final int port;

  /// What the box calls itself, for a phone choosing between several.
  final String hostName;

  /// Whether a dial from the server got through. False is still an endpoint
  /// worth showing: the phone may sit somewhere the server does not.
  final bool reachable;

  /// One sentence about the last reading, with its remedy when it has one.
  final String reason;

  /// What to run on the machine by hand, when that is the remedy.
  final String? command;

  /// [command] as a step for a terminal there, when `sudo` wants a password.
  final PrivilegedCommand? privileged;

  /// Whether what shuts the port is a firewall no command on the box can see.
  final bool outsideTheMachine;

  /// What a person types into the phone, and what a QR would encode.
  String get authority => '$address:$port';

  Map<String, Object?> toJson() => {
    'address': address,
    'port': port,
    'hostName': hostName,
    'reachable': reachable,
    'reason': reason,
    'command': ?command,
    'privileged': ?privileged?.toJson(),
    if (outsideTheMachine) 'outsideTheMachine': true,
  };

  static CompanionEndpoint fromJson(Map<String, Object?> json) =>
      CompanionEndpoint(
        address: json['address']! as String,
        port: json['port']! as int,
        hostName: json['hostName']! as String,
        reachable: json['reachable'] == true,
        reason: json['reason']! as String,
        command: json['command'] as String?,
        privileged: _step(json['privileged']),
        outsideTheMachine: json['outsideTheMachine'] == true,
      );

  @override
  String toString() =>
      'CompanionEndpoint($authority, ${reachable ? 'reachable' : 'unproven'})';
}

/// What asking a deployed host to pair came back with.
enum PairingRequestStatus {
  /// A window is open. [PairingWindow.code] is what to type into the phone.
  open('PAIRING OPEN'),

  /// The host answered, and it is older than pairing.
  hostTooOld('PAIRING UNSUPPORTED'),

  /// The host is serving sessions and cannot pair: no store, or its companion
  /// port was taken. It says which, in its own words.
  hostCannotPair('PAIRING REFUSED'),

  /// Nothing answered in time. Not a refusal — a reading nobody could take.
  noAnswer('PAIRING UNKNOWN');

  const PairingRequestStatus(this.token);

  final String token;
}

/// One open pairing window on one machine.
class PairingWindow {
  const PairingWindow({
    required this.status,
    required this.observedAt,
    required this.reason,
    this.code,
    this.expiresAt,
  });

  final PairingRequestStatus status;
  final DateTime observedAt;

  /// One sentence for whoever is holding the phone.
  final String reason;

  /// Grouped for reading: `K7QM-3X2W-…`. Null unless [status] is open.
  final String? code;

  final DateTime? expiresAt;

  bool get isOpen => status == PairingRequestStatus.open;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'observedAt': _stamp(observedAt),
    'reason': reason,
    'code': ?code,
    'expiresAt': ?expiresAt == null ? null : _stamp(expiresAt!),
  };

  static PairingWindow fromJson(Map<String, Object?> json) => PairingWindow(
    status: PairingRequestStatus.values.byName(json['status']! as String),
    observedAt: _time(json['observedAt']),
    reason: json['reason']! as String,
    code: json['code'] as String?,
    expiresAt: json['expiresAt'] == null ? null : _time(json['expiresAt']),
  );
}

/// A box host's session, as a client is told it (`ssh.hostSessions`).
Map<String, Object?> sessionSummaryToJson(SessionSummary summary) => {
  'id': summary.id,
  'argv': summary.argv,
  'workingDirectory': ?summary.workingDirectory,
  'pid': summary.pid,
  'columns': summary.columns,
  'rows': summary.rows,
  'startedAt': _stamp(summary.startedAt),
  'observedAt': _stamp(summary.observedAt),
  'totalBytes': summary.totalBytes,
  'firstAvailableOffset': summary.firstAvailableOffset,
  'lifecycle': switch (summary.lifecycle) {
    SessionRunning() => {'state': 'running'},
    SessionExited(:final code, :final at) => {
      'state': 'exited',
      'code': code,
      'at': _stamp(at),
    },
    SessionEndedWithoutCode(:final at, :final reason) => {
      'state': 'ended',
      'reason': reason,
      'at': _stamp(at),
    },
  },
  'writeHolder': ?summary.writeHolder,
};

SessionSummary sessionSummaryFromJson(Map<String, Object?> json) {
  final lifecycle = json['lifecycle']! as Map<String, Object?>;
  return SessionSummary(
    id: json['id']! as String,
    argv: [for (final part in json['argv']! as List) part as String],
    workingDirectory: json['workingDirectory'] as String?,
    pid: json['pid']! as int,
    columns: json['columns']! as int,
    rows: json['rows']! as int,
    startedAt: _time(json['startedAt']),
    observedAt: _time(json['observedAt']),
    totalBytes: json['totalBytes']! as int,
    firstAvailableOffset: json['firstAvailableOffset']! as int,
    lifecycle: switch (lifecycle['state']) {
      'exited' => SessionExited(
        lifecycle['code']! as int,
        _time(lifecycle['at']),
      ),
      'ended' => SessionEndedWithoutCode(
        _time(lifecycle['at']),
        lifecycle['reason']! as String,
      ),
      _ => const SessionRunning(),
    },
    writeHolder: json['writeHolder'] as String?,
  );
}
