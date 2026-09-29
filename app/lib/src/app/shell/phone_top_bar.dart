import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart' show CompanionPairing;

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../core/capabilities/capabilities.dart';
import '../../core/lifecycle/server_switcher.dart';
import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/remote/application/machines_providers.dart';
import '../../features/remote/presentation/machines_section.dart'
    show AddMachineDialog;
import '../widgets/adaptive_modal.dart';
import 'phone_shell.dart';
import 'quick_open/quick_open.dart';

/// The phone's top bar: which server this is (and a switch to another),
/// search, and how many sessions need you.
class PhoneTopBar extends StatelessWidget implements PreferredSizeWidget {
  const PhoneTopBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => AppBar(
    titleSpacing: Insets.xs,
    title: const PhoneHostSwitcher(),
    actions: [
      IconButton(
        tooltip: 'Search',
        icon: const Icon(AppIcons.magnifyingGlass),
        onPressed: () => QuickOpen.show(context),
      ),
      const _NeedsYouCount(),
      const SizedBox(width: Insets.xs),
    ],
  );
}

/// What a pick in the host switcher asks for.
sealed class _HostPick {
  const _HostPick();
}

final class _UseMachine extends _HostPick {
  const _UseMachine(this.machine);

  /// Null for this computer's own server.
  final CompanionPairing? machine;
}

final class _AddMachine extends _HostPick {
  const _AddMachine();
}

/// `▾ <server name>`: the machines to use, and adding one. A switch runs in
/// process ([ServerSwitcher]), as Settings › Machines does.
class PhoneHostSwitcher extends ConsumerWidget {
  const PhoneHostSwitcher({super.key});

  static String nameOf(CompanionPairing? machine) {
    if (machine == null) return 'This computer';
    final name = machine.hostName.trim();
    return name.isEmpty ? 'Server' : name;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = nameOf(ref.watch(activeMachineProvider));
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        button: true,
        label: 'Server: $name. Switch or add a machine',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: () => _open(context, ref),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.caretDown,
                    size: Chrome.iconSmall,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.xs),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
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

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final pick = await showAdaptiveModal<_HostPick>(
      context: context,
      title: 'Machines',
      builder: (_) => const _HostList(),
    );
    if (!context.mounted) return;
    switch (pick) {
      case _UseMachine(:final machine):
        await _use(context, ref, machine);
      case _AddMachine():
        await AddMachineDialog.show(context);
      case null:
        break;
    }
  }

  static Future<void> _use(
    BuildContext context,
    WidgetRef ref,
    CompanionPairing? machine,
  ) async {
    final switcher = ref.read(serverSwitcherProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (switcher == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Switching is not available here.')),
      );
      return;
    }
    final name = nameOf(machine);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Use $name?'),
        content: const Text(
          'This app becomes a client of that server: its sessions and '
          'terminals replace these. Nothing running on either server stops.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (go != true) return;
    // This tree goes with the old server: nothing here reads `ref` after.
    final outcome = await switcher.switchTo(machine);
    if (outcome == ServerSwitchOutcome.busy) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('A switch is already under way.')),
      );
    }
  }
}

/// The switcher's list: this computer where it hosts a server, every paired
/// machine, then Add a machine. Pops with a [_HostPick].
class _HostList extends ConsumerWidget {
  const _HostList();

  static String _routeOf(CompanionPairing machine) {
    final direct = machine.directEndpoint;
    if (direct != null) return 'At $direct';
    final relay = machine.relay;
    return relay.host == 'invalid.local' ? 'Paired' : 'Through ${relay.host}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeMachineProvider);
    final paired = ref.watch(pairedMachinesProvider);
    final hostsServer = ref.watch(clientCapabilitiesProvider).hostsServer;
    final canAdd = ref.watch(machinesProvider) != null;
    void pop(_HostPick pick) => Navigator.of(context).pop(pick);
    Widget row(CompanionPairing? machine, String detail) {
      final inUse = machine?.hostId == active?.hostId;
      return ListTile(
        title: Text(PhoneHostSwitcher.nameOf(machine)),
        subtitle: Text(detail),
        selected: inUse,
        trailing: inUse
            ? const Text('In use')
            : TextButton(
                onPressed: () => pop(_UseMachine(machine)),
                child: const Text('Use'),
              ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hostsServer) row(null, 'Its own Karmashala server.'),
        for (final machine in paired.value ?? const <CompanionPairing>[])
          row(machine, _routeOf(machine)),
        if (paired.isLoading && !paired.hasValue)
          const ListTile(title: Text('Loading machines…')),
        if (paired.hasError)
          ListTile(
            title: const Text('The machine list could not be read'),
            subtitle: Text('${paired.error}'),
          ),
        if (canAdd)
          ListTile(
            key: const Key('phone-add-machine'),
            leading: const Icon(AppIcons.plus),
            title: const Text('Add a machine'),
            onTap: () => pop(const _AddMachine()),
          ),
      ],
    );
  }
}

/// How many sessions need you, on the attention colour; a tap goes to
/// Sessions, where they are listed first. Nothing when none do.
class _NeedsYouCount extends ConsumerWidget {
  const _NeedsYouCount();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(needsYouCountProvider);
    if (count == 0) return const SizedBox.shrink();
    final attention = SemanticColors.of(context).attention;
    final ink = SurfaceTones.of(context).background;
    return Tooltip(
      message: '$count need you',
      child: Semantics(
        button: true,
        label: '$count sessions need you. Show them',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: () {
            ref.read(phoneWorkbenchProvider.notifier).close();
            ref.read(phoneTabProvider.notifier).select(PhoneTab.sessions);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: attention,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(
                  '$count',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
