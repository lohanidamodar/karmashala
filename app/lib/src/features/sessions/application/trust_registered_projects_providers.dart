import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The server's "Trust registered projects for agents", as it last told.
final trustRegisteredProjectsProvider = StreamProvider<bool>((ref) {
  final client = ref.watch(dataClientProvider);
  return (() async* {
    yield client.trustRegisteredProjects;
    yield* client.trustRegisteredProjectsChanges;
  })();
});

/// Changing that setting. The server owns the value and tells every client.
class TrustRegisteredProjectsActions {
  const TrustRegisteredProjectsActions(this._client);

  final DataClient _client;

  Future<void> set({required bool enabled}) => _client.write(
    AgentsTrustRegisteredProjectsSet(enabled: enabled),
    domain: DataDomain.sessions,
  );
}

final trustRegisteredProjectsActionsProvider =
    Provider<TrustRegisteredProjectsActions>(
      (ref) => TrustRegisteredProjectsActions(ref.watch(dataClientProvider)),
    );
