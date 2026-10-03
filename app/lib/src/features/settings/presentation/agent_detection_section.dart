import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../agents/application/agent_redetect_controller.dart';
import 'package:agent_cli/discovery.dart';
import 'agent_label.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Agents and accounts: run agent detection again, and say what it
/// did — a `(agent, environment)` pair searched once is never searched again,
/// so a CLI installed later stayed invisible. The line names what was *not*
/// found.
class AgentDetectionSection extends ConsumerWidget {
  const AgentDetectionSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentRedetectControllerProvider);

    // Board "Find agents": one row — Detection, what the last scan found, and
    // Rescan — with the per-machine breakdown under it once there is one.
    return SettingsSection(
      title: SettingsAnchor.detection.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: 'Detection',
            help: state.report == null
                ? 'Look for agents installed since, on every machine. Not '
                      'scanned yet in this session.'
                : state.report!.summary,
            control: TextButton.icon(
              onPressed: state.busy
                  ? null
                  : () => ref
                        .read(agentRedetectControllerProvider.notifier)
                        .redetect(),
              icon: state.busy
                  ? const InlineSpinner()
                  : const Icon(AppIcons.arrowsClockwise),
              label: const Text('Rescan'),
            ),
          ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: DesktopErrorBanner(state.error!),
            ),
          if (state.report case final report?
              when report.environments.isNotEmpty)
            _DetectionBreakdown(report: report),
        ],
      ),
    );
  }
}

/// The per-environment breakdown, shown only once there is one to show.
class _DetectionBreakdown extends ConsumerWidget {
  const _DetectionBreakdown({required this.report});

  final AgentDiscoveryReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final environment in report.environments) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: Text(
                environment.reachable
                    ? '${environment.environmentName}: '
                          '${_installed(environment)}'
                    : '${environment.environmentName}: not reached — '
                          '${environment.error}',
                style: MonoStyles.small.copyWith(
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
            ),
            // Its own line: neither found nor gone — the route to the file
            // could not be completed (§19), and the remedy is the path field
            // below rather than a reinstall.
            for (final install in environment.unreachablePaths)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.xs),
                child: Text(
                  '${environment.environmentName}: '
                  '${agentLabel(ref, install.agentId)} is installed at '
                  '${install.executable.path} but cannot be reached',
                  style: MonoStyles.small.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            for (final change in environment.movedPaths)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.xs),
                child: Text(
                  '${environment.environmentName}: '
                  '${change.displayName} moved to ${change.to}',
                  style: MonoStyles.small.copyWith(
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _installed(EnvironmentScanReport environment) =>
      environment.found.isEmpty
      ? 'no agents'
      : environment.found
            .map(
              (i) => '${i.agentId}${i.version == null ? '' : ' ${i.version}'}',
            )
            .join(', ');
}
