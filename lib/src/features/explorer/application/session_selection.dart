import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';

/// **What the Explorer has ticked, and whether it is asking.**
///
/// Keyed by session id and by nothing else. The tree refreshes on a poll and
/// re-sorts on every touch, so a row is a fresh widget at a fresh position
/// several times a minute; a selection held by index or by position would
/// silently follow the wrong rows across a refresh, and a refresh that moves
/// the selection is worse than one that clears it.
@immutable
class SessionSelection {
  const SessionSelection({this.active = false, this.ids = const {}});

  /// Not in selection mode, nothing ticked. What leaving the mode restores.
  static const none = SessionSelection();

  /// Whether checkboxes are drawn down the tree — and therefore whether a
  /// plain click ticks a row instead of opening it.
  final bool active;

  /// The ticked rows, native and imported alike.
  ///
  /// One set for both kinds, because a session id identifies a row uniquely
  /// whichever table it came from, and the delete routes each id by looking it
  /// up rather than by remembering which list drew it. That is also what makes
  /// [prune] possible: "does this still exist" is one question, asked of two
  /// DAOs.
  final Set<String> ids;

  bool contains(String id) => ids.contains(id);

  int get count => ids.length;

  bool get isEmpty => ids.isEmpty;

  SessionSelection copyWith({bool? active, Set<String>? ids}) =>
      SessionSelection(active: active ?? this.active, ids: ids ?? this.ids);
}

/// The one writer of [SessionSelection].
class SessionSelectionController extends Notifier<SessionSelection> {
  @override
  SessionSelection build() {
    // A ticked row that leaves the workspace drops out of the selection, so a
    // delete can never name a phantom. See [prune] for why membership rather
    // than visibility is the test.
    ref.listen(
      sessionSignalsProvider.select(
        (signals) => signals.forKinds(const {SessionChangeKind.membership}),
      ),
      (_, _) => prune(),
    );
    return SessionSelection.none;
  }

  /// Enters selection mode with **nothing ticked**.
  ///
  /// Deliberately does not preselect whatever row was singly selected. That row
  /// is what the user is *reading* — the transcript open in the right pane —
  /// not something they chose to act on, so carrying it in would make the first
  /// thing a bulk Delete offers to remove the session in front of them, and
  /// would make the user's first tick a *de*selection. The mode starts empty,
  /// so every tick in it is deliberate.
  void enter() {
    if (!state.active) state = const SessionSelection(active: true);
  }

  /// Leaves the mode and clears the selection — the two are one act, so there
  /// is no ticked set surviving out of sight of the checkboxes that made it.
  void leave() => state = SessionSelection.none;

  void toggleMode() => state.active ? leave() : enter();

  void toggle(String id) {
    final ids = Set<String>.of(state.ids);
    if (!ids.remove(id)) ids.add(id);
    state = state.copyWith(ids: ids);
  }

  void clear() {
    if (state.ids.isNotEmpty) state = state.copyWith(ids: const {});
  }

  /// Drops ticked ids whose session has left the workspace.
  ///
  /// **Membership, not visibility.** A row scrolled off, inside a collapsed
  /// project, or filtered out by the search box is still a session the user
  /// ticked and still perfectly deletable — dropping those would make the
  /// search field a destructive control over the selection. A row that has
  /// actually gone (deleted here, deleted elsewhere, its project removed) is
  /// dropped, because there is nothing left for the delete to name.
  ///
  /// Cheap when nothing is ticked, which is almost always: it reads no DAO at
  /// all until there is something to check.
  void prune() {
    if (state.ids.isEmpty) return;
    final sessions = ref.read(sessionDaoProvider);
    final imported = ref.read(importedSessionDaoProvider);
    final kept = {
      for (final id in state.ids)
        if (sessions.getById(id) != null || imported.getById(id) != null) id,
    };
    if (kept.length != state.ids.length) state = state.copyWith(ids: kept);
  }
}

/// **Watch this narrowly.** The Explorer inflates one `ConsumerWidget` per
/// visible row, and this provider changes on every tick; a row that watched the
/// whole value would rebuild all thirty rows to tick one. Every reader here
/// uses `.select` on the single fact it draws — `active`, `count`, or its own
/// membership — so Riverpod compares a `bool` or an `int` and stops.
final sessionSelectionProvider =
    NotifierProvider<SessionSelectionController, SessionSelection>(
      SessionSelectionController.new,
    );
