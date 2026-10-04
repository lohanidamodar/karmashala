import 'dart:async' show TimeoutException;
import 'dart:io' show Platform, Process, ProcessException, ProcessStartMode;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart' as acp;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart'
    show AcpAuthChoice, AcpAuthChoiceDao;
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;

import 'acp_native_bridge.dart';
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
    void Function(Uri link)? openLink,
    DateTime Function()? now,
    this.readTimeout = kAcpVersionProbeTimeout,
    this.authenticateTimeout = kAcpAgentLoginPatience,
    this.clientVersion = kHostVersion,
  }) : _installations = installations,
       _environments = environments,
       _registry = registry,
       _spawn = spawn,
       _vault = vault ?? (() => const {}),
       _openTerminal = openTerminal,
       _openLink = openLink,
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

  /// Opens a link in this machine's browser.
  final void Function(Uri link)? _openLink;
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
      onErrorLine: _loginLinkOpener(target.environment),
      timedOut:
          '${target.name} was not logged in within '
          '${_spoken(authenticateTimeout)}, so the login was ended. Log in '
          'again and finish signing in in the browser it opens.',
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

  /// An agent's browser login prints its link and tries to open it. In WSL
  /// that opener reaches no desktop, and the login waits on a callback that
  /// never comes, so the first https link it prints is opened here. Its
  /// callback is a loopback port, which WSL forwards from this machine.
  /// Elsewhere the agent opens its own.
  void Function(String line)? _loginLinkOpener(
    ExecutionEnvironment environment,
  ) {
    final open = _openLink;
    if (open == null || environment.kind != EnvironmentKind.wsl) return null;
    var opened = false;
    return (line) {
      if (opened) return;
      final link = loginLinkIn(line);
      if (link == null) return;
      opened = true;
      open(link);
    };
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
    void Function(String line)? onErrorLine,
    String? timedOut,
  }) async {
    try {
      return await talkToAcpAgent(
        () async => bridgedAcpTransport(
          target.spec,
          await _spawn(
            target.environment,
            acpProbeRequest(
              target.installation,
              target.spec,
              target.environment,
              target.directory,
              variables: variables,
            ),
          ),
        ),
        body,
        timeout: timeout,
        clientName: target.spec.clientName,
        clientVersion: clientVersion,
        onErrorLine: onErrorLine,
      );
    } on DataRefused {
      rethrow;
    } on TimeoutException catch (error) {
      throw DataRefused(
        DataRefusalCode.failed,
        timedOut ?? '${target.name} did not answer: $error',
      );
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

/// [span] as a person reads it: whole minutes, else seconds, else
/// milliseconds.
String _spoken(Duration span) {
  String count(int n, String unit) => n == 1 ? '1 $unit' : '$n ${unit}s';
  if (span.inMinutes > 0 && span == Duration(minutes: span.inMinutes)) {
    return count(span.inMinutes, 'minute');
  }
  if (span.inSeconds > 0 && span == Duration(seconds: span.inSeconds)) {
    return count(span.inSeconds, 'second');
  }
  return count(span.inMilliseconds, 'millisecond');
}

/// The first https link in [line], without the punctuation that ends a
/// sentence around it; null when there is none.
Uri? loginLinkIn(String line) {
  final match = RegExp(r'https://[^\s"<>]+').firstMatch(line);
  if (match == null) return null;
  final text = match[0]!.replaceFirst(RegExp(r'''[.,;:)\]'"]+$'''), '');
  final link = Uri.tryParse(text);
  return link == null || link.host.isEmpty ? null : link;
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

/// Opens [link] in the default browser of the machine this server runs on;
/// a browser that does not start is not the login's failure — it waits, and
/// ends at its timeout.
Future<void> openInThisMachinesBrowser(Uri link) async {
  final (executable, arguments) = Platform.isWindows
      ? ('rundll32', ['url.dll,FileProtocolHandler', '$link'])
      : Platform.isMacOS
      ? ('open', ['$link'])
      : ('xdg-open', ['$link']);
  try {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  } on ProcessException {
    // Nothing here opens a browser.
  }
}
