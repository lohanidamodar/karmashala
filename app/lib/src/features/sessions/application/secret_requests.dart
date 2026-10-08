import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

/// Agents' requests for a secret waiting for the owner, as the server tells
/// them: a label and a reason, never a value. The value typed into a card is
/// sent once in `secrets.provide`; the agent is given a reference.
class SecretRequestsController extends Notifier<List<SecretRequest>> {
  @override
  List<SecretRequest> build() {
    final client = ref.watch(dataClientProvider);
    final changes = client.secretRequestChanges.listen(
      (requests) => state = requests,
    );
    ref.onDispose(changes.cancel);
    final told = client.secretRequests;
    if (told == null) unawaited(refresh());
    return told ?? const [];
  }

  Future<void> refresh() async {
    try {
      state =
          (await ref.read(dataClientProvider).send(const SecretRequestsRead()))
              .value;
    } on DataRefused {
      // A server that takes no requests has none waiting.
    }
  }

  /// Saves [value] for request [id] on the server. Throws [DataRefused].
  Future<void> provide(String id, String value) async {
    await ref.read(dataClientProvider).send(SecretProvide(id, value));
  }

  Future<void> decline(String id) async {
    await ref.read(dataClientProvider).send(SecretDecline(id));
  }
}

final secretRequestsProvider =
    NotifierProvider<SecretRequestsController, List<SecretRequest>>(
      SecretRequestsController.new,
    );

/// The requests [sessionId]'s agent is waiting on.
final sessionSecretRequestsProvider =
    Provider.family<List<SecretRequest>, String>(
      (ref, sessionId) => [
        for (final request in ref.watch(secretRequestsProvider))
          if (request.sessionId == sessionId) request,
      ],
    );
