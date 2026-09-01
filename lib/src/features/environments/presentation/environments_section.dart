import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_registry.dart';
import '../../settings/presentation/settings_section.dart';
import '../../ssh/application/ssh_hosts_controller.dart';
import '../../ssh/domain/ssh_host.dart';
import '../../ssh/presentation/ssh_connection_status_chip.dart';
import '../application/environment_scan_controller.dart';
import '../application/environments_controller.dart';
import '../domain/environment_kind.dart';
import '../domain/execution_environment.dart';

/// Every place Karmashala can run an agent, and what it found there.
///
/// Grouped by environment rather than listed flat, because the environment is
/// what makes two installations different: `claude 2.1.251` on the Windows host
/// and `claude 2.1.251` on a build box are not one agent seen twice, they are
/// two independent installations that happen to share a version. A remote host
/// appears here as a third kind of environment beside Windows and WSL, with its
/// connection state on the same line — a machine that cannot be reached must not
/// read as a machine with nothing installed.
class EnvironmentsSection extends ConsumerWidget {
  const EnvironmentsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final environments = ref.watch(environmentsControllerProvider);
    final installations = ref.watch(agentInstallationsControllerProvider);
    final hosts = ref.watch(sshHostsControllerProvider);

    return SettingsSection(
      title: 'EXECUTION ENVIRONMENTS',
      trailing: TextButton.icon(
        onPressed: () => ref
            .read(environmentsControllerProvider.notifier)
            .discoverAndPersist(),
        icon: const Icon(AppIcons.magnifyingGlass, size: 16),
        label: const Text('Find local'),
      ),
      child: environments.isEmpty
          ? Text('No environments known yet.', style: theme.textTheme.bodySmall)
          : Column(
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

    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _iconFor(environment.kind),
                  size: 18,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    environment.name,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  _kindLabel(environment.kind),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            Text(
              host == null
                  ? environment.id
                  : '${environment.id} · ${host!.address}',
              style: const TextStyle(fontFamily: kMonoFamily, fontSize: 11),
            ),
            if (isSsh && host != null) ...[
              const SizedBox(height: Insets.sm),
              SshConnectionStatusChip(hostId: host!.id),
            ],
            const SizedBox(height: Insets.sm),
            if (installations.isEmpty)
              Text(
                scan.found == null
                    ? 'Not scanned yet.'
                    : 'No agents found here.',
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
                      const Icon(AppIcons.robot, size: 14),
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
                          style: const TextStyle(
                            fontFamily: kMonoFamily,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            if (scan.error != null) ...[
              const SizedBox(height: Insets.sm),
              DesktopErrorBanner(scan.error!),
            ],
            const SizedBox(height: Insets.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: scan.busy
                    ? null
                    : () => ref
                          .read(environmentScanControllerProvider.notifier)
                          .scan(environment),
                icon: scan.busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(AppIcons.magnifyingGlass, size: 16),
                label: Text(isSsh ? 'Connect and find agents' : 'Find agents'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(EnvironmentKind kind) => switch (kind) {
    EnvironmentKind.windowsNative => AppIcons.target,
    EnvironmentKind.wsl => AppIcons.terminal,
    EnvironmentKind.ssh => AppIcons.globe,
  };

  static String _kindLabel(EnvironmentKind kind) => switch (kind) {
    EnvironmentKind.windowsNative => 'WINDOWS',
    EnvironmentKind.wsl => 'WSL',
    EnvironmentKind.ssh => 'SSH',
  };
}
