import 'package:riverpod/riverpod.dart';

import 'package:karmashala_store/database.dart';

/// The server's database, opened by this app for the domains that do not yet
/// go through the server's data API (notes, todos and preferences do — see
/// `core/data/`). Created at bootstrap and supplied by a `ProviderScope`
/// override. Throws without one, so wiring fails loudly.
final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError(
    'databaseProvider must be overridden with an AppDatabase instance.',
  );
});
