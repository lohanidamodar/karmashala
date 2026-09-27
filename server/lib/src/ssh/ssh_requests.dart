import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../data/ssh_work.dart';
import 'deploy/box_admin.dart';
import 'pool/server_ssh.dart';

/// **Every `ssh.*` request a client makes** (slices 3a and 5d), answered by
/// the server's own SSH: a test connection, a disconnect and a prompt's
/// answer ([ServerSsh]); the host on a box — deploy, its sessions, its relay,
/// the port a phone dials and a pairing window ([BoxAdmin]).
class ServerSshRequests implements SshWork {
  ServerSshRequests({required this.ssh, required this.admin});

  final ServerSsh ssh;
  final BoxAdmin admin;

  @override
  List<DataChange> greeting() => ssh.greeting();

  @override
  Future<Object?> handle(SshWorkRequest<Object?> request) async =>
      switch (request) {
        SshTest(:final hostId, :final draft) => await ssh.test(
          draft ??
              ssh.hostOf(hostId!) ??
              (throw DataRefused.notFound('no SSH host is saved as $hostId')),
        ),
        SshDisconnect(:final hostId) => await () async {
          await ssh.disconnect(hostId);
          return const DataAck();
        }(),
        final SshAnswerPrompt answer => () {
          ssh.prompts.answer(answer);
          return const DataAck();
        }(),
        SshDeploy(:final hostId, :final action) => await admin.deploy(
          _saved(hostId),
          action,
        ),
        SshHostSessions(:final hostId) => await admin.sessions(_saved(hostId)),
        SshEndHostSession(:final hostId, :final sessionId) => await () async {
          await admin.endSession(_saved(hostId), sessionId);
          return const DataAck();
        }(),
        SshBoxRelay(
          :final hostId,
          :final action,
          :final port,
          :final ruleAddedByHand,
        ) =>
          await admin.relay(
            _saved(hostId),
            action,
            port: port,
            ruleAddedByHand: ruleAddedByHand,
          ),
        SshCompanionEndpoint(:final hostId, :final ruleAddedByHand) =>
          await admin.companionEndpoint(
            _saved(hostId),
            ruleAddedByHand: ruleAddedByHand,
          ),
        SshPairPhone(:final hostId, :final capabilities, :final relay) =>
          await admin.pair(
            _saved(hostId),
            capabilities: capabilities,
            relay: relay,
          ),
      };

  String _saved(String hostId) => ssh.hostOf(hostId) == null
      ? throw DataRefused.notFound('no SSH host is saved as $hostId')
      : hostId;
}
