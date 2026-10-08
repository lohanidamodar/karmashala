// The per-store releases cards and the signals panel.

part of '../store_app_detail.dart';

/// One card per store: stacked, or side by side.
class _Releases extends StatelessWidget {
  const _Releases({required this.group, required this.sideBySide});

  final StoreAppGroup group;
  final bool sideBySide;

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (final entry in group.entries)
        StoreReleasesCard(
          key: ValueKey('releases-${entry.app.key}'),
          entry: entry,
        ),
    ];
    if (!sideBySide || cards.length < 2) return _Stack(children: cards);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, card) in cards.indexed) ...[
          if (i > 0) const SizedBox(width: Insets.md),
          Expanded(child: card),
        ],
      ],
    );
  }
}

/// What wants a look, as sentences, loudest first.
class _SignalsPanel extends StatelessWidget {
  const _SignalsPanel({required this.group});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signals = group.signals;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, signal) in signals.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : Insets.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: Insets.xxs),
                    child: Icon(
                      signalIcon(signal),
                      size: Chrome.icon,
                      color: signalColor(context, signal),
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      signalSentence(signal),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (signal case ReleaseSignal(
                    release: StoreRelease(rolloutFraction: final fraction?),
                  )) ...[
                    const SizedBox(width: Insets.sm),
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.sm),
                      child: RolloutBar(fraction: fraction),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
