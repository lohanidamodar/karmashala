import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala_store/database.dart';

/// The conversation index is the one domain the app still keeps in a store
/// of its own (it moves in slice 1f): a test whose screen reaches it — Quick
/// Open's conversation search — gets an empty one, in memory.
Override conversationIndexDatabase() {
  final db = AppDatabase.memory();
  addTearDown(db.close);
  return databaseProvider.overrideWithValue(db);
}
