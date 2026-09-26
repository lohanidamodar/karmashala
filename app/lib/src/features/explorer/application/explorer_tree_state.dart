import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A set of ids the user opened by hand. Deliberately not persisted: a
/// project's tree is session state, and a machine's `Terminals` dials it (§19).
class ExplorerOpenSet extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  bool contains(String id) => state.contains(id);

  /// Flips [id] and answers whether it is now open.
  bool toggle(String id) {
    final opening = !state.contains(id);
    state = opening ? {...state, id} : ({...state}..remove(id));
    return opening;
  }

  void open(String id) {
    if (!state.contains(id)) state = {...state, id};
  }
}

/// Projects expanded in the Explorer tree.
final explorerExpandedProjectsProvider =
    NotifierProvider<ExplorerOpenSet, Set<String>>(ExplorerOpenSet.new);

/// Machines whose `Terminals` section is open.
final explorerExpandedTerminalsProvider =
    NotifierProvider<ExplorerOpenSet, Set<String>>(ExplorerOpenSet.new);

/// The Explorer's search field, as typed.
class ExplorerSearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query;
}

final explorerSearchQueryProvider =
    NotifierProvider<ExplorerSearchQuery, String>(ExplorerSearchQuery.new);
