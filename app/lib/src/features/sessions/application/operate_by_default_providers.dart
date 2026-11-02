import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The server's "Let new sessions operate Karmashala", as it last told.
final operateByDefaultProvider = StreamProvider<bool>((ref) {
  final client = ref.watch(dataClientProvider);
  return (() async* {
    yield client.operateByDefault;
    yield* client.operateByDefaultChanges;
  })();
});

/// Changing that setting. The server owns the value and tells every client.
class OperateByDefaultActions {
  const OperateByDefaultActions(this._client);

  final DataClient _client;

  Future<void> set({required bool enabled}) => _client.write(
    SessionsOperateByDefaultSet(enabled: enabled),
    domain: DataDomain.sessions,
  );
}

final operateByDefaultActionsProvider = Provider<OperateByDefaultActions>(
  (ref) => OperateByDefaultActions(ref.watch(dataClientProvider)),
);
