import 'dart:async';
import 'dart:io' show Directory, Platform;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;

import 'acp_arguments.dart';
import 'acp_native_bridge.dart';
import 'acp_temp_folders.dart';
import 'acp_transport.dart';
import 'acp_version_cache.dart';

/// How long one agent gets to answer `initialize`: an npx cold start
/// downloads the package first.
const Duration kAcpVersionProbeTimeout = Duration(seconds: 45);

/// A short-lived conversation with an ACP agent: the transport [spawn] opens,
/// `initialize`, then [body] with the peer and the agent's answer, and the
/// process ended — however it went. Throws what failed, or a
/// [TimeoutException] once [timeout] has passed. [onErrorLine] hears each
/// line the agent writes to stderr.
Future<T> talkToAcpAgent<T>(
  Future<AcpTransport> Function() spawn,
  Future<T> Function(AcpPeer peer, InitializeResult init) body, {
  Duration timeout = kAcpVersionProbeTimeout,
  String clientName = 'Karmashala',
  String clientVersion = kHostVersion,
  void Function(String line)? onErrorLine,
}) async {
  Future<AcpTransport>? spawning;
  AcpTransport? transport;
  AcpPeer? peer;
  StreamSubscription<String>? stderr;
  try {
    return await Future(() async {
      spawning = spawn();
      final opened = await spawning!;
      transport = opened;
      // Drained, or a chatty agent fills the pipe and blocks before it answers.
      stderr = opened.errorLines.listen(
        (line) => onErrorLine?.call(line),
        onError: (Object _) {},
      );
      final talking = AcpPeer(opened.output, opened.input);
      peer = talking;
      final answer = await talking.call(AcpMethods.initialize, {
        'protocolVersion': AcpVocabulary.protocolVersion,
        'clientCapabilities': const ClientCapabilities().toJson(),
        'clientInfo': ClientInfo(
          name: clientName,
          version: clientVersion,
        ).toJson(),
      });
      return body(talking, InitializeResult.fromJson(_asMap(answer)));
    }).timeout(timeout);
  } finally {
    // Ending it is bounded too: a probe never holds discovery.
    try {
      await peer?.close().timeout(_cleanupPatience, onTimeout: () {});
    } on Object {
      // Its process may be gone already.
    }
    if (transport case final started?) {
      try {
        await started.kill().timeout(_cleanupPatience, onTimeout: () {});
      } on Object {
        // Already ended.
      }
    } else if (spawning case final late?) {
      // The timeout fell while the process was still starting: it is ended
      // once it is there, not left to run.
      unawaited(late.then((started) => started.kill(), onError: (Object _) {}));
    }
    unawaited(stderr?.cancel());
  }
}

/// The version an ACP agent reports of itself: `initialize` is sent over the
/// transport [spawn] opens, `agentInfo.version` is read, and the process is
/// ended. Null when it did not answer within [timeout], answered without a
/// version, or failed at any step — nothing here throws, so discovery never
/// does.
Future<String?> readAcpAgentVersion(
  Future<AcpTransport> Function() spawn, {
  Duration timeout = kAcpVersionProbeTimeout,
  String clientName = 'Karmashala',
  String clientVersion = kHostVersion,
}) async {
  try {
    return await talkToAcpAgent(
      spawn,
      (_, init) async {
        final version = init.agentInfo?.version.trim();
        return version == null || version.isEmpty ? null : version;
      },
      timeout: timeout,
      clientName: clientName,
      clientVersion: clientVersion,
    );
  } on Object {
    return null;
  }
}

const Duration _cleanupPatience = Duration(seconds: 5);

JsonMap _asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

/// Where a probe starts an agent on a machine of [environment]'s kind: a
/// folder that is there and is nobody's project. Null for a box the server's
/// runners do not reach.
String? acpProbeDirectory(ExecutionEnvironment environment) =>
    switch (environment.kind) {
      EnvironmentKind.windowsNative => Directory.systemTemp.path,
      EnvironmentKind.localPosix || EnvironmentKind.wsl => '/tmp',
      EnvironmentKind.ssh => null,
    };

/// How a short-lived connection starts [installation] in [environment],
/// from [directory]: executable, then the installation's leading arguments,
/// then [spec]'s, under the spec's variables and then [variables].
CommandRequest acpProbeRequest(
  AgentInstallation installation,
  AcpLaunchSpec spec,
  ExecutionEnvironment environment,
  String directory, {
  Map<String, String> variables = const {},
}) => CommandRequest(
  executable: installation.executable.path,
  arguments: acpArgumentsFor(
    installation,
    spec,
    linux: AcpLaunchSpec.runsOnLinux(
      environment.kind,
      hostIsLinux: Platform.isLinux,
    ),
  ),
  workingDirectory: EnvironmentPath(
    environmentId: environment.id,
    path: directory,
  ),
  environment: {...spec.environment, ...variables},
);

/// Reads an ACP agent's version for the server's detection: the installation
/// is started in its environment through that environment's runner
/// ([acpProbeRequest]), asked `initialize`, and ended. Its `read` is an
/// `AcpVersionReader`. An installation whose executable is unchanged since
/// it last answered is not started again ([cache]), and one binary asked
/// for twice at once is started once.
class AcpVersionProbe {
  AcpVersionProbe({
    required this.runnerFor,
    this.timeout = kAcpVersionProbeTimeout,
    this.clientVersion = kHostVersion,
    AcpVersionCache? cache,
    this.fingerprintOf = acpInstallFingerprint,
    this.tempFolders,
    void Function(String message)? log,
  }) : cache = cache ?? AcpVersionCache(),
       _log = log;

  final CommandRunner Function(ExecutionEnvironment environment) runnerFor;
  final Duration timeout;
  final String clientVersion;
  final AcpVersionCache cache;
  final AcpInstallFingerprint fingerprintOf;

  /// Where an agent on this Windows machine gets its own TEMP; null: none.
  final AcpTempFolders? tempFolders;
  final void Function(String message)? _log;
  final Map<String, Future<String?>> _reading = {};

  Future<String?> read(
    AgentInstallation installation,
    AgentDescriptor descriptor,
    ExecutionEnvironment environment,
  ) async {
    final spec = descriptor.acp;
    final directory = acpProbeDirectory(environment);
    if (spec == null || directory == null) return null;
    final CommandRunner runner;
    try {
      runner = runnerFor(environment);
    } on Object {
      return null;
    }
    final key = AcpVersionCache.keyOf(installation);
    final fingerprint = await fingerprintOf(installation, environment, runner);
    if (fingerprint != null) {
      if (cache.versionFor(installation, fingerprint) case final known?) {
        return known;
      }
    }
    if (_reading[key] case final inFlight?) return inFlight;
    final reading = _ask(installation, descriptor, environment, runner, spec);
    _reading[key] = reading;
    try {
      final version = await reading;
      if (version != null && fingerprint != null) {
        cache.remember(installation, fingerprint, version);
      }
      return version;
    } finally {
      if (identical(_reading[key], reading)) unawaited(_reading.remove(key));
    }
  }

  Future<String?> _ask(
    AgentInstallation installation,
    AgentDescriptor descriptor,
    ExecutionEnvironment environment,
    CommandRunner runner,
    AcpLaunchSpec spec,
  ) async {
    final directory = acpProbeDirectory(environment)!;
    final version = await readAcpAgentVersion(
      () async => bridgedAcpTransport(
        spec,
        await startAcpProcess(
          runner.start,
          acpProbeRequest(installation, spec, environment, directory),
          temp: tempFolders?.forEnvironment(environment),
        ),
      ),
      timeout: timeout,
      clientName: spec.clientName,
      clientVersion: clientVersion,
    );
    _log?.call(
      version == null
          ? 'acp: ${descriptor.displayName} on ${environment.name} reported '
                'no version'
          : 'acp: ${descriptor.displayName} on ${environment.name} is $version',
    );
    return version;
  }
}
