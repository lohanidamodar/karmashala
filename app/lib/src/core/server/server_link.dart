import 'package:riverpod/riverpod.dart';

import '../data/data_client.dart';
import '../data/data_providers.dart';

export '../data/data_client.dart' show DataConnection, DataLinkState;

/// **The link to the server as a widget reads it**: how the data client
/// reaches the server now, live — the last reading the connection stream
/// gave, else the client's own. A widget watches this rather than the client.
final serverLinkProvider = Provider<DataConnection>(
  (ref) =>
      ref.watch(dataConnectionProvider).value ??
      ref.watch(dataClientProvider).connection,
);

/// Dials the server again now, cutting short any backoff.
final serverLinkRetryProvider = Provider<void Function()>(
  (ref) => ref.watch(dataClientProvider).retry,
);
