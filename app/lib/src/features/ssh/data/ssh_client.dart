import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart' show SessionSummary;
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// **The app's one client of SSH** (slices 3a and 5d): the server connects,
/// deploys the Karmashala host on a box, links to it, sets up its relay and
/// pairs phones there — this only asks, over the data API. The app holds no
/// SSH connection and reads no key (`test/features/ssh/no_ssh_in_app_guard_test.dart`).
class SshClient {
  const SshClient(this._client);

  final DataClient _client;

  Future<R> _ask<R>(DataRequest<R> request) async =>
      (await _client.send(request)).value;

  /// Where the server's connection to [hostId] stands, as it last told.
  SshConnectionState stateOf(String hostId) =>
      _client.sshConnections[hostId] ?? const SshConnectionState.idle();

  /// Connects to saved host [hostId] — or [draft], not yet saved — once,
  /// runs one command and hangs up. A question it needs comes back as a
  /// prompt; a failure is an answer too, in words.
  Future<SshTestResult> test({String? hostId, SshHost? draft}) async {
    try {
      return await _ask(SshTest(hostId: hostId, draft: draft));
    } on DataRefused catch (refusal) {
      return SshTestResult(connected: false, message: refusal.message);
    }
  }

  /// Closes the server's connection to [hostId]; the next use dials again.
  Future<void> disconnect(String hostId) => _ask(SshDisconnect(hostId));

  /// Answers a question the server put to every window.
  Future<void> answerPrompt(String promptId, {bool? trust, String? secret}) =>
      _ask(SshAnswerPrompt(promptId, trust: trust, secret: secret));

  /// [action] on box [hostId]'s host; the reading after it.
  Future<HostInstallReading> deploy(String hostId, SshDeployAction action) =>
      _ask(SshDeploy(hostId, action));

  /// Every session box [hostId]'s host holds, ended ones included.
  Future<List<SessionSummary>> hostSessions(String hostId) =>
      _ask(SshHostSessions(hostId));

  /// Ends [sessionId] on box [hostId] for good.
  Future<void> endHostSession(String hostId, String sessionId) =>
      _ask(SshEndHostSession(hostId, sessionId));

  /// [action] on the relay on box [hostId].
  Future<SshBoxAnswer<SshRelayReading>> relay(
    String hostId,
    SshRelayAction action, {
    required int port,
    bool ruleAddedByHand = false,
  }) => _ask(
    SshBoxRelay(hostId, action, port: port, ruleAddedByHand: ruleAddedByHand),
  );

  /// Where a phone reaches box [hostId], proved with a dial from the server.
  Future<SshBoxAnswer<CompanionEndpoint>> companionEndpoint(
    String hostId, {
    bool ruleAddedByHand = false,
  }) => _ask(SshCompanionEndpoint(hostId, ruleAddedByHand: ruleAddedByHand));

  /// A pairing window on box [hostId]'s host.
  Future<SshBoxAnswer<PairingWindow>> pairPhone(
    String hostId, {
    required int capabilities,
    String relay = '',
  }) => _ask(SshPairPhone(hostId, capabilities: capabilities, relay: relay));
}

final sshClientProvider = Provider<SshClient>(
  (ref) => SshClient(ref.watch(dataClientProvider)),
);

/// Where the **server's** connection to one saved host stands, live. Told by
/// the server; watching dials nothing.
final sshConnectionStateProvider = StreamProvider.autoDispose
    .family<SshConnectionState, String>((ref, hostId) {
      final client = ref.watch(dataClientProvider);
      final ssh = SshClient(client);
      final states = StreamController<SshConnectionState>();
      final subscription = client.sshChanges.listen((change) {
        if (change is SshConnectionChanged && change.hostId == hostId) {
          states.add(ssh.stateOf(hostId));
        }
      });
      states.add(ssh.stateOf(hostId));
      ref.onDispose(() {
        subscription.cancel();
        states.close();
      });
      return states.stream;
    });

/// [SshClient.test] for a widget.
final sshHostTestProvider = Provider<SshHostTester>(
  (ref) =>
      ({String? hostId, SshHost? draft}) =>
          ref.read(sshClientProvider).test(hostId: hostId, draft: draft),
);

typedef SshHostTester =
    Future<SshTestResult> Function({String? hostId, SshHost? draft});
