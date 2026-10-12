import 'dart:async' show Completer, TimeoutException;
import 'dart:io' show Platform, Process, ProcessException, ProcessStartMode;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart' as acp;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart'
    show AcpAuthChoice, AcpAuthChoiceDao;
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;

import 'acp_arguments.dart';
import 'acp_login_link.dart';
import 'acp_native_bridge.dart';
import 'acp_transport.dart';
import 'acp_usage_limit.dart' show speaksOfALimit;
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

/// Opens [terminal] and answers its exit code once it ends (null when it
/// ended without one); null when no terminal could be opened.
typedef AcpLoginTerminalOpener =
    Future<int?>? Function(AcpLoginTerminal terminal);

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
    AcpLoginTerminalOpener? openTerminal,
    void Function(Uri link)? openLink,
    void Function(AcpLoginProgress progress)? tell,
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
       _tell = tell ?? ((_) {}),
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
  final AcpLoginTerminalOpener? _openTerminal;

  /// Opens a link in this machine's browser.
  final void Function(Uri link)? _openLink;

  /// Tells every client how a login under way is going.
  final void Function(AcpLoginProgress progress) _tell;
  final DateTime Function() _now;

  /// The login under way per installation, completed to end it.
  final Map<String, Completer<void>> _underWay = {};

  /// Ends the login under way for [installationId], if there is one.
  DataAck cancel(String installationId) {
    final underWay = _underWay.remove(installationId);
    if (underWay != null && !underWay.isCompleted) underWay.complete();
    return const DataAck();
  }

  /// Runs [login] as [installationId]'s login under way: a second one ends
  /// the first, and [cancel] ends it with a refusal saying so.
  Future<T> _underWayAs<T>(
    String installationId,
    Future<T> Function(Future<Never> cancelled) login,
  ) async {
    cancel(installationId);
    final ended = Completer<void>();
    _underWay[installationId] = ended;
    final cancelled = ended.future.then<Never>(
      (_) => throw const DataRefused(
        DataRefusalCode.failed,
        'The login was cancelled.',
      ),
    );
    // Nobody may be listening once the login ended on its own.
    cancelled.ignore();
    try {
      return await login(cancelled);
    } finally {
      if (identical(_underWay[installationId], ended)) {
        _underWay.remove(installationId);
      }
    }
  }

  /// The methods [installationId] advertises, read over a fresh connection.
  Future<AcpAuthMethods> methods(String installationId) async {
    final target = _target(installationId);
    return _talk(target, readTimeout, (_, init) async {
      final own = target.spec.terminalLogin;
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
              completes:
                  target.spec.authCompletions[method.id]?.how ??
                  (method.isTerminal
                      ? 'Opens a terminal running '
                            '`${_commandLine(target, method)}`; finish '
                            'signing in there.'
                      : null),
            ),
          if (own != null)
            AcpAuthMethod(
              id: kAcpOwnTerminalLoginId,
              name: own.name,
              terminal: true,
              completes: own.how,
            ),
        ],
        supportsLogout: init.agentCapabilities.supportsLogout,
      );
    });
  }

  /// What a terminal method runs, as a person would type it.
  String _commandLine(_Target target, acp.AuthMethod method) {
    final command = method.terminalCommand;
    final program = (command ?? target.installation.executable.path)
        .split(RegExp(r'[/\\]'))
        .last;
    return [program, ...method.terminalArguments].join(' ');
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
    final open = _loginLinkOpener(target.environment, target.spec);
    final heard = _LoginHeard(
      (link, code) => _tell(
        AcpLoginProgress(
          installationId: installationId,
          methodId: methodId,
          link: link?.toString(),
          code: code,
        ),
      ),
    );
    // Raced outside as well as in: a cancel while the agent is still starting
    // answers at once, and the body's own race then ends the process.
    final name = await _underWayAs(
      installationId,
      (cancelled) => Future.any([
        _talk(
          target,
          authenticateTimeout,
          variables: _variablesFor(target.spec, methodId),
          onErrorLine: (line) {
            open?.call(line);
            heard.line(line);
          },
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
              await Future.any([
                peer.call(acp.AcpMethods.authenticate, {'methodId': methodId}),
                cancelled,
              ]);
            } on acp.AcpRpcError catch (error) {
              throw DataRefused(
                DataRefusalCode.failed,
                '${target.name} refused ${method.name}: ${error.message}',
              );
            }
            return method.name.isEmpty ? method.id : method.name;
          },
        ),
        cancelled,
      ]),
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
  /// method [methodId] — one the agent advertises, or the descriptor's own
  /// ([kAcpOwnTerminalLoginId]) — and answers once it has ended. A clean exit
  /// is re-checked with the agent: remembered confirmed where the agent says
  /// it is logged in, unconfirmed where it says nothing (ACP v1 has no way to
  /// ask), and refused where it says it is not.
  Future<AcpAuthState> terminalLogin(
    String installationId,
    String methodId,
  ) async {
    final open = _openTerminal;
    if (open == null) {
      throw const DataRefused.unavailable('this server opens no terminals');
    }
    final target = _target(installationId);
    final login = await _terminalFor(target, methodId);
    return _underWayAs(installationId, (cancelled) async {
      final ended = open(login.terminal);
      if (ended == null) {
        throw DataRefused.unavailable(
          'No terminal could be opened on ${target.environment.name} for '
          '${login.name}, so nothing was remembered.',
        );
      }
      _tell(
        AcpLoginProgress(
          installationId: installationId,
          methodId: methodId,
          terminal: login.terminal.title,
        ),
      );
      final int? exitCode;
      try {
        exitCode = await Future.any([
          ended,
          cancelled,
        ]).timeout(authenticateTimeout);
      } on TimeoutException {
        throw DataRefused(
          DataRefusalCode.failed,
          'The terminal login was not finished within '
          '${_spoken(authenticateTimeout)}, so Karmashala stopped waiting. '
          'Its terminal tab stays open; finish there and log in again.',
        );
      }
      if (exitCode != null && exitCode != 0) {
        throw DataRefused(
          DataRefusalCode.failed,
          '${login.name} ended with exit code $exitCode in the terminal, so '
          'nothing was remembered. Its output is in the terminal tab.',
        );
      }
      final loggedIn = await _loggedInNow(target);
      if (loggedIn == false) {
        throw DataRefused(
          DataRefusalCode.failed,
          'The terminal ended, but ${target.name} still says it is not '
          'logged in.',
        );
      }
      final now = _now();
      final choice = AcpAuthChoice(
        installationId: installationId,
        methodId: methodId,
        methodName: login.name,
        chosenAt: now,
        authenticatedAt: loggedIn == true ? now : null,
      );
      choices.upsert(choice);
      return _stateOf(choice);
    });
  }

  /// The terminal [methodId] runs in, and the method's name.
  Future<({AcpLoginTerminal terminal, String name})> _terminalFor(
    _Target target,
    String methodId,
  ) async {
    final installation = target.installation;
    final own = target.spec.terminalLogin;
    if (methodId == kAcpOwnTerminalLoginId) {
      if (own == null) {
        throw DataRefused.invalid('${target.name} has no terminal login');
      }
      return (
        terminal: AcpLoginTerminal(
          agentId: installation.agentId,
          environment: target.environment,
          directory: target.directory,
          executable: installation.executable.path,
          arguments: acpLoginArgumentsFor(
            installation,
            target.spec,
            own.arguments,
          ),
          variables: target.spec.environment,
          title: '${target.name}: ${own.name}',
        ),
        name: own.name,
      );
    }
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
    final command = method.terminalCommand;
    final name = method.name.isEmpty ? method.id : method.name;
    return (
      terminal: AcpLoginTerminal(
        agentId: installation.agentId,
        environment: target.environment,
        directory: target.directory,
        executable: command ?? installation.executable.path,
        // A typed terminal method appends to the agent's own invocation.
        arguments: command != null
            ? method.terminalArguments
            : [
                ...acpArgumentsFor(
                  installation,
                  target.spec,
                  linux: AcpLaunchSpec.runsOnLinux(
                    target.environment.kind,
                    hostIsLinux: Platform.isLinux,
                  ),
                ),
                ...method.terminalArguments,
              ],
        variables: {...target.spec.environment, ...method.env},
        title: '${target.name}: $name',
      ),
      name: name,
    );
  }

  /// Whether the agent says it is logged in now, over a fresh connection;
  /// null when it says nothing of it or could not be asked.
  Future<bool?> _loggedInNow(_Target target) async {
    try {
      return await _talk(
        target,
        readTimeout,
        (_, init) async => loggedInSaid(init),
      );
    } on DataRefused {
      return null;
    }
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
  /// Elsewhere the agent opens its own, unless a bridge speaks for it: the
  /// bridge runs in this process and has no browser to open.
  void Function(String line)? _loginLinkOpener(
    ExecutionEnvironment environment,
    AcpLaunchSpec spec,
  ) {
    final open = _openLink;
    if (open == null || !serverOpensLoginLinks(environment.kind, spec)) {
      return null;
    }
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
/// sentence around it; null when there is none, and when the line speaks of a
/// usage limit: its link is an upgrade page, not a login.
Uri? loginLinkIn(String line) {
  if (speaksOfALimit(line)) return null;
  final match = RegExp(r'https://[^\s"<>]+').firstMatch(line);
  if (match == null) return null;
  final text = match[0]!.replaceFirst(RegExp(r'''[.,;:)\]'"]+$'''), '');
  final link = Uri.tryParse(text);
  return link == null || link.host.isEmpty ? null : link;
}

/// A device code in [line], or in [link]'s `user_code`: what a device login
/// asks a person to confirm or type. Null when there is none.
String? deviceCodeIn(String line, {Uri? link}) {
  final inLink = link?.queryParameters['user_code'];
  if (inLink != null && inLink.isNotEmpty) return inLink;
  return RegExp(
    r'\bcode\b\D{0,24}?\b([A-Z0-9]{4,8}-[A-Z0-9]{4,8})\b',
    caseSensitive: false,
  ).firstMatch(line)?[1];
}

/// What an agent's own `initialize` says of its login, where it says
/// anything: the Claude bridge's `_meta.claudeCode.loggedIn`, the Codex
/// bridge's `_meta.codex.accountType`. Null for an agent that says nothing.
bool? loggedInSaid(acp.InitializeResult init) {
  final meta = init.meta;
  if (meta?['claudeCode'] case {'loggedIn': final bool loggedIn}) {
    return loggedIn;
  }
  if (meta?['codex'] case final Map<String, Object?> codex
      when codex.containsKey('accountType')) {
    return codex['accountType'] != null;
  }
  return null;
}

/// What an agent's stderr has said of a login under way: its first link and
/// any device code, each told once as it is heard.
class _LoginHeard {
  _LoginHeard(this._tell);

  final void Function(Uri? link, String? code) _tell;
  Uri? _link;
  String? _code;

  void line(String line) {
    final link = _link ?? loginLinkIn(line);
    final code = _code ?? deviceCodeIn(line, link: link);
    if (link == _link && code == _code) return;
    _link = link;
    _code = code;
    _tell(link, code);
  }
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
