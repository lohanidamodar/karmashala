import 'dart:async';
import 'dart:io' show Directory;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;

import 'acp_transport.dart';

/// How long one agent gets to answer `initialize`: an npx cold start
/// downloads the package first.
const Duration kAcpVersionProbeTimeout = Duration(seconds: 45);

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
  Future<AcpTransport>? spawning;
  AcpTransport? transport;
  AcpPeer? peer;
  try {
    return await Future(() async {
      spawning = spawn();
      final opened = await spawning!;
      transport = opened;
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
      final version = InitializeResult.fromJson(
        _asMap(answer),
      ).agentInfo?.version.trim();
      return version == null || version.isEmpty ? null : version;
    }).timeout(timeout);
  } on Object {
    return null;
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

/// Reads an ACP agent's version for the server's detection: the installation
/// is started in its environment through that environment's runner —
/// executable, then the installation's leading arguments, then the spec's,
/// under the spec's variables — asked `initialize`, and ended. Its `read` is
/// an `AcpVersionReader`.
class AcpVersionProbe {
  AcpVersionProbe({
    required this.runnerFor,
    this.timeout = kAcpVersionProbeTimeout,
    this.clientVersion = kHostVersion,
    void Function(String message)? log,
  }) : _log = log;

  final CommandRunner Function(ExecutionEnvironment environment) runnerFor;
  final Duration timeout;
  final String clientVersion;
  final void Function(String message)? _log;

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
    final version = await readAcpAgentVersion(
      () async => AcpTransport.process(
        await runner.start(
          CommandRequest(
            executable: installation.executable.path,
            arguments: [...installation.leadingArguments, ...spec.arguments],
            workingDirectory: EnvironmentPath(
              environmentId: environment.id,
              path: directory,
            ),
            environment: spec.environment,
          ),
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
