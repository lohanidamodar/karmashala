import 'dart:async';

import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/clock_provider.dart';
import '../../cli_detection/presentation/subagent_turns_tile.dart';
import '../application/background_runs_providers.dart';

/// More rows than this and the strip starts folded to its summary.
const kUnfoldedRunsMax = 3;

/// How long a finished run stays listed; after that it is only counted.
const kFinishedRunLingers = Duration(minutes: 5);

/// **The background runs a session is waiting on**, above its composer: each
/// agent or command it left running, how long it has run, and how the ones
/// that finished lately ended. An agent opens to its own turns. Nothing at all
/// while nothing runs. Placed in a [Flexible]: unfolded, its rows scroll.
class BackgroundRunsStrip extends ConsumerStatefulWidget {
  const BackgroundRunsStrip({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<BackgroundRunsStrip> createState() =>
      _BackgroundRunsStripState();
}

class _BackgroundRunsStripState extends ConsumerState<BackgroundRunsStrip> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    _tick = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runs = ref.watch(sessionBackgroundRunsProvider(widget.sessionId));
    if (runs.isEmpty || !Visibility.of(context)) {
      _tick?.cancel();
      _tick = null;
      if (runs.isEmpty) return const SizedBox.shrink();
    } else {
      _tick ??= Timer.periodic(kActivityTickInterval, (_) => setState(() {}));
    }
    final now = ref.read(clockProvider).nowUtc();
    final byAgentId = ref.watch(
      capabilitiesProvider.select((c) => c.subagentByAgentId),
    );
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    bool lingers(BackgroundRun run) {
      final ended = run.endedAt;
      return ended != null && now.difference(ended) < kFinishedRunLingers;
    }

    final listed = [
      for (final entry in runs)
        if (entry.run.state.isRunning || lingers(entry.run)) entry,
    ];
    final done = runs.where((entry) => !entry.run.state.isRunning).length;
    final folded =
        ref.watch(
          backgroundRunsFoldedProvider.select((all) => all[widget.sessionId]),
        ) ??
        listed.length > kUnfoldedRunsMax;
    final strip = Padding(
      padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => ref
                .read(backgroundRunsFoldedProvider.notifier)
                .set(widget.sessionId, folded: !folded),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    _heading(runs),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ),
                if (done > 0) ...[
                  Text(' · ', style: muted),
                  Text('$done done', maxLines: 1, style: muted),
                ],
                const SizedBox(width: Insets.xs),
                Icon(
                  folded ? AppIcons.caretUp : AppIcons.caretDown,
                  size: Chrome.iconSmall,
                  color: theme.colorScheme.onSurfaceVariant,
                  semanticLabel: folded ? 'Show runs' : 'Hide runs',
                ),
              ],
            ),
          ),
          if (!folded)
            Flexible(
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in listed)
                      _RunRow(
                        entry: entry,
                        now: now,
                        sessionId: widget.sessionId,
                        byAgentId: byAgentId,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    // Never more than a third of the view, and within what the composer
    // leaves: 21 rows once hid the composer on a phone.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height / 3,
      ),
      child: strip,
    );
  }

  static String _heading(List<SessionBackgroundRun> runs) {
    var agents = 0;
    var commands = 0;
    for (final entry in runs) {
      if (!entry.run.state.isRunning) continue;
      if (entry.run.kind == BackgroundRunKind.agent) {
        agents++;
      } else {
        commands++;
      }
    }
    String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
    if (commands == 0) {
      return '${count(agents, 'background agent')} running';
    }
    if (agents == 0) {
      return '${count(commands, 'background command')} running';
    }
    return '${count(agents, 'agent')} and ${count(commands, 'command')} '
        'running in the background';
  }
}

/// How a run's row names where it stands. A run that is over with no end
/// recorded (its process went away unsaid) is never called running.
String backgroundRunStateWord(BackgroundRunState state) => switch (state) {
  BackgroundRunState.running => 'running',
  BackgroundRunState.completed => 'done',
  BackgroundRunState.failed => 'failed',
  BackgroundRunState.killed => 'stopped',
  BackgroundRunState.ended => 'not recorded',
};

class _RunRow extends StatelessWidget {
  const _RunRow({
    required this.entry,
    required this.now,
    required this.sessionId,
    required this.byAgentId,
  });

  final SessionBackgroundRun entry;
  final DateTime now;
  final String sessionId;

  /// The server reads an agent's turns by its id, so an agent whose row
  /// names no file still opens.
  final bool byAgentId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final run = entry.run;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final elapsed = entry.elapsedAt(now);
    final state = backgroundRunStateWord(run.state);
    final trailing = elapsed == null
        ? state
        : '$state · ${formatElapsed(elapsed)}';
    final Widget mark = switch (run.state) {
      BackgroundRunState.running => WorkingSpinner(
        size: Chrome.iconSmall,
        color: semantic.working,
      ),
      BackgroundRunState.completed => Icon(
        AppIcons.check,
        size: Chrome.iconSmall,
        color: scheme.onSurfaceVariant,
      ),
      _ => Icon(AppIcons.x, size: Chrome.iconSmall, color: scheme.error),
    };
    final subagent = entry.subagent;
    final title = backgroundRunTitle(run);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.hair),
      child: Row(
        children: [
          mark,
          const SizedBox(width: Insets.sm),
          Icon(
            run.kind == BackgroundRunKind.agent
                ? AppIcons.robot
                : AppIcons.terminal,
            size: Chrome.iconSmall,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Text(trailing, maxLines: 1, style: muted),
        ],
      ),
    );
    final summary = run.summary;
    final described = summary == null
        ? row
        : Tooltip(message: summary, child: row);
    // An agent whose row names no file is asked for by its own id.
    final byId =
        subagent == null && byAgentId && run.kind == BackgroundRunKind.agent;
    if (subagent == null && !byId) return described;
    return InkWell(
      onTap: () => showAdaptiveModal<void>(
        context: context,
        title: title,
        heightFactor: 0.8,
        builder: (_) => SingleChildScrollView(
          child: SubagentTurnsTile(
            reference:
                subagent ??
                SubagentRef(
                  toolUseId: run.id,
                  filePath: '',
                  agentType: '',
                  description: title,
                  spawnDepth: 1,
                ),
            sessionId: sessionId,
            agentId: byId ? run.id : null,
            initiallyExpanded: true,
          ),
        ),
      ),
      child: described,
    );
  }
}
