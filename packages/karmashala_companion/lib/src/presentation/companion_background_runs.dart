import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/companion_providers.dart';

/// **The background runs a session is waiting on**, above the phone's
/// composer: each agent or command it left running, how long it has run, and
/// how those that finished alongside them ended. Nothing while none runs.
class CompanionBackgroundRuns extends ConsumerStatefulWidget {
  const CompanionBackgroundRuns({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<CompanionBackgroundRuns> createState() =>
      _CompanionBackgroundRunsState();
}

class _CompanionBackgroundRunsState
    extends ConsumerState<CompanionBackgroundRuns> {
  Timer? _tick;
  ProviderSubscription<AsyncValue<CompanionActivity>>? _activity;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(CompanionBackgroundRuns oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) _listen();
  }

  @override
  void dispose() {
    _activity?.close();
    _tick?.cancel();
    super.dispose();
  }

  /// The clock runs exactly while a run does, decided as each reading lands.
  void _listen() {
    _activity?.close();
    _activity = ref.listenManual(
      companionActivityProvider(widget.sessionId),
      (_, next) {
        final running =
            next.asData?.value.background.any((run) => run.isRunning) ?? false;
        if (running) {
          _tick ??= Timer.periodic(kActivityTickInterval, (_) {
            if (mounted) setState(() {});
          });
        } else {
          _tick?.cancel();
          _tick = null;
        }
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final reading = ref
        .watch(companionActivityProvider(widget.sessionId))
        .asData
        ?.value;
    final runs = reading?.background ?? const <CompanionBackgroundRun>[];
    if (reading == null || runs.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // The host's reading plus what has passed here since.
    final since = DateTime.now().difference(reading.at);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_heading(runs), style: muted),
          for (final run in runs)
            _RunLine(run: run, since: since.isNegative ? Duration.zero : since),
        ],
      ),
    );
  }

  static String _heading(List<CompanionBackgroundRun> runs) {
    var agents = 0;
    var commands = 0;
    for (final run in runs) {
      if (!run.isRunning) continue;
      if (run.agent) {
        agents++;
      } else {
        commands++;
      }
    }
    String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
    if (commands == 0) return '${count(agents, 'background agent')} running';
    if (agents == 0) return '${count(commands, 'background command')} running';
    return '${count(agents, 'agent')} and ${count(commands, 'command')} '
        'running in the background';
  }
}

class _RunLine extends StatelessWidget {
  const _RunLine({required this.run, required this.since});

  final CompanionBackgroundRun run;
  final Duration since;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final word = switch (run.state) {
      'running' => 'running',
      'completed' => 'done',
      'failed' => 'failed',
      'killed' => 'stopped',
      'ended' => 'ended',
      final other => other,
    };
    final elapsed = run.elapsed;
    final shown = elapsed == null
        ? null
        : run.isRunning
        ? elapsed + since
        : elapsed;
    final Widget mark = switch (run.state) {
      'running' => WorkingSpinner(
        size: Chrome.iconSmall,
        color: SemanticColors.of(context).working,
      ),
      'completed' => Icon(
        AppIcons.check,
        size: Chrome.iconSmall,
        color: scheme.onSurfaceVariant,
      ),
      _ => Icon(AppIcons.x, size: Chrome.iconSmall, color: scheme.error),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.hair),
      child: Row(
        children: [
          mark,
          const SizedBox(width: Insets.sm),
          Icon(
            run.agent ? AppIcons.robot : AppIcons.terminal,
            size: Chrome.iconSmall,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              run.description ?? (run.agent ? 'Agent' : 'Command'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Text(
            shown == null ? word : '$word · ${formatElapsed(shown)}',
            maxLines: 1,
            style: muted,
          ),
        ],
      ),
    );
  }
}
