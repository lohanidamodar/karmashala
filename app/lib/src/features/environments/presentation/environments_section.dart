import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../agents/application/agent_installations_controller.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import '../../settings/presentation/settings_section.dart';
import '../../settings/presentation/settings_theme.dart';
import '../../ssh/application/ssh_hosts_controller.dart';
import 'package:karmashala_environments/ssh.dart';
import '../../ssh/application/companion_route_store.dart';
import '../../ssh/presentation/pair_phone_dialog.dart';
import '../../ssh/presentation/pair_phone_entry.dart';
import '../../ssh/presentation/ssh_connection_status_chip.dart';
import 'package:karmashala_remote/pairing.dart' show HostRoute;
import '../application/environment_scan_controller.dart';
import '../application/environments_controller.dart';
import 'package:agent_cli/process.dart';

/// Every place Karmashala can run an agent, and what it found there. Grouped
/// by environment: one version on two machines is two installations.
class EnvironmentsSection extends ConsumerWidget {
  const EnvironmentsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final environments = ref.watch(environmentsControllerProvider);
    final installations = ref.watch(agentInstallationsControllerProvider);
    final hosts = ref.watch(sshHostsControllerProvider);

    return SettingsSection(
      title: 'EXECUTION ENVIRONMENTS',
      trailing: TextButton.icon(
        onPressed: () => ref
            .read(environmentsControllerProvider.notifier)
            .discoverAndPersist(),
        icon: const Icon(AppIcons.magnifyingGlass),
        label: const Text('Find local'),
      ),
      child: environments.isEmpty
          ? const SettingsNote('No environments known yet.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final environment in environments)
                  _EnvironmentCard(
                    environment: environment,
                    installations: [
                      for (final installation in installations)
                        if (installation.environmentId == environment.id)
                          installation,
                    ],
                    host: _hostFor(environment, hosts),
                  ),
              ],
            ),
    );
  }

  static SshHost? _hostFor(ExecutionEnvironment env, List<SshHost> hosts) {
    final id = env.sshHostId;
    if (id == null) return null;
    for (final host in hosts) {
      if (host.id == id) return host;
    }
    return null;
  }
}

class _EnvironmentCard extends ConsumerWidget {
  const _EnvironmentCard({
    required this.environment,
    required this.installations,
    this.host,
  });

  final ExecutionEnvironment environment;
  final List<AgentInstallation> installations;
  final SshHost? host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scan = ref
        .watch(environmentScanControllerProvider.notifier)
        .scanOf(environment.id);
    // Watched so a finished scan repaints the card.
    ref.watch(environmentScanControllerProvider);
    final isSsh = environment.kind == EnvironmentKind.ssh;

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // The board's row head: a quiet glyph, the name in the row
              // label's hand, the kind as a small dim tag.
              Icon(
                _iconFor(environment.kind),
                size: Chrome.iconSmall,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  environment.name,
                  style: SettingsStyles.rowLabel(context),
                ),
              ),
              Text(
                _kindLabel(environment.kind),
                style: SettingsStyles.sectionLabel(context),
              ),
            ],
          ),
          // The address, when there is one. Never the id: it is a database key, and the
          // local host's is the literal `windows` under a heading reading "macOS".
          if (host != null) ...[
            const SizedBox(height: Insets.xs),
            Text(host!.address, style: MonoStyles.small),
          ],
          if (isSsh && host != null) ...[
            const SizedBox(height: Insets.sm),
            SshConnectionStatusChip(hostId: host!.id),
          ],
          const SizedBox(height: Insets.sm),
          if (installations.isEmpty)
            Text(
              scan.found == null ? 'Not scanned yet.' : 'No agents found here.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (final installation in installations)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    const Icon(AppIcons.robot, size: Chrome.iconAction),
                    const SizedBox(width: Insets.sm),
                    Text(
                      AgentRegistry.builtIn.displayNameFor(
                        installation.agentId,
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        '${installation.version == null ? '' : 'v${installation.version} · '}'
                        '${installation.executable.path}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MonoStyles.small,
                      ),
                    ),
                  ],
                ),
              ),
          if (scan.error != null) ...[
            const SizedBox(height: Insets.sm),
            DesktopErrorBanner(scan.error!),
          ],
          if (isSsh && host != null) ...[
            const SizedBox(height: Insets.xs),
            _PhoneRoute(hostId: host!.id),
          ],
          const SizedBox(height: Insets.xs),
          // A Wrap: two buttons do not fit one line at the narrowest window
          // with bigger text.
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              TextButton.icon(
                onPressed: scan.busy
                    ? null
                    : () => ref
                          .read(environmentScanControllerProvider.notifier)
                          .scan(environment),
                icon: scan.busy
                    ? const InlineSpinner()
                    : const Icon(AppIcons.magnifyingGlass),
                label: Text(isSsh ? 'Connect and find agents' : 'Find agents'),
              ),
              if (isSsh && host != null)
                TextButton.icon(
                  onPressed: () => PairPhoneDialog.show(context, host: host!),
                  icon: const Icon(AppIcons.deviceMobile),
                  label: const Text(kPairPhoneLabel),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(EnvironmentKind kind) => switch (kind) {
    EnvironmentKind.windowsNative ||
    EnvironmentKind.localPosix => AppIcons.target,
    EnvironmentKind.wsl => AppIcons.terminal,
    EnvironmentKind.ssh => AppIcons.globe,
  };

  static String _kindLabel(EnvironmentKind kind) => switch (kind) {
    EnvironmentKind.windowsNative => 'WINDOWS',
    EnvironmentKind.localPosix => localHostEnvironmentName.toUpperCase(),
    EnvironmentKind.wsl => 'WSL',
    EnvironmentKind.ssh => 'SSH',
  };
}

/// How phones reach this machine, once somebody has chosen. Silent before
/// that: the route is decided by a dial, and none has been made here.
class _PhoneRoute extends ConsumerWidget {
  const _PhoneRoute({required this.hostId});

  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref.watch(companionRouteProvider(hostId));
    if (route == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Text(
      switch (route) {
        HostRoute.direct => 'Phones connect to this host itself.',
        HostRoute.relay => 'Phones connect through the hosted relay.',
      },
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
