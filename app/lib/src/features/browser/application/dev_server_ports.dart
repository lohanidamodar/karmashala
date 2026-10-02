import 'package:riverpod/riverpod.dart';

import '../../terminal/data/terminals_client.dart';

/// Reads the ports Karmashala's panes have started listening on, once per
/// ask — the dev-server menu asks when it opens, and nothing polls.
final listeningPortsReaderProvider = Provider(
  (ref) => ref.watch(terminalsClientProvider).listeningPorts,
);
