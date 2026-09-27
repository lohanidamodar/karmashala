import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

/// Where the **server's** connection to one saved host stands, live — the
/// connection its agent work, checks and scans use (slice 3a). Told by the
/// server; watching dials nothing.
final sshConnectionStateProvider = StreamProvider.autoDispose
    .family<SshConnectionState, String>((ref, hostId) {
      final client = ref.watch(dataClientProvider);
      SshConnectionState now() =>
          client.sshConnections[hostId] ?? const SshConnectionState.idle();
      final states = StreamController<SshConnectionState>();
      final subscription = client.sshChanges.listen((change) {
        if (change is SshConnectionChanged && change.hostId == hostId) {
          states.add(now());
        }
      });
      states.add(now());
      ref.onDispose(() {
        subscription.cancel();
        states.close();
      });
      return states.stream;
    });

/// Asks the server to connect to saved host [hostId] — or to [draft],
/// settings not saved yet — once, run one command and hang up. A question it
/// needs (a key to trust, a password) comes back as a prompt; a failure is an
/// answer too, in words.
Future<SshTestResult> testSshHost(
  Ref ref, {
  String? hostId,
  SshHost? draft,
}) async {
  try {
    return (await ref
            .read(dataClientProvider)
            .send(SshTest(hostId: hostId, draft: draft)))
        .value;
  } on DataRefused catch (refusal) {
    return SshTestResult(connected: false, message: refusal.message);
  }
}

/// [testSshHost] for a widget.
final sshHostTestProvider = Provider<SshHostTester>(
  (ref) =>
      ({String? hostId, SshHost? draft}) =>
          testSshHost(ref, hostId: hostId, draft: draft),
);

typedef SshHostTester =
    Future<SshTestResult> Function({String? hostId, SshHost? draft});
