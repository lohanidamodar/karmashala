import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

/// **The server's environment vault, as this client may know it** (slice
/// 5a): the names and when each was set. The vault lives on the server, one
/// per server, and is write-only — a value is typed here, sent once in
/// `env.set`, and never read back by any client. Null until the server has
/// answered.
class EnvVariablesController extends Notifier<List<EnvVariableName>?> {
  @override
  List<EnvVariableName>? build() {
    final client = ref.watch(dataClientProvider);
    final changes = client.envChanges.listen((names) => state = names);
    ref.onDispose(changes.cancel);
    final told = client.envVariables;
    if (told == null) unawaited(refresh());
    return told;
  }

  /// Asks the server for the names now. A server that cannot answer leaves
  /// the list as it was; the page says nothing is known yet.
  Future<void> refresh() async {
    try {
      state = (await ref.read(dataClientProvider).send(const EnvList())).value;
    } on DataRefused {
      // Nothing learned; the change stream brings the names when it can.
    }
  }

  /// Sets [name] to [value] at the server, replacing any value it had.
  /// Throws [DataRefused] in the server's words.
  Future<void> set(String name, String value) async {
    await ref.read(dataClientProvider).send(EnvSet(name.trim(), value));
  }

  /// Renames [from] to [to] at the server in one write, setting [value] when
  /// one is given and keeping the old value otherwise. Throws [DataRefused]
  /// in the server's words — [to] taken, or [from] gone.
  Future<void> rename(String from, String to, {String? value}) async {
    await ref
        .read(dataClientProvider)
        .send(EnvRename(from, to.trim(), value: value));
  }

  /// Removes [name] at the server. Throws [DataRefused] in its words.
  Future<void> remove(String name) async {
    await ref.read(dataClientProvider).send(EnvRemove(name));
  }
}

final envVariablesProvider =
    NotifierProvider<EnvVariablesController, List<EnvVariableName>?>(
      EnvVariablesController.new,
    );
