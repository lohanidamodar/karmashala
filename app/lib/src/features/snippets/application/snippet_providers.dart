import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../data/command_snippet_dao.dart';
import '../domain/command_snippet.dart';

final commandSnippetDaoProvider = Provider<CommandSnippetDao>(
  (ref) => CommandSnippetDao(ref.watch(databaseProvider)),
);

/// Every saved snippet, kept in memory so a surface rebuilds on a write.
/// Nothing on the terminal's hot path watches this — `snippet_button_cost_test`.
class CommandSnippetsController extends Notifier<List<CommandSnippet>> {
  @override
  List<CommandSnippet> build() => ref.watch(commandSnippetDaoProvider).list();

  CommandSnippetDao get _dao => ref.read(commandSnippetDaoProvider);

  /// Saves a new snippet. [command] is flattened to one line — see
  /// [singleLine] for why a stored newline would be a submit nobody asked for.
  CommandSnippet add({
    required String label,
    required String command,
    String? shellId,
    bool submit = false,
  }) {
    final now = ref.read(clockProvider).nowUtc();
    final snippet = CommandSnippet(
      id: _newId(now),
      label: label.trim(),
      command: singleLine(command),
      shellId: shellId,
      submit: submit,
      createdAt: now,
      updatedAt: now,
    );
    _dao.insert(snippet);
    state = [...state, snippet];
    return snippet;
  }

  void edit(
    String id, {
    required String label,
    required String command,
    required String? shellId,
    required bool submit,
  }) {
    final index = state.indexWhere((s) => s.id == id);
    if (index == -1) return;
    final now = ref.read(clockProvider).nowUtc();
    final trimmed = label.trim();
    final flattened = singleLine(command);
    _dao.update(
      id,
      label: trimmed,
      command: flattened,
      shellId: shellId,
      submit: submit,
      updatedAt: now,
    );
    state = [...state]
      ..[index] = state[index].copyWith(
        label: trimmed,
        command: flattened,
        shellId: shellId,
        clearShell: shellId == null,
        submit: submit,
        updatedAt: now,
      );
  }

  void delete(String id) {
    _dao.delete(id);
    state = [
      for (final snippet in state)
        if (snippet.id != id) snippet,
    ];
  }

  /// Unique within a run and sortable, the same shape `NotesController` uses:
  /// a counter rides along with the clock because a fixed clock in a test makes
  /// two writes in one millisecond a certainty rather than a rarity.
  String _newId(DateTime now) =>
      'snippet-${now.microsecondsSinceEpoch}-${_sequence++}';

  int _sequence = 0;
}

final commandSnippetsProvider =
    NotifierProvider<CommandSnippetsController, List<CommandSnippet>>(
      CommandSnippetsController.new,
    );
