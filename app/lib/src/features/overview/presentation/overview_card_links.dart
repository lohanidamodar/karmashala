import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/overview_board.dart';
import '../application/overview_links.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart' show overviewCardOf;

/// Where each session is drawn, for a jump to it.
final _drawn = <String, BuildContext>{};

/// **A session's family ties, wherever it is drawn**: hovered or holding
/// the keys, [child] lights its parent and its sub-sessions and is lit by
/// them, ringed in the accent along a [radius]; and it can be jumped to
/// ([overviewJumpTo]).
///
/// Given [ring] false it draws no ring of its own: a surface with an
/// outline already, a family card or a sub-session's row, turns that
/// outline into the accent itself ([overviewLinkLit]), so one line is drawn.
class OverviewFamilyHover extends ConsumerStatefulWidget {
  const OverviewFamilyHover({
    required this.card,
    required this.child,
    this.radius = Radii.lg,
    this.ring = true,
    super.key,
  });

  final OverviewCard card;
  final Widget child;
  final double radius;
  final bool ring;

  @override
  ConsumerState<OverviewFamilyHover> createState() =>
      _OverviewFamilyHoverState();
}

class _OverviewFamilyHoverState extends ConsumerState<OverviewFamilyHover> {
  late String _id = widget.card.id;

  @override
  void didUpdateWidget(OverviewFamilyHover old) {
    super.didUpdateWidget(old);
    if (old.card.id != widget.card.id) {
      if (_drawn[_id] == context) _drawn.remove(_id);
      _id = widget.card.id;
    }
  }

  @override
  void dispose() {
    if (_drawn[_id] == context) _drawn.remove(_id);
    super.dispose();
  }

  void _enter() =>
      ref.read(overviewLinkFocusProvider.notifier).enter(widget.card);

  void _leave() => ref.read(overviewLinkFocusProvider.notifier).leave(_id);

  @override
  Widget build(BuildContext context) {
    _drawn[_id] = context;
    final card = widget.card;
    final lit =
        widget.ring &&
        ref.watch(
          overviewLinkFocusProvider.select((f) => overviewLinkLit(card, f)),
        );
    final body = MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _leave(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (has) => has ? _enter() : _leave(),
        child: widget.child,
      ),
    );
    if (!lit) return body;
    return DecoratedBox(
      key: ValueKey('overview-link-lit:${card.id}'),
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: StateLayers.focusRingWidth * 2,
        ),
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: body,
    );
  }
}

/// Brings [id]'s session into view and selects it.
void overviewJumpTo(BuildContext context, WidgetRef ref, String id) {
  ref.read(overviewFocusProvider.notifier).select(id);
  final target = _drawn[id];
  if (target != null && target.mounted) {
    Scrollable.ensureVisible(
      target,
      alignment: 0.2,
      duration: Motion.of(context).base,
    );
  }
}

/// "Go to parent" over a sub-session drawn apart from its parent — in
/// another lane, or waiting on the owner — whose header already says
/// "↳ from" it: back there in one tap. Nothing for a session whose parent is
/// not on the board.
class OverviewParentLink extends ConsumerWidget {
  const OverviewParentLink({required this.card, super.key});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parentId = card.parentId;
    if (parentId == null) return const SizedBox.shrink();
    final onBoard = ref.watch(
      overviewBoardProvider.select((b) => overviewCardOf(b, parentId) != null),
    );
    if (!onBoard) return const SizedBox.shrink();
    return Align(
      key: ValueKey('overview-link-elsewhere:${card.id}'),
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        key: ValueKey('overview-jump-parent:${card.id}'),
        onPressed: () => overviewJumpTo(context, ref, parentId),
        icon: const Icon(AppIcons.arrowUp),
        label: const Text('Go to parent'),
      ),
    );
  }
}
