import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'overview_board.dart';

/// The parents whose sub-sessions are folded away on the dashboard's tree.
class OverviewFoldedParents extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String parentId) => state = state.contains(parentId)
      ? ({...state}..remove(parentId))
      : {...state, parentId};
}

final overviewFoldedParentsProvider =
    NotifierProvider<OverviewFoldedParents, Set<String>>(
      OverviewFoldedParents.new,
    );

/// The card a pointer is over, or the keys are in: its family lights up.
@immutable
class OverviewLinkFocus {
  const OverviewLinkFocus(this.id, this.parentId);

  final String id;
  final String? parentId;
}

class OverviewLinkFocusController extends Notifier<OverviewLinkFocus?> {
  @override
  OverviewLinkFocus? build() => null;

  void enter(OverviewCard card) =>
      state = OverviewLinkFocus(card.id, card.parentId);

  void leave(String id) {
    if (state?.id == id) state = null;
  }
}

final overviewLinkFocusProvider =
    NotifierProvider<OverviewLinkFocusController, OverviewLinkFocus?>(
      OverviewLinkFocusController.new,
    );

/// Whether [card] lights up for [focus]: it is the focused card's parent, or
/// one of its sub-sessions.
bool overviewLinkLit(OverviewCard card, OverviewLinkFocus? focus) =>
    focus != null &&
    focus.id != card.id &&
    (focus.parentId == card.id || card.parentId == focus.id);
