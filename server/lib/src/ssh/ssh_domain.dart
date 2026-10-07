import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart' show Clock, SystemClock;
import 'package:karmashala_files/karmashala_files.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/files.dart' show RemoteFileBrowser;
import 'package:karmashala_ssh_host/host.dart';
import 'package:karmashala_store/database.dart';

import '../data/data_service.dart';
import 'boxes/box_relay.dart';
import 'boxes/remote_sessions.dart';
import 'boxes/server_remote_hosts.dart';
import 'deploy/box_admin.dart';
import 'deploy/host_bundles.dart';
import 'pool/server_ssh.dart';
import 'ssh_requests.dart';

export 'boxes/remote_sessions.dart';

/// **The server's one SSH domain** (slices 3a and 5d), as the rest of the
/// server sees it. Everything that touches SSH lives under `ssh/`:
///
/// - `pool/` — the server's connections over its saved hosts and trusted
///   keys, keys read on this machine only, and the runners (`ServerSsh`);
/// - `prompts/` — what a connection cannot decide alone, put to a person
///   through the server's windows (`SshPrompts`);
/// - `boxes/` — the host on each SSH box: one link per box, the copies of
///   its sessions' screens, the frame relay and session refs
///   (`ServerRemoteHosts`, `BoxScreen`, `ServerBoxRelay`);
/// - `deploy/` — where host bundles come from and the explicit verbs on a
///   box's host, relay and pairing (`serverHostBundles`, `BoxAdmin`);
/// - `ssh_requests.dart` — every `ssh.*` data request.
///
/// Other features never import SSH: they use what this hands them — a
/// runner factory ([runners]), a file space ([fileSpaceFor]), sessions on a
/// box ([remote], `RemoteSessions`) and the relay `HostServer` sends a box's
/// frames through ([relay]). `server/test/ssh/ssh_boundary_test.dart` fails
/// on anything else.
class ServerSshDomain {
  ServerSshDomain({
    required DataService data,
    required AppDatabase database,
    required String dataDirectory,
    HostBinarySource? bundles,
    HostDeployTarget Function(SshHost host)? targetFor,
    PrivateKeyReader? readKey,
    Clock clock = const SystemClock(),
    Duration promptWait = const Duration(minutes: 5),
    bool probe = false,
    void Function(String message)? log,
  }) : _data = data {
    ssh = ServerSsh(
      data: data,
      database: database,
      clock: clock,
      readKey: readKey,
      promptWait: promptWait,
    );
    boxes = ServerRemoteHosts(
      hostOf: ssh.hostOf,
      connectionFor: ssh.pool.forHostId,
      bundles: bundles ?? serverHostBundles(dataDirectory: dataDirectory),
      targetFor: targetFor,
      log: log,
      refusal: probe
          ? 'A probe server does not use the Karmashala host on SSH '
                'machines: the host there is per user, and the owner\'s '
                'sessions are in it.'
          : null,
    );
    admin = BoxAdmin(boxes);
    relay = ServerBoxRelay(boxes);
  }

  final DataService _data;

  /// The connections, runners and connection states.
  late final ServerSsh ssh;

  /// The host on each box, and the copies of its sessions.
  late final ServerRemoteHosts boxes;
  late final BoxAdmin admin;

  /// The frame relay `HostServer` hands a box's sessions to.
  late final BoxRelay relay;

  /// Where the server runs a command: this machine, its WSL distributions,
  /// an SSH box over its own connection.
  CommandRunnerFactory get runners => ssh.runners;

  /// Sessions on SSH boxes, for terminals, launches, setups and runs.
  RemoteSessions get remote => boxes;

  /// Told each lifecycle event a box host tells — its sessions' starts and
  /// exits, the box's facts, recorded on the rows they run.
  set onBoxLifecycle(void Function(LifecycleEvent event) record) =>
      boxes.onLifecycle = (_, event) => record(event);

  /// Told each agent hook a box host took, for the status and attention.
  set onBoxHook(void Function(AgentHookEvent hook) take) =>
      boxes.onHook = (_, hook) => take(hook);

  /// Answers every `ssh.*` request from now on.
  void attach() => _data.sshWork = ServerSshRequests(ssh: ssh, admin: admin);

  /// A shell on [hostId] (`sh -c`, whatever the account's login shell) over
  /// the connection already open to it, and the box's address; null when none
  /// is open. Only looking never dials.
  ({String address, Future<String> Function(String script) run})? openShell(
    String hostId,
  ) {
    final SshConnection connection;
    try {
      connection = ssh.pool.forHostId(hostId);
    } on ArgumentError {
      return null;
    }
    if (!connection.isConnected) return null;
    final target = SshHostDeployTarget(connection);
    return (
      address: connection.host.address,
      run: (script) async => (await target.run(script)).stdout,
    );
  }

  /// An SSH environment's files over the server's own SFTP; null for any
  /// other environment, or a host deleted while something still named it.
  FileSpace? fileSpaceFor(ExecutionEnvironment environment) {
    final hostId = environment.sshHostId;
    if (environment.kind != EnvironmentKind.ssh || hostId == null) return null;
    try {
      return SftpFileSpace(
        label: environment.name,
        files: RemoteFileBrowser(
          connection: ssh.pool.forHostId(hostId),
          environmentId: environment.id,
        ),
      );
    } on ArgumentError {
      return null;
    }
  }

  /// The folder a saved host names to start in, or null.
  String? defaultDirectoryOf(String hostId) {
    final path = ssh.hostOf(hostId)?.defaultDirectory?.path;
    return path == null || path.trim().isEmpty ? null : path;
  }

  /// Keeps a copy of every session still running on [hostId]'s host — for
  /// after the server restarted (the box kept them). Returns how many; a box
  /// that cannot be reached is said in the log, not thrown.
  Future<int> adoptRunning(String hostId) async {
    try {
      return await boxes.adoptRunning(hostId);
    } on Object {
      return 0;
    }
  }

  Future<void> close() async {
    await boxes.dispose();
    await ssh.close();
  }
}
