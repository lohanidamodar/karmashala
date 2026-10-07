import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';
import 'overview_card_parts.dart';
import 'overview_cards.dart';
import 'overview_session_parts.dart';

/// From this window width two peeks dock side by side; below it, one.
const double kOverviewSideBySideFrom = 1600;

/// Whether the window is wide enough for two peeks.
bool overviewSideBySideFits(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kOverviewSideBySideFrom;

/// The pinned sessions still on the board, in the order they were pinned.
List<OverviewCard> watchOverviewPinned(WidgetRef ref) {
  final pinned = ref.watch(overviewPrefsProvider.select((p) => p.pinned));
  if (pinned.isEmpty) return const [];
  final board = ref.watch(overviewBoardProvider);
  return [for (final id in pinned) ?overviewCardOf(board, id)];
}

/// Pins or unpins [sessionId]; says so when the board is full.
void toggleOverviewPin(BuildContext context, WidgetRef ref, String sessionId) {
  if (!ref.read(overviewPrefsProvider.notifier).togglePin(sessionId)) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Up to $kOverviewPinLimit sessions can be pinned. Unpin one first.',
        ),
      ),
    );
  }
}

/// **Pinned**: up to three sessions held above the groups, kept per device,
/// with "Open side by side" where the window has room for two peeks.
class OverviewPinnedStrip extends ConsumerWidget {
  const OverviewPinnedStrip({required this.onOpen, super.key});

  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = watchOverviewPinned(ref);
    if (cards.isEmpty) return const SizedBox.shrink();
    final sideBySide = cards.length > 1 && overviewSideBySideFits(context);
    return Column(
      key: const ValueKey('overview-pinned'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: EyebrowLabel(
                'Pinned · ${cards.length}',
                padding: const EdgeInsets.only(bottom: Insets.sm),
              ),
            ),
            if (sideBySide)
              TextButton.icon(
                key: const ValueKey('overview-side-by-side'),
                onPressed: () => ref
                    .read(overviewFocusProvider.notifier)
                    .peekSideBySide(cards[0].id, cards[1].id),
                icon: const Icon(AppIcons.squareSplitHorizontal),
                label: const Text('Open side by side'),
              ),
          ],
        ),
        LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth < WidthClass.mediumMin) {
              return Column(
                children: [
                  for (final card in cards)
                    OverviewPhoneRow(
                      key: ValueKey('overview-pinned-card:${card.id}'),
                      card: card,
                      onOpen: onOpen,
                    ),
                ],
              );
            }
            // As many across as keep a card at the work grid's least width.
            final least = WidthClass.scaleBreakpoint(
              WidthClass.mediumMin / 2,
              MediaQuery.textScalerOf(context),
            );
            final across = ((box.maxWidth + Insets.md) / (least + Insets.md))
                .floor()
                .clamp(1, kOverviewPinLimit);
            return Column(
              children: [
                for (var start = 0; start < cards.length; start += across)
                  Padding(
                    padding: EdgeInsets.only(top: start == 0 ? 0 : Insets.md),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = start; i < start + across; i++) ...[
                            if (i > start) const SizedBox(width: Insets.md),
                            Expanded(
                              child: i < cards.length
                                  ? _PinnedCard(card: cards[i], onOpen: onOpen)
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// A pinned session, short: its header and what it is doing.
class _PinnedCard extends StatelessWidget {
  const _PinnedCard({required this.card, required this.onOpen});

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context) => OverviewCardFrame(
    key: ValueKey('overview-pinned-card:${card.id}'),
    card: card,
    onOpen: onOpen,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OverviewCardHeader(card: card),
        const SizedBox(height: Insets.xs),
        OverviewActivityLine(card: card),
      ],
    ),
  );
}

/// Pin and Unpin, in the peek's header.
class OverviewPinButton extends ConsumerWidget {
  const OverviewPinButton({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(
      overviewPrefsProvider.select((p) => p.pinned.contains(sessionId)),
    );
    return IconButton(
      key: const ValueKey('overview-peek-pin'),
      tooltip: pinned ? 'Unpin' : 'Pin to the top',
      visualDensity: VisualDensity.compact,
      isSelected: pinned,
      onPressed: () => toggleOverviewPin(context, ref, sessionId),
      icon: Icon(pinned ? AppIcons.pushPinFill : AppIcons.pushPin),
    );
  }
}
