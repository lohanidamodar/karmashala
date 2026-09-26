import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_runtime.dart';
import 'package:karmashala_ui/rows.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';
import 'companion_states.dart';
import 'connection_route.dart';
import 'pairing/pairing_screen.dart';

/// The saved machines on the settings screen. The frame draws in every state
/// and only the list slot answers, so a read that never returns still pairs.
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
          // The plural until the count is known.
          (saved?.length ?? 2) > 1 ? 'MACHINES' : 'PAIRED MACHINE',
        ),
        companionAsync(
          connections,
          // Silence, not a placeholder. See the class comment.
          loading: () => const SizedBox.shrink(),
          // The stream carries no errors today, but answering "nothing" to one
          // would be the same lie the loading state was.
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
                    companionRoute<void>(context, (_) => const PairingScreen()),
                  ),
            icon: const Icon(AppIcons.plus),
            label: const Text('Add a machine'),
          ),
        ),
      ],
    );
  }
}

/// The list slot once the phone knows what it has: the saved machines, or the
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
        'No machines saved on this phone yet.',
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
          for (final connection in list) ...[
            if (connection != list.first) const CompanionRowDivider(indent: 0),
            _ConnectionRow(
              connection: connection,
              busy: switching == connection.hostId,
              anyBusy: switching != null,
            ),
          ],
        ],
      ),
    );
  }
}

/// Forgetting keeps the key valid on the machine; revoking it is done there.
const String _revokeThere =
    "To also revoke this phone's key, revoke it on that machine: in the "
    "desktop app's Remote access settings, or with karmashala_host revoke on "
    'a server.';

/// One saved machine: name, state, and a whole-row tap that switches to it when
/// it is not already active.
class _ConnectionRow extends ConsumerWidget {
  const _ConnectionRow({
    required this.connection,
    required this.busy,
    required this.anyBusy,
  });

  final CompanionConnection connection;
  final bool busy;
  final bool anyBusy;

  Future<void> _forget(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget ${connection.name}?'),
        content: Text(
          connection.active
              ? 'This phone forgets ${connection.name} and switches to '
                    'another saved machine, if it has one. $_revokeThere'
              : 'This phone forgets ${connection.name}. The machine you are '
                    'using now is not affected. $_revokeThere',
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
    final now = ref.read(companionClockProvider).nowUtc();
    final at = connection.lastConnectedAt;

    // The badge already says "Active", so this line says something else.
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
      child: CompanionTouchRow(
        onTap: connection.active || anyBusy
            ? null
            : () => ref
                  .read(companionSwitchingProvider.notifier)
                  .switchTo(connection.hostId),
        // Less on the right: the trailing icon button brings its own 48dp box,
        // and a full gutter would push the glyph in from the edge.
        padding: EdgeInsets.fromLTRB(
          density.padX,
          density.padY,
          Insets.sm,
          density.padY,
        ),
        leading: busy
            ? const InlineSpinner(size: InlineSpinnerSize.medium)
            : Icon(
                AppIcons.deviceMobile,
                size: density.icon,
                color: connection.active
                    ? semantic.idle
                    : scheme.onSurfaceVariant,
              ),
        title: Column(
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
            // A machine is reached by the one route it was paired over, so the
            // row says which — it is also what to change when it stops working.
            if (connectionRouteLabel(connection) case final route?)
              Text(
                route,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: density.muted(theme),
              ),
            // A found machine's route is the person's to choose; its own tap
            // target, so choosing one never switches machines by accident.
            ConnectionRouteLine(connection: connection),
          ],
        ),
        trailing: IconButton(
          onPressed: anyBusy ? null : () => _forget(context, ref),
          icon: const Icon(AppIcons.linkBreak),
          tooltip: 'Forget ${connection.name}',
          visualDensity: density.isTouch
              ? VisualDensity.standard
              : VisualDensity.compact,
        ),
      ),
    );
  }
}

/// How a machine paired by address is reached, or null for one the phone
/// finds by itself, over whichever path answers.
String? connectionRouteLabel(CompanionConnection connection) =>
    switch (connection.route) {
      null => null,
      HostRoute.direct => ['Direct', ?connection.directEndpoint].join(' · '),
      HostRoute.relay => 'Hosted relay',
    };

/// The "Active" pill — colour plus a word, never colour alone.
class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xs,
        vertical: companionBadgeHairline,
      ),
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
