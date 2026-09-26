import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'app_preferences.dart';
import 'data_client.dart';

/// This app's client of the server's data. `main` overrides it with the one
/// it connected to this machine's server; a test, with one over its fake
/// server. Anything else has no server to reach, and says so.
final dataClientProvider = Provider<DataClient>((ref) {
  final client = DataClient.unavailable(
    'this process was not connected to a Karmashala server',
  );
  ref.onDispose(() => unawaited(client.close()));
  return client;
});

/// How the data client reaches the server now, as it moves.
final dataConnectionProvider = StreamProvider<DataConnection>((ref) {
  final client = ref.watch(dataClientProvider);
  return (() async* {
    yield client.connection;
    yield* client.connectionChanges;
  })();
});

final appPreferencesProvider = Provider<AppPreferences>(
  (ref) => AppPreferences(ref.watch(dataClientProvider)),
);
