import 'package:riverpod/riverpod.dart';

import 'package:karmashala_terminal_runtime/persistence.dart';

import '../../../core/database/database_providers.dart';

/// The layout store, over the application database. The DAO is the package's;
/// the provider is the app's, the same split every other DAO here uses.
final terminalLayoutDaoProvider = Provider<TerminalLayoutDao>(
  (ref) => TerminalLayoutDao(ref.watch(databaseProvider)),
);
