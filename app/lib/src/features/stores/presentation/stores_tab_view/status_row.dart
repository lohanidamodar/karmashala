// Store-wide notices and the status row above the dashboard.

part of '../stores_tab_view.dart';

typedef _Notice = ({String message, bool fault, bool settings});

/// The failures every app of a store shares, one notice each: a fault says
/// what failed and why; setup still to do says it once per store, its
/// remedies run together (`… to see the rating and installs.`).
List<_Notice> _storeWideNotices(List<StoreWideMissing> missing) {
  final notices = <_Notice>[];
  final setup = <StoreKind, List<StoreWideMissing>>{};
  for (final failure in missing) {
    if (failure.expected) {
      setup.putIfAbsent(failure.store, () => []).add(failure);
      continue;
    }
    final areas = failure.areas.map((area) => area.label).join(', ');
    notices.add((
      message:
          '${failure.store.label} · $areas, for every app: ${failure.message}',
      fault: true,
      settings:
          failure.kind == StoreFailure.auth ||
          failure.kind == StoreFailure.permission,
    ));
  }
  for (final MapEntry(key: store, value: failures) in setup.entries) {
    notices.add((
      message:
          '${store.label} · ${_joinRemedies([for (final failure in failures) failure.message])}',
      fault: false,
      settings: failures.any(
        (failure) => failure.kind == StoreFailure.notConfigured,
      ),
    ));
  }
  return notices;
}

/// Remedies that differ only after "to see" as one: "Add X to see the
/// rating." and "Add X to see installs." are "Add X to see the rating and
/// installs."
String _joinRemedies(List<String> messages) {
  const cut = ' to see ';
  final heads = {
    for (final message in messages)
      message.contains(cut) ? message.split(cut).first : message,
  };
  if (messages.length < 2 ||
      heads.length != 1 ||
      !messages.first.contains(cut)) {
    return messages.join(' ');
  }
  final tails = [
    for (final message in messages)
      message.split(cut).skip(1).join(cut).replaceAll(RegExp(r'\.$'), ''),
  ];
  final joined = tails.length == 2
      ? tails.join(' and ')
      : '${tails.take(tails.length - 1).join(', ')} and ${tails.last}';
  return '${heads.single}$cut$joined.';
}

/// How old the data is, how far a refresh has got, and the way to ask for
/// one; a thin bar under it fills as a refresh reads app after app.
class _StatusRow extends ConsumerWidget {
  const _StatusRow({required this.dashboard});

  final StoresState dashboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final at = dashboard.refreshedAt;
    final refreshing = dashboard.refreshing;
    final now = ref.watch(clockProvider).nowUtc();
    final age = at == null
        ? (refreshing ? 'Reading the stores…' : 'Not read yet')
        : 'Updated ${formatDataAge(now.difference(at))}';
    final total = dashboard.total;
    final progress = refreshing && total > 0
        ? ' · reading ${dashboard.done} of $total'
        : '';
    final apps = dashboard.view.apps.length;
    // How long the overview takes to fade from one state to the next; nothing
    // under reduced motion.
    final swap = Motion.of(context).base;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.xs,
            Insets.sm,
            Insets.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '$age$progress'),
                      if (!refreshing && apps > 0)
                        TextSpan(
                          text:
                              ' · $apps ${apps == 1 ? 'listing' : 'listings'}',
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: Insets.sm),
              TextButton.icon(
                onPressed: refreshing
                    ? null
                    : () => ref.read(storesProvider.notifier).refresh(),
                icon: refreshing
                    ? const InlineSpinner(semanticsLabel: 'Reading the stores')
                    : const Icon(
                        AppIcons.arrowsClockwise,
                        size: Chrome.iconAction,
                      ),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
        // Always two pixels tall, so starting and ending a refresh moves
        // nothing below it.
        SizedBox(
          height: 2,
          child: AnimatedOpacity(
            opacity: refreshing ? 1 : 0,
            duration: swap,
            child: refreshing
                ? TweenAnimationBuilder<double>(
                    tween: Tween(end: total > 0 ? dashboard.done / total : 0),
                    duration: swap,
                    builder: (context, value, _) => LinearProgressIndicator(
                      value: total > 0 ? value : null,
                      minHeight: 2,
                      backgroundColor: Colors.transparent,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}
