import 'package:riverpod/riverpod.dart';

import 'package:karmashala_terminal_runtime/persistence.dart';

/// This client's own layout store, never the server's: `main` overrides it
/// with the file in the app-support folder. Without one (a test, a tool) it
/// is in memory, so nothing on disk is ever touched by accident. Not closed on
/// dispose: the last save can land during container teardown.
final terminalLayoutStoreProvider = Provider<TerminalLayoutStore>(
  (ref) => TerminalLayoutStore.memory(),
);

final terminalLayoutDaoProvider = Provider<TerminalLayoutDao>(
  (ref) => TerminalLayoutDao(ref.watch(terminalLayoutStoreProvider)),
);
