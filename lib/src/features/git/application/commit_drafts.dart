/// The commit message you were part-way through, per checkout.
///
/// In memory only, like the composer's drafts: a message is a thought about
/// the change in front of you, and carrying one across a restart would put it
/// on a tree that has moved. Keyed by environment and path, so the same
/// repository open in two worktrees keeps two messages.
library;

import 'package:riverpod/riverpod.dart';

class CommitDrafts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  void put(String checkout, String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      if (!state.containsKey(checkout)) return;
      state = {...state}..remove(checkout);
      return;
    }
    if (state[checkout] == message) return;
    state = {...state, checkout: message};
  }
}

final commitDraftsProvider =
    NotifierProvider<CommitDrafts, Map<String, String>>(CommitDrafts.new);
