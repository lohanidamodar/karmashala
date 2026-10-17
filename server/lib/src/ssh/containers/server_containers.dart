import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:agent_cli/process.dart';
import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:karmashala_core/util.dart' show Clock, SystemClock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/access.dart'
    show HandshakePermissions, SystemHandshakePermissions;
import 'package:karmashala_ssh/connection.dart';
import 'package:path/path.dart' as p;

import '../../data/data_service.dart';
import '../pool/server_ssh.dart';

/// **Linux containers as machines.** On a Docker host — an SSH host, reached
/// over the pool, or a WSL distribution — the server checks Docker, starts a
/// stock image whose first-start setup makes a key-only sshd, saves the
/// container as an SSH host reached through its host (a WSL one directly at
/// `localhost`, which WSL forwards), pins its key on first connect and has
/// its agents detected. Each container gets a key of its own, kept owner-only
/// in the data directory; no port is opened beyond the host's loopback.
class ServerContainers {
  ServerContainers({
    required DataService data,
    required ServerSsh ssh,
    required String dataDirectory,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
    Clock clock = const SystemClock(),
    Random? random,
    CommandRunner Function(ExecutionEnvironment environment)? runnerFor,
    Future<void> Function(String hostId)? connect,
    this.setupTimeout = const Duration(minutes: 30),
  }) : _data = data,
       _ssh = ssh,
       _keys = Directory(p.join(dataDirectory, 'containers', 'keys')),
       _permissions = permissions,
       _clock = clock,
       _random = random,
       _runnerFor = runnerFor ?? ssh.runners.forEnvironment,
       _connect = connect ?? ((hostId) => ssh.pool.forHostId(hostId).client());

  final DataService _data;
  final ServerSsh _ssh;
  final CommandRunner Function(ExecutionEnvironment environment) _runnerFor;
  final Future<void> Function(String hostId) _connect;
  final Directory _keys;
  final HandshakePermissions _permissions;
  final Clock _clock;
  final Random? _random;

  /// How long a container's first-start setup may take: npm installs.
  final Duration setupTimeout;

  /// Detects the agents in a new container's environment; set by the server
  /// once detection exists. A failure there does not undo the container.
  Future<void> Function(String environmentId)? detectAgents;

  final _creating = <String, _Create>{};

  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// Whether [environmentId] can run a container. Never throws: a host that
  /// cannot be reached answers why.
  Future<HostCheck> check(String environmentId) async {
    final ExecutionEnvironment environment;
    try {
      environment = _dockerHost(environmentId);
    } on DataRefused catch (refused) {
      return HostCheck.unreachable(refused.message);
    }
    try {
      final result = await _run(
        environment,
        hostCheckScript,
        timeout: const Duration(seconds: 60),
      );
      return parseHostCheck(result.stdout, hostName: environment.name);
    } on Object catch (error) {
      return HostCheck.unreachable(
        'Could not reach ${environment.name}: ${describeSshFailure(error)}',
      );
    }
  }

  /// Creates [spec] on [environmentId] as machine [machineId], telling each
  /// step as [ContainerProgress]. Whatever it made is removed when it fails or
  /// is cancelled — a home volume that was there before excepted.
  Future<SshHost> create({
    required String environmentId,
    required String machineId,
    required ContainerSpec spec,
  }) async {
    if (!_idPattern.hasMatch(machineId)) {
      throw DataRefused.invalid('"$machineId" cannot name a machine');
    }
    if (_creating.containsKey(machineId) || _ssh.hostOf(machineId) != null) {
      throw DataRefused.invalid('machine $machineId already exists');
    }
    final specProblem = containerSpecProblem(spec);
    if (specProblem != null) throw DataRefused.invalid(specProblem);
    final environment = _dockerHost(environmentId);
    final job = _creating[machineId] = _Create();
    void tell(ContainerStep step, [String? line]) => _data.announce([
      ContainerProgress(machineId: machineId, step: step, line: line),
    ]);

    var started = false;
    var volumeExisted = true;
    File? keyFile;
    SshHost? saved;
    try {
      tell(ContainerStep.checking, 'Checking ${environment.name}');
      final hostCheck = await check(environmentId);
      job.stopIfCancelled();
      if (!hostCheck.canHost) {
        throw DataRefused.invalid(hostCheck.problem ?? 'It cannot host one.');
      }
      final fits = containerSpecProblem(
        spec,
        cores: hostCheck.cores,
        freeMemoryMb: hostCheck.freeMemoryMb,
      );
      if (fits != null) throw DataRefused.invalid(fits);

      final listening = await _run(environment, listeningPortsScript);
      final port = chooseContainerPort({
        ...parseListeningPorts(listening.stdout),
        ..._loopbackPortsSaved(),
      });
      if (port == null) {
        throw DataRefused.invalid(
          'Every port Karmashala uses for containers is taken on '
          '${environment.name}.',
        );
      }
      volumeExisted =
          (await _run(
            environment,
            homeVolumeExistsScript(spec.containerName),
          )).stdout.trim() !=
          'no';
      job.stopIfCancelled();

      tell(ContainerStep.pulling, 'Pulling ${spec.distro.image}');
      final pulled = await _stream(
        environment,
        pullImageScript(spec.distro.image),
        job,
        (line) => tell(ContainerStep.pulling, line),
      );
      if (pulled != 0) {
        throw DataRefused(
          DataRefusalCode.failed,
          'Docker could not pull ${spec.distro.image} on ${environment.name}.',
        );
      }

      final key = generateContainerKey(
        comment: 'karmashala-${spec.name}',
        random: _random,
      );
      keyFile = await _writeKey(machineId, key.privatePem);

      tell(ContainerStep.starting, 'Starting ${spec.containerName}');
      final run = await _run(
        environment,
        runContainerScript(
          spec,
          port: port,
          publicKeyLine: key.publicLine,
          machineId: machineId,
        ),
        timeout: const Duration(minutes: 2),
      );
      if (!run.ok) {
        throw DataRefused(
          DataRefusalCode.failed,
          _lastLine(run.stderr) ?? 'docker run exited ${run.exitCode}.',
        );
      }
      started = true;
      final containerId = _lastLine(run.stdout) ?? '';
      job.stopIfCancelled();

      tell(ContainerStep.settingUp, 'Setting up ${spec.distro.label}');
      final setup = await _stream(
        environment,
        waitForSetupScript(
          spec.containerName,
          timeoutSeconds: setupTimeout.inSeconds,
        ),
        job,
        (line) => tell(ContainerStep.settingUp, line),
      );
      job.stopIfCancelled();
      if (setup != 0) {
        throw DataRefused(DataRefusalCode.failed, switch (setup) {
          3 => 'The setup inside the container failed; its log is above.',
          4 => 'The container disappeared during its setup.',
          5 => 'The setup took longer than ${setupTimeout.inMinutes} minutes.',
          _ => 'Waiting for the setup failed (exit $setup).',
        });
      }

      tell(ContainerStep.connecting, 'Connecting and pinning its host key');
      final SshHost machine = _data.applyAsServer(
        SshHostPut(
          SshHost(
            id: machineId,
            name: spec.name,
            host: environment.kind == EnvironmentKind.wsl
                ? 'localhost'
                : '127.0.0.1',
            port: port,
            username: kContainerUser,
            authMethod: SshAuthMethod.privateKey,
            privateKey: EnvironmentPath(
              environmentId: localHostEnvironmentId,
              path: keyFile.path,
            ),
            viaHostId: environment.kind == EnvironmentKind.ssh
                ? environment.sshHostId
                : null,
            container: SshContainer(
              environmentId: environment.id,
              name: spec.containerName,
              id: containerId,
              image: spec.distro.image,
              cpus: spec.cpus,
              memoryMb: spec.memoryMb,
              agents: [for (final cli in spec.agents) cli.name],
            ),
            createdAt: _clock.nowUtc(),
          ),
        ),
      );
      saved = machine;
      await _connect(machineId);
      job.stopIfCancelled();

      tell(ContainerStep.detecting, 'Looking for agents');
      try {
        await detectAgents?.call(sshEnvironmentId(machineId));
      } on Object catch (error) {
        tell(ContainerStep.detecting, 'Agent detection failed: $error');
      }
      tell(ContainerStep.done, '${spec.name} is ready');
      return machine;
    } on Object catch (error) {
      final why = switch (error) {
        DataRefused(:final message) => message,
        _ => describeSshFailure(error),
      };
      tell(ContainerStep.failed, why);
      await _undo(
        environment,
        spec.containerName,
        started: started,
        withHome: !volumeExisted,
        keyFile: keyFile,
        saved: saved,
      );
      if (error is DataRefused) rethrow;
      throw DataRefused(DataRefusalCode.failed, why);
    } finally {
      _creating.remove(machineId);
    }
  }

  /// Stops the create under way for [machineId]; it then cleans up and fails.
  Future<void> cancel(String machineId) async {
    await _creating[machineId]?.cancel();
  }

  /// Where container machine [hostId] stands.
  Future<ContainerState> status(String hostId) async {
    final (_, container) = _container(hostId);
    try {
      final result = await _run(
        _dockerHost(container.environmentId),
        containerStatusScript(container.name),
        timeout: const Duration(seconds: 30),
      );
      return parseContainerState(result.stdout);
    } on Object {
      return ContainerState.unknown;
    }
  }

  /// Starts or stops container machine [hostId].
  Future<ContainerState> power(
    String hostId,
    ContainerPowerAction action,
  ) async {
    final (_, container) = _container(hostId);
    final environment = _dockerHost(container.environmentId);
    if (action == ContainerPowerAction.stop) await _ssh.disconnect(hostId);
    final result = await _run(environment, switch (action) {
      ContainerPowerAction.start => startContainerScript(container.name),
      ContainerPowerAction.stop => stopContainerScript(container.name),
    }, timeout: const Duration(minutes: 2));
    if (!result.ok) {
      throw DataRefused(
        DataRefusalCode.failed,
        _lastLine(result.stderr) ??
            'docker ${action.name} exited ${result.exitCode}.',
      );
    }
    return status(hostId);
  }

  /// Deletes container machine [hostId]: the saved host first (refused while
  /// a project uses it), then the container; put back if that fails.
  Future<void> delete(String hostId, {required bool withHome}) async {
    final (host, container) = _container(hostId);
    final environment = _dockerHost(container.environmentId);
    _data.applyAsServer(SshHostDelete(hostId));
    await _ssh.disconnect(hostId);
    final result =
        await _run(
          environment,
          deleteContainerScript(container.name, withHome: withHome),
          timeout: const Duration(minutes: 2),
        ).onError<Object>(
          (error, _) => CommandResult(
            exitCode: -1,
            stdout: '',
            stderr: describeSshFailure(error),
          ),
        );
    if (!result.ok) {
      _data.applyAsServer(SshHostPut(host));
      throw DataRefused(
        DataRefusalCode.failed,
        'The container on ${environment.name} could not be deleted: '
        '${_lastLine(result.stderr) ?? 'exit ${result.exitCode}'}',
      );
    }
    _data.applyAsServer(KnownHostForget(host.hostKeyName, host.port));
    await _deleteKey(host);
  }

  (SshHost, SshContainer) _container(String hostId) {
    final host =
        _ssh.hostOf(hostId) ??
        (throw DataRefused.notFound('no machine is saved as $hostId'));
    final container =
        host.container ??
        (throw DataRefused.invalid('${host.name} is not a container'));
    return (host, container);
  }

  /// [environmentId] as a host Docker may run on: an SSH host that is not
  /// itself a container, or a WSL distribution.
  ExecutionEnvironment _dockerHost(String environmentId) {
    final environment =
        _data.environments.where((e) => e.id == environmentId).firstOrNull ??
        (throw DataRefused.notFound('no environment $environmentId'));
    switch (environment.kind) {
      case EnvironmentKind.wsl:
        return environment;
      case EnvironmentKind.ssh:
        final host = _ssh.hostOf(environment.sshHostId ?? '');
        if (host?.container != null) {
          throw DataRefused.invalid(
            '${environment.name} is a container; containers run on its host.',
          );
        }
        return environment;
      case EnvironmentKind.windowsNative || EnvironmentKind.localPosix:
        throw DataRefused.invalid(
          'Containers run on an SSH host or in WSL, not on '
          '${environment.name}.',
        );
    }
  }

  /// Ports saved hosts already use on a loopback address: two saved hosts may
  /// not share `127.0.0.1:<port>` (`ssh_hosts` is unique on it).
  Set<int> _loopbackPortsSaved() => {
    for (final environment in _data.environments)
      if (environment.sshHostId case final id?)
        if (_ssh.hostOf(id) case final host?)
          if (host.host == '127.0.0.1' || host.host == 'localhost') host.port,
  };

  Future<CommandResult> _run(
    ExecutionEnvironment environment,
    String script, {
    Duration timeout = const Duration(minutes: 1),
  }) => _runnerFor(environment).run(
    CommandRequest(
      executable: 'sh',
      arguments: const ['-s'],
      stdinText: script,
      timeout: timeout,
    ),
  );

  /// Runs [script] telling each output line; its exit code.
  Future<int> _stream(
    ExecutionEnvironment environment,
    String script,
    _Create job,
    void Function(String line) onLine,
  ) async {
    final handle = await _runnerFor(
      environment,
    ).start(const CommandRequest(executable: 'sh', arguments: ['-s']));
    job.handle = handle;
    try {
      final lines = [
        handle.stdoutLines.listen(onLine).asFuture<void>(),
        handle.stderrLines.listen(onLine).asFuture<void>(),
      ];
      handle.writeLine(script);
      await handle.closeStdin();
      final code = await handle.exitCode;
      await Future.wait(
        lines,
      ).timeout(const Duration(seconds: 5), onTimeout: () => const []);
      return code;
    } finally {
      job.handle = null;
    }
  }

  Future<File> _writeKey(String machineId, String pem) async {
    if (!_keys.existsSync()) _keys.createSync(recursive: true);
    if (!await _permissions.restrictDirectory(_keys)) {
      throw const DataRefused(
        DataRefusalCode.failed,
        'the containers\' key folder could not be made owner-only, so no key '
        'was written',
      );
    }
    final file = File(p.join(_keys.path, machineId));
    final temp = File('${file.path}.tmp');
    await temp.writeAsString('');
    if (!await _permissions.restrictFile(temp)) {
      await temp.delete();
      throw const DataRefused(
        DataRefusalCode.failed,
        'the container\'s key file could not be made owner-only, so it was '
        'not written',
      );
    }
    await temp.writeAsString(pem, flush: true);
    return temp.rename(file.path);
  }

  Future<void> _deleteKey(SshHost host) async {
    final path = host.privateKey?.path;
    // Only a key this service wrote, in its own folder.
    if (path == null || !p.isWithin(_keys.path, path)) return;
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  Future<void> _undo(
    ExecutionEnvironment environment,
    String containerName, {
    required bool started,
    required bool withHome,
    required File? keyFile,
    required SshHost? saved,
  }) async {
    if (saved != null) {
      try {
        _data.applyAsServer(SshHostDelete(saved.id));
        await _ssh.disconnect(saved.id);
        _data.applyAsServer(KnownHostForget(saved.hostKeyName, saved.port));
      } on Object {
        // The host row is the person's to remove if this could not.
      }
    }
    if (started) {
      try {
        await _run(
          environment,
          deleteContainerScript(containerName, withHome: withHome),
          timeout: const Duration(minutes: 2),
        );
      } on Object {
        // Reported by the failure itself; the container keeps its prefix.
      }
    }
    if (keyFile != null && keyFile.existsSync()) await keyFile.delete();
  }

  static String? _lastLine(String text) {
    final lines = text.trim().split('\n').where((l) => l.trim().isNotEmpty);
    return lines.isEmpty ? null : lines.last.trim();
  }
}

/// A create under way: whether it was cancelled, and what it is streaming.
class _Create {
  bool cancelled = false;
  ProcessHandle? handle;

  Future<void> cancel() async {
    cancelled = true;
    await handle?.kill();
  }

  void stopIfCancelled() {
    if (cancelled) throw const DataRefused.invalid('The create was cancelled.');
  }
}
