import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_mcp_entry_service.dart';
import '../../agents/application/agent_providers.dart';
import '../../environments/application/environment_health.dart'
    show HealthLevel;
import '../../environments/application/environments_controller.dart';
import '../../environments/presentation/environment_health_dialog.dart'
    show healthColor, healthIcon;
import '../application/settings_controller.dart';
import 'settings_notice.dart';
import 'settings_section.dart';

/// Settings → Agents and accounts → Karmashala in agent configs: the entry
/// Karmashala keeps in the MCP file of an agent that takes no server for one
/// launch, with the one control that matters — take it out, or put it back.
class AgentMcpEntrySection extends ConsumerWidget {
  const AgentMcpEntrySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final report = ref.watch(agentMcpEntryReportProvider);
    final on = ref.watch(
      settingsControllerProvider.select((s) => s.agentMcpEntries),
    );
    final registry = ref.watch(agentRegistryProvider);
    final service = ref.read(agentMcpEntryServiceProvider);
    return SettingsSection(
      // Upper-cased like every anchored section's heading beside it.
      title: 'Karmashala in agent configs'.toUpperCase(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'agy cannot be handed Karmashala\'s tools for one session, so '
            'Karmashala keeps an entry in its own MCP file. The entry serves '
            'only sessions Karmashala started; your other servers stay as '
            'they are.',
          ),
          SettingsRuled(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!report.swept)
                  Text(
                    'Not read yet — that runs just after the window opens.',
                    style: theme.textTheme.bodySmall,
                  )
                else if (report.entries.isEmpty)
                  Text(
                    'No agent here needs one.',
                    style: theme.textTheme.bodySmall,
                  )
                else
                  for (final entry in report.entries)
                    _EntryRow(
                      key: ValueKey(
                        'mcp-entry-${entry.agentId}-${entry.environmentId}',
                      ),
                      entry: entry,
                      agent: registry.displayNameFor(entry.agentId),
                      environment: ref.watch(
                        environmentLabelForIdProvider(entry.environmentId),
                      ),
                    ),
                if (report.checkedAt case final at?)
                  Text(
                    'Read ${describeAge(ref.read(clockProvider).nowUtc().difference(at))}.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: Insets.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: on
                      ? TextButton.icon(
                          key: const ValueKey('mcp-entry-remove'),
                          onPressed: service.removeAll,
                          icon: const Icon(AppIcons.trash, size: Chrome.icon),
                          label: const Text('Remove it'),
                        )
                      : TextButton.icon(
                          key: const ValueKey('mcp-entry-restore'),
                          onPressed: service.restore,
                          icon: const Icon(AppIcons.plus, size: Chrome.icon),
                          label: const Text('Add it back'),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.entry,
    required this.agent,
    required this.environment,
  });

  final AgentMcpEntry entry;
  final String agent;
  final String environment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (level, words) = switch (entry.state) {
      KarmashalaMcpEntryState.current => (HealthLevel.healthy, 'Present'),
      KarmashalaMcpEntryState.stale => (
        HealthLevel.warning,
        'Present, from another install',
      ),
      KarmashalaMcpEntryState.foreign => (
        HealthLevel.warning,
        'Your own "karmashala" entry, left alone',
      ),
      KarmashalaMcpEntryState.absent => (HealthLevel.unknown, 'Not present'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                level == HealthLevel.healthy
                    ? AppIcons.checkCircle
                    : healthIcon(level),
                size: Chrome.icon,
                color: healthColor(context, level),
              ),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  '$words for $agent in $environment'
                  '${entry.path == null ? '' : ' — ${entry.path}'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (entry.problem case final problem?)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: SettingsNotice(
                tone: SettingsNoticeTone.neutral,
                message: 'Not written — $problem.',
              ),
            ),
        ],
      ),
    );
  }
}
