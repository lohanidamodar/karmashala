import 'dart:io' show Platform;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart' as acp;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart'
    show AcpAuthChoice, AcpAuthChoiceDao;
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;

import 'acp_transport.dart';
import 'acp_version_probe.dart';

/// How a short-lived connection's process is started.
typedef AcpAuthSpawn =
    Future<AcpTransport> Function(
      ExecutionEnvironment environment,
      CommandRequest request,
    );

/// A login an agent completes in a terminal: what to run, and where.
class AcpLoginTerminal {
  const AcpLoginTerminal({
    required this.agentId,
    required this.environment,
    required this.directory,
    required this.executable,
    required this.arguments,
    required this.title,
    this.variables = const {},
  });

  final String agentId;
  final ExecutionEnvironment environment;

  /// Where it starts: a folder that is nobody's project.
  final String directory;
  final String executable;
  final List<String> arguments;
  final Map<String, String> variables;
  final String title;
}

/// What a start is given from the remembered choice: the spec authenticating
/// with it, and the API key that method reads.
typedef AcpStartAuth = ({AcpLaunchSpec spec, Map<String, String> variables});

/// **Logging in to the ACP agents on this server's machines.** ACP v1 gives
/// `initialize.authMethods`, `authenticate` and (when advertised) `logout`,
/// and no account identity — so what is kept per installation is the method
/// chosen and when `authenticate` last confirmed it. Every conversation with
/// the agent here is short-lived: started, `initialize`, one call, ended.
class ServerAcpAuth {
  ServerAcpAuth({
    required List<AgentInstallation> Function() installations,
    required List<ExecutionEnvironment> Function() environments,
    required AgentRegistry Function() registry,
    required this.choices,
    required AcpAuthSpawn spawn,
    Map<String, String> Function()? vault,
    bool Function(AcpLoginTerminal terminal)? openTerminal,
    DateTime Function()? now,
    this.readTimeout = kAcpVersionProbeTimeout,
    this.authenticateTimeout = const Duration(minutes: 3),
    this.clientVersion = kHostVersion,
  }) : _installations = installations,
       _environments = environments,
       _registry = registry,
       _spawn = spawn,
       _vault = vault ?? (() => const {}),
       _openTerminal = openTerminal,
       _now = now ?? (() => DateTime.now().toUtc());

  final AcpAuthChoiceDao choices;
  final Duration readTimeout;

  /// An agent's own login may wait on a browser a person completes.
  final Duration authenticateTimeout;
  final String clientVersion;
  final List<AgentInstallation> Function() _installations;
  final List<ExecutionEnvironment> Function() _environments;
  final AgentRegistry Function() _registry;
  final AcpAuthSpawn _spawn;
  final Map<String, String> Function() _vault;
  final bool Function(AcpLoginTerminal terminal)? _openTerminal;
  final DateTime Function() _now;

  /// The methods [installationId] advertises, read over a fresh connection.
  Future<AcpAuthMethods> methods(String installationId) async {
    final target = _target(installationId);
    return _talk(target, readTimeout, (_, init) async {
      return AcpAuthMethods(
        installationId: installationId,
        methods: [
          for (final method in init.authMethods)
            AcpAuthMethod(
              id: method.id,
              name: method.name.isEmpty ? method.id : method.name,
              description: method.description,
              terminal: method.isTerminal,
              apiKeyVariable: target.spec.apiKeyVariables[method.id],
            ),
        ],
        supportsLogout: init.agentCapabilities.supportsLogout,
      );
    });
  }

  /// The method remembered for [installationId], or null.
  AcpAuthState? state(String installationId) =>
      switch (choices.getByInstallation(installationId)) {
        final choice? => _stateOf(choice),
        null => null,
      };

  /// `authenticate` with [methodId], remembered once the agent said yes.
  Future<AcpAuthState> authenticate(
    String installationId,
    String methodId,
  ) async {
    final target = _target(installationId);
    final keyVariable = target.spec.apiKeyVariables[methodId];
    if (keyVariable != null && !_vault().containsKey(keyVariable)) {
      throw DataRefused.invalid(
        '${target.name} reads its key from $keyVariable, which is not set in '
        'Variables and secrets',
      );
    }
    final name = await _talk(
      target,
      authenticateTimeout,
      variables: _variablesFor(target.spec, methodId),
      (peer, init) async {
        final method = _advertised(target, init, methodId);
        if (method.isTerminal) {
          throw DataRefused.invalid(
            '${method.name} is completed in a terminal, not by the agent',
          );
        }
        try {
          await peer.call(acp.AcpMethods.authenticate, {'methodId': methodId});
        } on acp.AcpRpcError catch (error) {
          throw DataRefused(
            DataRefusalCode.failed,
            '${target.name} refused ${method.name}: ${error.message}',
          );
        }
        return method.name.isEmpty ? method.id : method.name;
      },
    );
    final now = _now();
    final choice = AcpAuthChoice(
      installationId: installationId,
      methodId: methodId,
      methodName: name,
      chosenAt: now,
      authenticatedAt: now,
    );
    choices.upsert(choice);
    return _stateOf(choice);
  }

  /// Opens a terminal on the installation's machine running the terminal
  /// method [methodId], and remembers the method unconfirmed — the protocol
  /// tells the client nothing of how a terminal login went.
  Future<AcpAuthState> terminalLogin(
    String installationId,
    String methodId,
  ) async {
    final open = _openTerminal;
    if (open == null) {
      throw const DataRefused.unavailable('this server opens no terminals');
    }
    final target = _target(installationId);
    final method = await _talk(
      target,
      readTimeout,
      (_, init) async => _advertised(target, init, methodId),
    );
    if (!method.isTerminal) {
      throw DataRefused.invalid(
        '${method.name} is done by the agent, not in a terminal',
      );
    }
    final installation = target.installation;
    final command = method.terminalCommand;
    final opened = open(
      AcpLoginTerminal(
        agentId: installation.agentId,
        environment: target.environment,
        directory: target.directory,
        executable: command ?? installation.executable.path,
        // A typed terminal method appends to the agent's own invocation.
        arguments: command != null
            ? method.terminalArguments
            : [
                ...installation.leadingArguments,
                ...target.spec.argumentsFor(
                  linux: AcpLaunchSpec.runsOnLinux(
                    target.environment.kind,
                    hostIsLinux: Platform.isLinux,
                  ),
                ),
                ...method.terminalArguments,
              ],
        variables: {...target.spec.environment, ...method.env},
        title: '${target.name}: ${method.name}',
      ),
    );
    if (!opened) {
      throw DataRefused.unavailable(
        'No terminal could be opened on ${target.environment.name} for '
        '${method.name}, so nothing was remembered.',
      );
    }
    final choice = AcpAuthChoice(
      installationId: installationId,
      methodId: methodId,
      methodName: method.name.isEmpty ? method.id : method.name,
      chosenAt: _now(),
    );
    choices.upsert(choice);
    return _stateOf(choice);
  }

  /// Forgets the remembered method; with [logout], an agent that advertises
  /// `logout` is asked to end its login first.
  Future<DataAck> clear(String installationId, {bool logout = false}) async {
    if (logout) {
      final target = _target(installationId);
      await _talk(target, readTimeout, (peer, init) async {
        if (!init.agentCapabilities.supportsLogout) return;
        try {
          await peer.call(acp.AcpMethods.logout, const <String, Object?>{});
        } on acp.AcpRpcError catch (error) {
          throw DataRefused(
            DataRefusalCode.failed,
            '${target.name} did not log out: ${error.message}',
          );
        }
      });
    }
    choices.delete(installationId);
    return const DataAck();
  }

  /// What a start of [installation] under [spec] takes from the remembered
  /// choice: that method as the one to authenticate with, and its API key.
  AcpStartAuth startAuth(AgentInstallation installation, AcpLaunchSpec spec) {
    final choice = choices.getByInstallation(installation.id);
    if (choice == null) return (spec: spec, variables: const {});
    return (
      spec: spec.withAuthMethod(choice.methodId),
      variables: _variablesFor(spec, choice.methodId),
    );
  }

  Map<String, String> _variablesFor(AcpLaunchSpec spec, String methodId) {
    final name = spec.apiKeyVariables[methodId];
    if (name == null) return const {};
    final value = _vault()[name];
    return value == null ? const {} : {name: value};
  }

  acp.AuthMethod _advertised(
    _Target target,
    acp.InitializeResult init,
    String methodId,
  ) {
    for (final method in init.authMethods) {
      if (method.id == methodId) return method;
    }
    throw DataRefused.invalid(
      '${target.name} does not offer "$methodId" (it offers '
      '${init.authMethods.map((m) => m.id).join(', ')})',
    );
  }

  Future<T> _talk<T>(
    _Target target,
    Duration timeout,
    Future<T> Function(acp.AcpPeer peer, acp.InitializeResult init) body, {
    Map<String, String> variables = const {},
  }) async {
    try {
      return await talkToAcpAgent(
        () => _spawn(
          target.environment,
          acpProbeRequest(
            target.installation,
            target.spec,
            target.environment,
            target.directory,
            variables: variables,
          ),
        ),
        body,
        timeout: timeout,
        clientName: target.spec.clientName,
        clientVersion: clientVersion,
      );
    } on DataRefused {
      rethrow;
    } on Object catch (error) {
      throw DataRefused(
        DataRefusalCode.failed,
        '${target.name} did not answer: '
        '${withoutSecrets('$error', variables.values)}',
      );
    }
  }

  _Target _target(String installationId) {
    final installation =
        _installations().where((i) => i.id == installationId).firstOrNull ??
        (throw DataRefused.notFound(
          'no agent installation with id $installationId',
        ));
    final adapter = _registry().adapterFor(installation.agentId);
    final spec = adapter?.acp;
    if (adapter == null || spec == null) {
      throw DataRefused.invalid(
        '${adapter?.descriptor.displayName ?? installation.agentId} is not '
        'spoken to over ACP',
      );
    }
    final name = adapter.descriptor.displayName;
    final environmentId = installation.environmentId;
    final environment =
        _environments().where((e) => e.id == environmentId).firstOrNull ??
        (throw DataRefused.notFound('no environment with id $environmentId'));
    final directory = acpProbeDirectory(environment);
    if (directory == null) {
      throw DataRefused.notFound(
        '$name on ${environment.name} cannot be reached for a login from '
        'here',
      );
    }
    return _Target(installation, spec, environment, directory, name);
  }

  AcpAuthState _stateOf(AcpAuthChoice choice) => AcpAuthState(
    installationId: choice.installationId,
    methodId: choice.methodId,
    methodName: choice.methodName,
    chosenAt: choice.chosenAt,
    authenticatedAt: choice.authenticatedAt,
  );
}

class _Target {
  const _Target(
    this.installation,
    this.spec,
    this.environment,
    this.directory,
    this.name,
  );

  final AgentInstallation installation;
  final AcpLaunchSpec spec;
  final ExecutionEnvironment environment;
  final String directory;
  final String name;
}
