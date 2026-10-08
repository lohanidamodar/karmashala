import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_context.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_working_directory.dart';
import '../application/agent_context_readings.dart';
import '../application/agent_providers.dart';
import 'package:agent_cli/context.dart';

/// The agent, environment and directory a reading needs, or null when the
/// session on screen does not name all three.
final agentContextTargetProvider = Provider<AgentContextTarget?>((ref) {
  final sessionId = ref.watch(panelSessionIdProvider);
  if (sessionId == null) return null;
  final session = ref.watch(sessionsDataProvider).getById(sessionId);
  if (session == null) return null;
  final agentId = ref
      .watch(agentInstallationsDataProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  final directory = sessionWorkingDirectoryOf(ref, session);
  if (agentId == null || directory == null) return null;
  return AgentContextTarget(
    agentId: agentId,
    environmentId: directory.environmentId,
    directory: directory.path,
  );
});

/// **What a session started here would be given** — the MCP servers and skills
/// the agent's own configuration names, each row saying which file it came
/// from and which of them Karmashala put there.
///
/// Never what a *running* session has: the CLI binds its servers at start-up
/// and owns those processes (§19). The wording throughout is the conditional
/// one on purpose.
class AgentContextPanel extends ConsumerStatefulWidget {
  const AgentContextPanel({super.key});

  @override
  ConsumerState<AgentContextPanel> createState() => _AgentContextPanelState();
}

class _AgentContextPanelState extends ConsumerState<AgentContextPanel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _readIfUnread());
  }

  Future<void> _readIfUnread() async {
    if (!mounted) return;
    final target = ref.read(agentContextTargetProvider);
    if (target == null) return;
    if (ref.read(agentContextReadingsProvider.notifier).cached(target) !=
        null) {
      return;
    }
    await readAgentContext(ProviderScope.containerOf(context), target);
  }

  @override
  Widget build(BuildContext context) {
    // A different session on screen is a different set of files to read.
    ref.listen<AgentContextTarget?>(agentContextTargetProvider, (_, next) {
      if (next != null) _readIfUnread();
    });
    final target = ref.watch(agentContextTargetProvider);
    if (target == null) {
      return const PanePlaceholder(
        message:
            'Open a session to see the MCP servers and skills a session '
            'started in its directory would be given.',
        icon: AppIcons.robot,
      );
    }
    ref.watch(agentContextReadingsProvider);
    final reading = ref
        .read(agentContextReadingsProvider.notifier)
        .cached(target);
    final running = ref
        .watch(agentContextReadsRunningProvider)
        .contains(target.key);

    return ListView(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      children: [
        _Scope(target: target, reading: reading, running: running),
        if (reading == null)
          const _Message('Nothing has been read yet.')
        else if (!reading.wasRead)
          _Message(_absenceOf(reading))
        else ...[
          _Section(
            title: 'MCP SERVERS',
            entries: reading.mcpServers,
            empty:
                'None. A session here would have only what Karmashala adds to '
                'the launch.',
          ),
          _Section(
            title: 'SKILLS',
            entries: reading.skills,
            empty: 'None in the places this agent looks.',
          ),
        ],
        for (final note in reading?.notes ?? const <String>[]) _Message(note),
      ],
    );
  }

  String _absenceOf(AgentContextReading reading) {
    if (reading.refusal.isNotEmpty) return reading.refusal;
    return switch (reading.absence) {
      AgentContextAbsence.noSession => 'No session is on screen.',
      AgentContextAbsence.agentUndeclared =>
        'Nobody has established where this agent keeps its configuration, so '
            'it has not been read.',
      AgentContextAbsence.environmentNotReadable =>
        'This directory is on a machine whose files are not read from here.',
      AgentContextAbsence.notRead || null => 'Nothing has been read yet.',
    };
  }
}

/// What the reading is *about*, and how old it is. Both, always: a list with
/// neither is a claim about a session nobody named.
class _Scope extends ConsumerWidget {
  const _Scope({
    required this.target,
    required this.reading,
    required this.running,
  });

  final AgentContextTarget target;
  final AgentContextReading? reading;
  final bool running;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final agent =
        ref.watch(agentRegistryProvider).byId(target.agentId)?.displayName ??
        target.agentId;
    final readAt = reading?.readAt;
    final now = ref.watch(clockProvider).nowUtc();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.md,
        Insets.md,
        Insets.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The conditional, not "what this session has". The app cannot know
          // what a running CLI bound, and a row claiming it would be §19's
          // confident false statement in a new place.
          Text(
            'What a $agent session started in this directory would be given.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.xs),
          Text(
            target.directory,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  running
                      ? 'reading…'
                      : readAt == null
                      ? 'not read yet'
                      : 'read ${describeAge(now.difference(readAt))}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: running
                    ? null
                    : () => readAgentContext(
                        ProviderScope.containerOf(context),
                        target,
                        force: true,
                      ),
                icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
                label: Text(readAt == null ? 'Read' : 'Read again'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.entries,
    required this.empty,
  });

  final String title;
  final List<AgentContextEntry> entries;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.sm,
            Insets.md,
            Insets.xs,
          ),
          child: Text(
            title,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (entries.isEmpty)
          _Message(empty)
        else
          for (final entry in entries) _EntryRow(entry: entry),
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry});

  final AgentContextEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final ours = entry.origin == AgentContextOrigin.karmashala;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Insets.xxs),
            child: Icon(
              switch (entry.standing) {
                AgentContextStanding.taken => AppIcons.checkCircle,
                AgentContextStanding.awaitingApproval => AppIcons.question,
                AgentContextStanding.refused => AppIcons.minusCircle,
              },
              size: Chrome.icon,
              color: switch (entry.standing) {
                AgentContextStanding.taken =>
                  ours ? scheme.primary : semantic.idle,
                AgentContextStanding.awaitingApproval => semantic.attention,
                AgentContextStanding.refused => scheme.onSurfaceVariant,
              },
            ),
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (entry.detail case final String detail)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                // **Provenance is the point.** Karmashala's own entries say so;
                // everything else names the file the user would edit.
                Text(
                  describeProvenance(entry),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: ours ? scheme.primary : scheme.onSurfaceVariant,
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

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.xs),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
