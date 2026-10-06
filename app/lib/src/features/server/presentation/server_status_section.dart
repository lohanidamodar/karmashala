import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/clock_provider.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/application/settings_tab.dart';
import '../../settings/presentation/session_host_status_line.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_notice.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../../ssh/application/host_install_controller.dart';
import '../../terminal/application/local_host_providers.dart';
import '../application/server_files.dart';
import '../application/server_overview.dart';
import 'server_command_actions.dart';

/// Settings → Server → Status and controls. A phone sees a read-only summary
/// of the server it is connected to; Restart and Stop are a desktop's.
class ServerStatusSection extends ConsumerWidget {
  const ServerStatusSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = ref.watch(
      capabilitiesProvider.select((c) => c.hostsServer),
    );
    final overview = ref.watch(serverOverviewProvider);
    return SettingsSection(
      title: SettingsAnchor.serverStatus.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...switch (overview) {
            AsyncData(:final value) => _readings(context, ref, value, desktop),
            AsyncError(:final error) => [
              SettingsNote('Could not read the server: $error'),
            ],
            _ => [const SettingsNote('Reading the server…')],
          },
          if (desktop) ...[
            // Its Start, Sessions and Check; Restart and Stop are above.
            const SessionHostStatusLine(),
            SettingsSwitchRow(
              label: 'Keep sessions running when Karmashala quits',
              help:
                  'Terminals and agents in the server go on after the app '
                  'closes, and reopening picks them up. Off, quitting ends '
                  'them.',
              value: ref.watch(
                settingsControllerProvider.select(
                  (s) => s.quitKeepsHostSessions,
                ),
              ),
              onChanged: ref
                  .read(settingsControllerProvider.notifier)
                  .setQuitKeepsHostSessions,
            ),
            const _OtherMachinesRow(),
          ],
        ],
      ),
    );
  }

  List<Widget> _readings(
    BuildContext context,
    WidgetRef ref,
    ServerOverview overview,
    bool desktop,
  ) {
    final now = ref.watch(clockProvider).nowUtc();
    final started = overview.startedAt;
    final held = describeSessionsHeld(overview);
    final dataFolder = overview.dataFolder;
    return [
      SettingsRow(
        label: 'Status',
        control: SettingsValue(label: overview.state.label),
      ),
      SettingsRow(
        label: 'Version',
        control: SettingsValue(
          mono: true,
          label:
              'Server ${overview.serverVersion ?? 'not recorded'} · app '
              '${overview.appVersion.isEmpty ? 'not recorded' : overview.appVersion}',
        ),
      ),
      if (overview.versionsDiffer)
        const Padding(
          padding: EdgeInsets.only(bottom: Insets.sm),
          child: SettingsNotice(
            tone: SettingsNoticeTone.attention,
            message:
                'The server and this app differ in version. Restarting the '
                'server replaces it with this app\'s build.',
          ),
        ),
      if (started != null)
        SettingsRow(
          label: 'Up for',
          control: SettingsValue(
            label: describeUptime(now.difference(started.toUtc())),
          ),
        ),
      SettingsRow(
        label: desktop ? 'Sessions held' : 'Sessions',
        control: SettingsValue(label: held ?? 'Not recorded'),
      ),
      if (desktop && dataFolder != null)
        SettingsRow(
          label: 'Data folder',
          help: dataFolder,
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: () => _open(context, ref, dataFolder),
                child: const Text('Open'),
              ),
              const SizedBox(width: Insets.xs),
              OutlinedButton(
                onPressed: () => _copy(context, dataFolder),
                child: const Text('Copy'),
              ),
            ],
          ),
        ),
      if (desktop && overview.socketPath != null)
        _Details(socketPath: overview.socketPath!),
      if (desktop) _ControlsRow(overview: overview),
    ];
  }

  Future<void> _open(BuildContext context, WidgetRef ref, String path) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failure = await ref.read(serverFilesProvider).revealFolder(path);
    if (failure != null) {
      messenger?.showSnackBar(SnackBar(content: Text(failure)));
    }
  }

  Future<void> _copy(BuildContext context, String path) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: path));
    messenger?.showSnackBar(
      const SnackBar(content: Text('Copied the data folder.')),
    );
  }
}

/// The socket path, folded away: it is for a bug report, not for reading.
class _Details extends StatelessWidget {
  const _Details({required this.socketPath});

  final String socketPath;

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      title: Text('Details', style: Theme.of(context).textTheme.bodySmall),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      children: [
        SettingsRow(
          label: 'Socket',
          help: socketPath,
          control: const SizedBox.shrink(),
        ),
      ],
    ),
  );
}

/// Restart and Stop, each confirmed first with what it ends; disabled with
/// the reason while this app is not the one running this machine's server.
class _ControlsRow extends ConsumerWidget {
  const _ControlsRow({required this.overview});

  final ServerOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final refusal = overview.controlsRefusal;
    final idle = !overview.canRestart && !overview.canStop;
    return SettingsRow(
      label: 'Restart or stop',
      help:
          refusal ??
          (idle
              ? 'Nothing is running to restart or stop. Start is in the line '
                    'below.'
              : 'Restart replaces the server with this app\'s build.'),
      control: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(
            onPressed: refusal == null && overview.canRestart
                ? () => confirmServerRestart(context, overview)
                : null,
            child: Text(
              sessionHostRestartLabel(ref.watch(localHostStatusProvider)),
            ),
          ),
          const SizedBox(width: Insets.xs),
          OutlinedButton(
            onPressed: refusal == null && overview.canStop
                ? () => confirmServerStop(context, overview)
                : null,
            child: const Text('Stop'),
          ),
        ],
      ),
    );
  }
}

/// One line when another machine's server, as last read this launch, is
/// older than this app's or missing — their controls stay on Machines.
class _OtherMachinesRow extends ConsumerWidget {
  const _OtherMachinesRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final views = ref.watch(hostInstallControllerProvider).values;
    var outdated = 0;
    var missing = 0;
    for (final view in views) {
      switch (view.reading?.state) {
        case HostInstallState.outdated:
          outdated++;
        case HostInstallState.notInstalled:
          missing++;
        default:
          break;
      }
    }
    if (outdated == 0 && missing == 0) return const SizedBox.shrink();
    return SettingsRow(
      label: describeOtherServers(outdated: outdated, missing: missing),
      help: 'Each is updated from its own machine under Machines.',
      control: OutlinedButton(
        onPressed: () => ref
            .read(settingsTabSectionProvider.notifier)
            .reveal(SettingsTarget.anchor(SettingsAnchor.sshHosts)),
        child: const Text('Open Machines'),
      ),
    );
  }
}

/// "2 machines run an older server · 1 has no server".
String describeOtherServers({required int outdated, required int missing}) {
  final parts = [
    if (outdated > 0)
      outdated == 1
          ? '1 machine runs an older server'
          : '$outdated machines run an older server',
    if (missing > 0)
      outdated > 0
          ? '$missing ${missing == 1 ? 'has' : 'have'} no server'
          : missing == 1
          ? '1 machine has no server'
          : '$missing machines have no server',
  ];
  return parts.join(' · ');
}
