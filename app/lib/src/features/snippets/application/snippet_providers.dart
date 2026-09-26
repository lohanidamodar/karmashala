import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';

/// Every saved snippet, from this app's copy of the server's, in the table's
/// order. A write lands in the copy at once and at the server after.
/// Nothing on the terminal's hot path watches this — `snippet_button_cost_test`.
class CommandSnippetsController extends Notifier<List<CommandSnippet>> {
  static final _log = AppLogger.named('snippets');

  @override
  List<CommandSnippet> build() {
    final replica = ref.watch(dataClientProvider).snippets;
    final listening = replica.changes.listen((_) => state = _sorted());
    ref.onDispose(listening.cancel);
    return _sorted();
  }

  DataClient get _client => ref.read(dataClientProvider);

  List<CommandSnippet> _sorted() => List.unmodifiable(
    <CommandSnippet>[..._client.snippets.values]..sort(compareSnippets),
  );

  CommandSnippet? getById(String id) => _client.snippets[id];

  /// Saves a new snippet; the server flattens [command] to one line
  /// ([singleLine]) and stamps it.
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
    _client.snippets.setLocal(snippet.id, snippet);
    _send(
      SnippetAdd(
        id: snippet.id,
        label: label,
        command: command,
        shellId: shellId,
        submit: submit,
      ),
    );
    return snippet;
  }

  void edit(
    String id, {
    required String label,
    required String command,
    required String? shellId,
    required bool submit,
  }) {
    final existing = _client.snippets[id];
    if (existing == null) return;
    _client.snippets.setLocal(
      id,
      existing.copyWith(
        label: label.trim(),
        command: singleLine(command),
        shellId: shellId,
        clearShell: shellId == null,
        submit: submit,
        updatedAt: ref.read(clockProvider).nowUtc(),
      ),
    );
    _send(
      SnippetEdit(
        id: id,
        label: label,
        command: command,
        shellId: shellId,
        submit: submit,
      ),
    );
  }

  void delete(String id) {
    _client.snippets.setLocal(id, null);
    _send(SnippetDelete(id));
  }

  /// Sent behind the copy; a refusal is logged and the copy read again.
  void _send<R>(DataRequest<R> request) => unawaited(
    _client
        .write(request, domain: DataDomain.snippets)
        .then<void>(
          (_) {},
          onError: (Object error) =>
              _log.warning('${request.kind} was refused: $error'),
        ),
  );

  /// Unique within a run and sortable: a counter rides along with the clock,
  /// because a fixed clock in a test makes two writes in one millisecond sure.
  String _newId(DateTime now) =>
      'snippet-${now.microsecondsSinceEpoch}-${_sequence++}';

  int _sequence = 0;
}

final commandSnippetsProvider =
    NotifierProvider<CommandSnippetsController, List<CommandSnippet>>(
      CommandSnippetsController.new,
    );
