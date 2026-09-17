import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';

/// What a selection holds. One kind at a time: the verbs differ (a session is
/// deleted, a project is filed into a context), so a mixed set would offer
/// only what both share, which is nothing.
enum SelectionKind {
  sessions,
  projects;

  /// "1 session", "3 projects".
  String count(int n) => switch (this) {
    SelectionKind.sessions => n == 1 ? '1 session' : '$n sessions',
    SelectionKind.projects => n == 1 ? '1 project' : '$n projects',
  };

  /// Why a row of the other kind cannot be ticked, in the tick box's tooltip.
  String get holdsLabel => switch (this) {
    SelectionKind.sessions => 'This selection holds sessions',
    SelectionKind.projects => 'This selection holds projects',
  };
}

/// What the Explorer has ticked, and whether it is asking. Keyed by id and
/// nothing else: the tree re-sorts several times a minute, and a selection
/// held by position would silently follow the wrong rows.
@immutable
class SessionSelection {
  const SessionSelection({
    this.active = false,
    this.ids = const {},
    this.kind,
    this.anchor,
  });

  /// Not in selection mode, nothing ticked. What leaving the mode restores.
  static const none = SessionSelection();

  /// Whether checkboxes are drawn down the tree — and therefore whether a
  /// plain click ticks a row instead of opening it.
  final bool active;

  /// The ticked rows. Native and imported sessions share one set, because an
  /// id identifies a row whichever table it came from.
  final Set<String> ids;

  /// What [ids] are; null while nothing is ticked, when either kind may start.
  final SelectionKind? kind;

  /// The row a Shift-click extends from: the last one ticked or unticked.
  final String? anchor;

  bool contains(String id) => ids.contains(id);

  /// Whether a row of [other] may join the selection as it stands.
  bool canTick(SelectionKind other) => kind == null || kind == other;

  int get count => ids.length;

  bool get isEmpty => ids.isEmpty;

  SessionSelection copyWith({bool? active, Set<String>? ids}) =>
      SessionSelection(
        active: active ?? this.active,
        ids: ids ?? this.ids,
        kind: kind,
        anchor: anchor,
      );
}

/// The one writer of [SessionSelection].
class SessionSelectionController extends Notifier<SessionSelection> {
  @override
  SessionSelection build() {
    // A ticked row that leaves the workspace drops out, so a bulk verb can
    // never name a phantom. See [prune] for why membership, not visibility.
    ref.listen(
      sessionSignalsProvider.select(
        (signals) => signals.forKinds(const {SessionChangeKind.membership}),
      ),
      (_, _) => prune(),
    );
    ref.listen(projectsControllerProvider, (_, _) => prune());
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

  /// Ticks or unticks [id], entering the mode if it was off. Refuses — and
  /// answers false — a row of a kind the selection does not hold.
  bool toggle(String id, {SelectionKind kind = SelectionKind.sessions}) {
    if (!state.canTick(kind)) return false;
    final ids = Set<String>.of(state.ids);
    if (!ids.remove(id)) ids.add(id);
    state = SessionSelection(
      active: true,
      ids: ids,
      kind: ids.isEmpty ? null : kind,
      anchor: id,
    );
    return true;
  }

  /// Adds every row from the anchor to [id] in [order] — the rows as drawn.
  /// With no anchor on screen it is a plain [toggle].
  bool extendTo(
    String id, {
    required SelectionKind kind,
    required List<String> order,
  }) {
    if (!state.canTick(kind)) return false;
    final from = state.anchor == null ? -1 : order.indexOf(state.anchor!);
    final to = order.indexOf(id);
    if (from < 0 || to < 0) return toggle(id, kind: kind);
    final (start, end) = from <= to ? (from, to) : (to, from);
    state = SessionSelection(
      active: true,
      ids: {...state.ids, ...order.sublist(start, end + 1)},
      kind: kind,
      anchor: state.anchor,
    );
    return true;
  }

  /// Ticks all of [ids], which are rows of [kind]. Refused while the selection
  /// holds the other kind.
  bool selectAll(List<String> ids, SelectionKind kind) {
    if (!state.canTick(kind) || ids.isEmpty) return false;
    state = SessionSelection(
      active: true,
      ids: {...state.ids, ...ids},
      kind: kind,
      anchor: state.anchor ?? ids.first,
    );
    return true;
  }

  /// Drops ticked ids whose row has left the workspace — membership, not
  /// visibility: a row scrolled off or filtered out is still acted on, and
  /// dropping those would make the search field a destructive control.
  void prune() {
    if (state.ids.isEmpty) return;
    final bool Function(String id) exists = switch (state.kind) {
      SelectionKind.projects =>
        (id) => ref.read(projectDaoProvider).getById(id) != null,
      _ =>
        (id) =>
            ref.read(sessionDaoProvider).getById(id) != null ||
            ref.read(importedSessionDaoProvider).getById(id) != null,
    };
    final kept = {
      for (final id in state.ids)
        if (exists(id)) id,
    };
    if (kept.length == state.ids.length) return;
    state = SessionSelection(
      active: state.active,
      ids: kept,
      kind: kept.isEmpty ? null : state.kind,
      anchor: kept.contains(state.anchor) ? state.anchor : null,
    );
  }
}

/// **Watch this narrowly.** The Explorer inflates one `ConsumerWidget` per
/// visible row and this changes on every tick, so every reader `.select`s the
/// single fact it draws — `active`, `count`, or its own membership.
final sessionSelectionProvider =
    NotifierProvider<SessionSelectionController, SessionSelection>(
      SessionSelectionController.new,
    );
