import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../database/database_providers.dart';
import '../util/clock_provider.dart';
import 'app_preferences.dart';
import 'data_client.dart';

/// This app's client of the server's data. `main` overrides it with the one
/// it connected to the local server before the first frame. The default is
/// the **temporary** in-process fallback over [databaseProvider] — what
/// `flutter test` runs, where no server may be reached.
final dataClientProvider = Provider<DataClient>((ref) {
  final client = DataClient.inProcess(
    ref.watch(databaseProvider),
    reason: 'no server is reached from here (a test)',
    clock: ref.watch(clockProvider).nowUtc,
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
