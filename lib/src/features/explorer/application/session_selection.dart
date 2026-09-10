import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';

/// What the Explorer has ticked, and whether it is asking. Keyed by session id
/// and nothing else: the tree re-sorts several times a minute, and a selection
/// held by position would silently follow the wrong rows.
@immutable
class SessionSelection {
  const SessionSelection({this.active = false, this.ids = const {}});

  /// Not in selection mode, nothing ticked. What leaving the mode restores.
  static const none = SessionSelection();

  /// Whether checkboxes are drawn down the tree — and therefore whether a
  /// plain click ticks a row instead of opening it.
  final bool active;

  /// The ticked rows, native and imported alike. One set, because an id
  /// identifies a row whichever table it came from — which is also what makes
  /// [prune] one question asked of two DAOs.
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
    // A ticked row that leaves the workspace drops out, so a delete can never
    // name a phantom. See [prune] for why membership, not visibility.
    ref.listen(
      sessionSignalsProvider.select(
        (signals) => signals.forKinds(const {SessionChangeKind.membership}),
      ),
      (_, _) => prune(),
    );
    return SessionSelection.none;
  }

  /// Enters selection mode with **nothing ticked** — the singly selected row is
  /// what the user is *reading*, so carrying it in would make the first thing a
  /// bulk Delete offers the session in front of them.
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

  /// Drops ticked ids whose session has left the workspace — membership, not
  /// visibility: a row scrolled off or filtered out is still deletable, and
  /// dropping those would make the search field a destructive control.
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
/// visible row and this changes on every tick, so every reader `.select`s the
/// single fact it draws — `active`, `count`, or its own membership.
final sessionSelectionProvider =
    NotifierProvider<SessionSelectionController, SessionSelection>(
      SessionSelectionController.new,
    );
