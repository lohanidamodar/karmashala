part of '../data_request.dart';

// SSH reached by the server itself (slice 3a). The connection is the
// server's; what it cannot decide alone — an unknown host key, a password, a
// key passphrase — is put to every desktop client as `SshPromptOpened`, and
// the first answer wins. A secret travels client → server in
// `ssh.answerPrompt` only: never in an answer, a change, a log line or a
// `toString` (a request prints its kind alone). Phones are forwarded none of
// these.

DataRequest<Object?>? _sshRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      SshTest.name => SshTest(
        hostId: args.optionalString('hostId'),
        draft: args.values['draft'] == null
            ? null
            : args.value('draft', sshHostFromJson),
      ),
      SshDisconnect.name => SshDisconnect(args.string('hostId')),
      SshAnswerPrompt.name => SshAnswerPrompt(
        args.string('promptId'),
        trust: args.values['trust'] == null ? null : args.boolean('trust'),
        secret: args.optionalString('secret'),
      ),
      SshDeploy.name => SshDeploy(
        args.string('hostId'),
        _named(SshDeployAction.values, args, 'action'),
      ),
      SshHostSessions.name => SshHostSessions(args.string('hostId')),
      SshEndHostSession.name => SshEndHostSession(
        args.string('hostId'),
        args.string('sessionId'),
      ),
      SshBoxRelay.name => SshBoxRelay(
        args.string('hostId'),
        _named(SshRelayAction.values, args, 'action'),
        port: args.optionalInt('port') ?? kDefaultBoxRelayPort,
        ruleAddedByHand: args.boolean('ruleAddedByHand', orElse: false),
      ),
      SshCompanionEndpoint.name => SshCompanionEndpoint(
        args.string('hostId'),
        ruleAddedByHand: args.boolean('ruleAddedByHand', orElse: false),
      ),
      SshPairPhone.name => SshPairPhone(
        args.string('hostId'),
        capabilities: args.optionalInt('capabilities') ?? 0,
        relay: args.optionalString('relay') ?? '',
      ),
      _ => null,
    };

T _named<T extends Enum>(List<T> values, _Arguments args, String key) {
  final name = args.string(key);
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw DataRefused.invalid('${args.kind}: "$key" cannot be "$name"');
}

/// The port a box's relay listens on unless told otherwise: the relay's own
/// default, read from its contract.
const int kDefaultBoxRelayPort = kDefaultRelayPort;

/// Work the server does on an SSH connection of its own; answered when done.
sealed class SshWorkRequest<R> extends DataRequest<R> {
  const SshWorkRequest();
}

/// Connects to saved host [hostId] — or to [draft], settings not yet saved —
/// once, runs one command and hangs up. A prompt it needs is put to the
/// clients. Answers what happened, a failure included.
final class SshTest extends SshWorkRequest<SshTestResult> {
  const SshTest({this.hostId, this.draft})
    : assert((hostId == null) != (draft == null), 'a host id or a draft');

  static const String name = 'ssh.test';

  final String? hostId;
  final SshHost? draft;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'hostId': ?hostId,
    if (draft != null) 'draft': sshHostToJson(draft!),
  };

  @override
  Object? resultToJson(SshTestResult result) => result.toJson();

  @override
  SshTestResult resultFromJson(Object? json) =>
      _decode(kind, () => SshTestResult.fromJson(_object(json, kind)));
}

/// Closes the server's connection to host [hostId]; the next use dials again.
final class SshDisconnect extends SshWorkRequest<DataAck> {
  const SshDisconnect(this.hostId);

  static const String name = 'ssh.disconnect';

  final String hostId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'hostId': hostId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Answers prompt [promptId]: [trust] for a host key, [secret] for a password
/// or passphrase (null for "cancelled"). The first answer wins; a later one
/// is refused `notFound`. [secret] is used for one connection attempt and
/// never kept.
final class SshAnswerPrompt extends SshWorkRequest<DataAck> {
  const SshAnswerPrompt(this.promptId, {this.trust, this.secret});

  static const String name = 'ssh.answerPrompt';

  final String promptId;
  final bool? trust;
  final String? secret;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'promptId': promptId,
    'trust': ?trust,
    'secret': ?secret,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

// The Karmashala host on an SSH box, driven by the server (slice 5d): the
// server deploys it with its own connection and bundles, and a client only
// asks. Nothing here carries a key or a password.

/// Looks at, installs, starts, stops or removes the host on box [hostId]:
/// the reading after [action]. Install is the deploy every terminal, agent
/// and run on the box goes through.
final class SshDeploy extends SshWorkRequest<HostInstallReading> {
  const SshDeploy(this.hostId, this.action);

  static const String name = 'ssh.deploy';

  final String hostId;
  final SshDeployAction action;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'hostId': hostId,
    'action': action.name,
  };

  @override
  Object? resultToJson(HostInstallReading result) => result.toJson();

  @override
  HostInstallReading resultFromJson(Object? json) =>
      _decode(kind, () => HostInstallReading.fromJson(_object(json, kind)));
}

/// Every session the host on box [hostId] holds, ended ones included.
final class SshHostSessions extends SshWorkRequest<List<SessionSummary>> {
  const SshHostSessions(this.hostId);

  static const String name = 'ssh.hostSessions';

  final String hostId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'hostId': hostId};

  @override
  Object? resultToJson(List<SessionSummary> result) => [
    for (final summary in result) sessionSummaryToJson(summary),
  ];

  @override
  List<SessionSummary> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) sessionSummaryFromJson(item)],
  );
}

/// Ends session [sessionId] on box [hostId] for good.
final class SshEndHostSession extends SshWorkRequest<DataAck> {
  const SshEndHostSession(this.hostId, this.sessionId);

  static const String name = 'ssh.endHostSession';

  final String hostId;
  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'hostId': hostId,
    'sessionId': sessionId,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Sets up (or updates, restarts), looks at, stops or removes the relay on
/// box [hostId] at [port]. [ruleAddedByHand] is "Check again" after a
/// firewall command was run in a terminal there.
final class SshBoxRelay
    extends SshWorkRequest<SshBoxAnswer<SshRelayReading>> {
  const SshBoxRelay(
    this.hostId,
    this.action, {
    this.port = kDefaultBoxRelayPort,
    this.ruleAddedByHand = false,
  });

  static const String name = 'ssh.relaySetup';

  final String hostId;
  final SshRelayAction action;
  final int port;
  final bool ruleAddedByHand;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'hostId': hostId,
    'action': action.name,
    'port': port,
    if (ruleAddedByHand) 'ruleAddedByHand': true,
  };

  @override
  Object? resultToJson(SshBoxAnswer<SshRelayReading> result) =>
      result.toJson((reading) => reading.toJson());

  @override
  SshBoxAnswer<SshRelayReading> resultFromJson(Object? json) => _decode(
    kind,
    () => SshBoxAnswer.fromJson(_object(json, kind), SshRelayReading.fromJson),
  );
}

/// Where a phone reaches box [hostId]: its companion port opened (only
/// against evidence it is shut) and proved with a dial from the server.
final class SshCompanionEndpoint
    extends SshWorkRequest<SshBoxAnswer<CompanionEndpoint>> {
  const SshCompanionEndpoint(this.hostId, {this.ruleAddedByHand = false});

  static const String name = 'ssh.companionEndpoint';

  final String hostId;
  final bool ruleAddedByHand;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'hostId': hostId,
    if (ruleAddedByHand) 'ruleAddedByHand': true,
  };

  @override
  Object? resultToJson(SshBoxAnswer<CompanionEndpoint> result) =>
      result.toJson((endpoint) => endpoint.toJson());

  @override
  SshBoxAnswer<CompanionEndpoint> resultFromJson(Object? json) => _decode(
    kind,
    () =>
        SshBoxAnswer.fromJson(_object(json, kind), CompanionEndpoint.fromJson),
  );
}

/// Opens a pairing window on box [hostId]'s host: the code a phone types.
/// [capabilities] is the grant the person chose, passed on untouched;
/// [relay] empty is the direct route.
final class SshPairPhone extends SshWorkRequest<SshBoxAnswer<PairingWindow>> {
  const SshPairPhone(this.hostId, {required this.capabilities, this.relay = ''});

  static const String name = 'ssh.pairPhone';

  final String hostId;
  final int capabilities;
  final String relay;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'hostId': hostId,
    'capabilities': capabilities,
    if (relay.isNotEmpty) 'relay': relay,
  };

  @override
  Object? resultToJson(SshBoxAnswer<PairingWindow> result) =>
      result.toJson((window) => window.toJson());

  @override
  SshBoxAnswer<PairingWindow> resultFromJson(Object? json) => _decode(
    kind,
    () => SshBoxAnswer.fromJson(_object(json, kind), PairingWindow.fromJson),
  );
}
