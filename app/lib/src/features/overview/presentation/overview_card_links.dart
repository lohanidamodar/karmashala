import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/overview_board.dart';
import '../application/overview_links.dart';
import '../application/overview_providers.dart';

/// **A sub-session card's ties**, around [child], the card itself, drawn in
/// [among]:
/// - tied to its parent just before it: indented by its depth with a
///   connector on a desktop; on a [phone], a "↳ child of" line instead;
/// - its parent in another lane: "↳ parent" and a jump there, no connector;
/// - a parent: its sub-sessions counted under it, with a fold;
/// - hovered or holding the keys, its parent and its sub-sessions light up.
///
/// A card with none of these is [child] with the hover watch alone.
class OverviewLinked extends ConsumerStatefulWidget {
  const OverviewLinked({
    required this.card,
    required this.among,
    required this.child,
    this.phone = false,
    super.key,
  });

  final OverviewCard card;
  final List<OverviewCard> among;
  final Widget child;
  final bool phone;

  @override
  ConsumerState<OverviewLinked> createState() => _OverviewLinkedState();
}

/// Where each linked card is drawn, for a jump to it.
final _drawn = <String, BuildContext>{};

class _OverviewLinkedState extends ConsumerState<OverviewLinked> {
  late String _id = widget.card.id;

  @override
  void didUpdateWidget(OverviewLinked old) {
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
    final board = ref.watch(overviewBoardProvider);
    final link = overviewLinksOf(widget.among, board: board)[card.id];
    final children = overviewChildCardsOf(board, card.id);
    final lit = ref.watch(
      overviewLinkFocusProvider.select((f) => overviewLinkLit(card, f)),
    );
    final scheme = Theme.of(context).colorScheme;

    Widget body = MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _leave(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (has) => has ? _enter() : _leave(),
        child: widget.child,
      ),
    );
    if (lit) {
      body = DecoratedBox(
        key: ValueKey('overview-link-lit:${card.id}'),
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(
            color: scheme.primary,
            width: StateLayers.focusRingWidth * 2,
          ),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: body,
      );
    }
    if (children.isNotEmpty) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          body,
          _ChildrenFold(parent: card, children: children),
        ],
      );
    }
    if (link == null) return body;

    void peekParent() =>
        ref.read(overviewFocusProvider.notifier).peek(link.parentId);
    switch (link.kind) {
      case OverviewLinkKind.elsewhere:
        return Column(
          key: ValueKey('overview-link-elsewhere:${card.id}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // A desktop card's header names its parent already.
                if (widget.phone)
                  _LinkLine(
                    key: ValueKey('overview-parent-line:${card.id}'),
                    text: '↳ ${link.parentTitle}',
                    onTap: peekParent,
                  ),
                TextButton.icon(
                  key: ValueKey('overview-jump-parent:${card.id}'),
                  onPressed: () => _jumpTo(link.parentId),
                  icon: const Icon(AppIcons.arrowUp),
                  label: const Text('Go to parent'),
                ),
              ],
            ),
            body,
          ],
        );
      case OverviewLinkKind.tied when widget.phone:
        return Column(
          key: ValueKey('overview-child-link:${card.id}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _LinkLine(
              key: ValueKey('overview-child-of:${card.id}'),
              text: '↳ child of ${link.parentTitle}',
              onTap: peekParent,
            ),
            body,
          ],
        );
      case OverviewLinkKind.tied:
        final indent = Insets.lg * link.depth;
        return Padding(
          key: ValueKey('overview-child-link:${card.id}'),
          padding: const EdgeInsets.only(top: Insets.xs),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: ValueKey(
                    'overview-child-indent:${card.id}:${link.depth}',
                  ),
                  width: indent,
                  child: CustomPaint(
                    painter: _ConnectorPainter(
                      color: lit ? scheme.primary : scheme.outlineVariant,
                    ),
                  ),
                ),
                Expanded(child: body),
              ],
            ),
          ),
        );
    }
  }

  /// Brings [parentId]'s card into view and selects it.
  void _jumpTo(String parentId) {
    ref.read(overviewFocusProvider.notifier).select(parentId);
    final target = _drawn[parentId];
    if (target != null && target.mounted) {
      Scrollable.ensureVisible(
        target,
        alignment: 0.2,
        duration: Motion.of(context).base,
      );
    }
  }
}

/// The parent's line to its sub-session: down from the card above, then
/// across to this one's header.
class _ConnectorPainter extends CustomPainter {
  _ConnectorPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = StateLayers.focusRingWidth * 1.5
      ..style = PaintingStyle.stroke;
    final x = size.width - Insets.md;
    final y = (Insets.xl).clamp(0, size.height).toDouble();
    canvas
      ..drawLine(Offset(x, -Insets.xs), Offset(x, y), paint)
      ..drawLine(Offset(x, y), Offset(size.width, y), paint);
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) => old.color != color;
}

/// "↳ Parent", a tap peeking the parent.
class _LinkLine extends StatelessWidget {
  const _LinkLine({required this.text, required this.onTap, super.key});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Touch.compactControl),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.xs,
              vertical: Insets.xxs,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "▾ 3 sub-sessions · 2 working" under a parent: a tap folds its
/// sub-session cards away, or back.
class _ChildrenFold extends ConsumerWidget {
  const _ChildrenFold({required this.parent, required this.children});

  final OverviewCard parent;
  final List<OverviewCard> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final folded = ref.watch(
      overviewFoldedParentsProvider.select((s) => s.contains(parent.id)),
    );
    final label = overviewChildrenLine(children);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      expanded: !folded,
      label: label,
      excludeSemantics: true,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: InkWell(
          key: ValueKey('overview-children-fold:${parent.id}'),
          onTap: () => ref
              .read(overviewFoldedParentsProvider.notifier)
              .toggle(parent.id),
          borderRadius: BorderRadius.circular(Radii.sm),
          child: TouchTarget(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    folded ? AppIcons.caretRight : AppIcons.caretDown,
                    size: UiDensity.of(context).iconSmall,
                    color: muted,
                  ),
                  const SizedBox(width: Insets.xs),
                  Flexible(
                    child: Text(
                      label,
                      key: ValueKey('overview-children-line:${parent.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
