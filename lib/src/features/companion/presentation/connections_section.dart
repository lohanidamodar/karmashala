import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/presentation/session_card.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'companion_states.dart';
import 'pairing/pairing_screen.dart';

/// The saved desktops, on the settings screen: which one this phone is
/// talking to, when it last reached each, and the two verbs — switch, forget.
///
/// It lives in Settings because that is where "which machine am I paired
/// with" already lived; the Sessions tab gets the compact switcher instead,
/// so choosing a desktop never costs a trip through a tab.
///
/// **The section's frame is drawn in every state**, and only the list slot
/// answers. It used to collapse to nothing until the list arrived, which
/// conflated two different situations — "this phone has no desktops" and
/// "this phone has not looked yet" — and took "Add a desktop" away with it,
/// so a read that never answered left the settings screen with no way to pair
/// and nothing saying why.
///
/// No skeleton, and no spinner. The gateway contract seeds
/// `connectionsStates` with the value it already holds and emits it on
/// listen, so the unknown window is one microtask on both implementations: a
/// skeleton would render for a frame at most and inform nobody, and a delayed
/// indicator would be machinery for a latency the contract does not allow.
/// What the state costs instead is a sentence — the empty one is only said
/// once the phone knows it is true.
class ConnectionsSection extends ConsumerWidget {
  const ConnectionsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final connections = ref.watch(companionConnectionsProvider);
    final switching = ref.watch(companionSwitchingProvider);
    final saved = connections.asData?.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CompanionSectionHeader(
          // The plural until the count is known: a heading is not the place
          // to guess how many desktops this phone has.
          (saved?.length ?? 2) > 1 ? 'DESKTOPS' : 'PAIRED DESKTOP',
        ),
        companionAsync(
          connections,
          // Silence, not a placeholder. See the class comment.
          loading: () => const SizedBox.shrink(),
          // The stream carries no errors today, but a section that answers
          // "nothing" to one would be the same lie the loading state was.
          error: (error) => Text(
            companionErrorText(error),
            style: density
                .muted(theme)
                ?.copyWith(color: theme.colorScheme.error),
          ),
          data: (list) => _Saved(list: list, switching: switching),
        ),
        const SizedBox(height: Insets.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: switching != null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PairingScreen(),
                    ),
                  ),
            icon: const Icon(AppIcons.plus),
            label: const Text('Add a desktop'),
          ),
        ),
      ],
    );
  }
}

/// The list slot once the phone knows what it has: the saved desktops, or the
/// sentence saying there are none.
class _Saved extends StatelessWidget {
  const _Saved({required this.list, required this.switching});

  final List<CompanionConnection> list;

  /// The host id a switch is in flight for, or null.
  final String? switching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    if (list.isEmpty) {
      return Text(
        'No desktops saved on this phone yet.',
        style: density.muted(theme),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(
          density.isTouch ? Radii.lg : Radii.sm,
        ),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final connection in list)
            _ConnectionRow(
              connection: connection,
              busy: switching == connection.hostId,
              anyBusy: switching != null,
              last: connection == list.last,
            ),
        ],
      ),
    );
  }
}

/// One saved desktop: name, its state, and — when it is not the active one —
/// a whole-row tap that switches to it.
class _ConnectionRow extends ConsumerWidget {
  const _ConnectionRow({
    required this.connection,
    required this.busy,
    required this.anyBusy,
    required this.last,
  });

  final CompanionConnection connection;
  final bool busy;
  final bool anyBusy;
  final bool last;

  Future<void> _forget(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget ${connection.name}?'),
        content: Text(
          connection.active
              ? 'This phone forgets ${connection.name} and switches to '
                    'another saved desktop, if it has one. To also revoke '
                    "this phone's key, use that desktop's Remote access "
                    'settings.'
              : 'This phone forgets ${connection.name}. The desktop you are '
                    "using now is not affected. To also revoke this phone's "
                    "key, use that desktop's Remote access settings.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await ref
        .read(companionSwitchingProvider.notifier)
        .remove(connection.hostId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final now = ref.read(clockProvider).nowUtc();
    final at = connection.lastConnectedAt;

    // The badge already says "Active", so the line under it says something
    // else: how long ago this desktop was last reached.
    final subtitle = switch ((busy, connection.active, at)) {
      (true, _, _) => 'Connecting…',
      (_, true, _) => 'In use now',
      (_, false, null) => 'Never connected',
      (_, false, final seen) =>
        'Last used ${compactAge(now.difference(seen!))} ago',
    };

    return Semantics(
      button: !connection.active,
      selected: connection.active,
      child: InkWell(
        onTap: connection.active || anyBusy
            ? null
            : () => ref
                  .read(companionSwitchingProvider.notifier)
                  .switchTo(connection.hostId),
        child: Container(
          constraints: density.isTouch
              ? const BoxConstraints(minHeight: Touch.target)
              : null,
          // Less on the right than the left because the trailing icon button
          // brings its own 48dp box; a full gutter on both sides would push
          // the glyph a finger's width in from the edge it belongs on.
          padding: EdgeInsets.fromLTRB(
            density.padX,
            density.padY,
            Insets.sm,
            density.padY,
          ),
          decoration: last
              ? null
              : BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
          child: Row(
            children: [
              if (busy)
                SizedBox(
                  width: density.icon,
                  height: density.icon,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  AppIcons.deviceMobile,
                  size: density.icon,
                  color: connection.active
                      ? semantic.idle
                      : scheme.onSurfaceVariant,
                ),
              SizedBox(width: density.isTouch ? Insets.md : Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            connection.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: density.title(theme),
                          ),
                        ),
                        if (connection.active) ...[
                          const SizedBox(width: Insets.sm),
                          const _ActiveBadge(),
                        ],
                      ],
                    ),
                    Text(subtitle, style: density.muted(theme)),
                  ],
                ),
              ),
              IconButton(
                onPressed: anyBusy ? null : () => _forget(context, ref),
                icon: const Icon(AppIcons.linkBreak),
                tooltip: 'Forget ${connection.name}',
                visualDensity: density.isTouch
                    ? VisualDensity.standard
                    : VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Active" pill — colour plus a word, never colour alone.
class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs, vertical: 1),
      decoration: BoxDecoration(
        color: semantic.idle.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        'Active',
        style: theme.textTheme.labelSmall?.copyWith(
          color: semantic.idle,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
