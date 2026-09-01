import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../agents/application/agent_redetect_controller.dart';
import '../../agents/domain/agent_discovery_report.dart';
import 'settings_section.dart';

/// Settings → Agents: run agent detection again, and say what it did.
///
/// Detection used to happen exactly once, on the workspace's first launch, and
/// a `(agent, environment)` pair searched for once is never searched for again
/// — so a CLI installed afterwards, or one missed because the app's inherited
/// PATH was stale at that moment, stayed invisible with no way to ask again.
/// The only re-scan in the app was the per-environment one under Environments,
/// which is not where anyone looks for their agents.
///
/// The result line is the point of the control, not a nicety. It names the
/// agents that were **not** found and the environments that could not be
/// reached, because "detection finished" is not an answer to "where is my
/// Codex" — and this codebase has already shipped one operation that reported
/// success while writing nothing.
class AgentDetectionSection extends ConsumerWidget {
  const AgentDetectionSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(agentRedetectControllerProvider);

    return SettingsSection(
      title: 'DETECTION',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: state.busy
                  ? null
                  : () => ref
                        .read(agentRedetectControllerProvider.notifier)
                        .redetect(),
              icon: state.busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(AppIcons.arrowsClockwise, size: 16),
              label: const Text('Detect agents'),
            ),
          ),
          const SizedBox(height: Insets.xs),
          if (state.error != null)
            DesktopErrorBanner(state.error!)
          else
            Text(
              state.report == null
                  ? 'Not scanned yet in this session. Run this after '
                        'installing or removing an agent CLI.'
                  : state.report!.summary,
              style: theme.textTheme.bodySmall,
            ),
          ?_details(context, state.report),
        ],
      ),
    );
  }

  /// The per-environment breakdown, shown only once there is one to show.
  Widget? _details(BuildContext context, AgentDiscoveryReport? report) {
    if (report == null || report.environments.isEmpty) return null;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final environment in report.environments)
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
        ],
      ),
    );
  }

  static String _installed(EnvironmentScanReport environment) =>
      environment.found.isEmpty
      ? 'no agents'
      : environment.found
            .map((i) => '${i.agentId}${i.version == null ? '' : ' ${i.version}'}')
            .join(', ');
}
