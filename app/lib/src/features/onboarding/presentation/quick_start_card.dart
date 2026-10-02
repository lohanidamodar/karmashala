import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/shell_area.dart';
import '../../../app/shell/shell_shortcuts.dart';
import '../../../app/shell/side_panel_state.dart';
import '../../../app/shell/workbench_tabs.dart' show openSettingsTab;
import '../../agents/application/agent_redetect_controller.dart';
import '../../environments/application/environment_health.dart';
import '../../environments/application/system_health_service.dart';
import '../../environments/presentation/environment_health_dialog.dart';
import '../../explorer/presentation/sidebar_chrome.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../ssh/presentation/copyable_command.dart';
import '../application/quick_start.dart';
import 'keyboard_map.dart';

/// What the palette command is called, so the card's closing line names it.
const kQuickStartCommandLabel = 'Quick start';

/// Opens the quick start in the sidebar — the palette's "Quick start". Picks
/// the Sessions area when the sidebar shows Devices, which has no room for it.
void showQuickStart(WidgetRef ref) {
  ref.read(quickStartProvider.notifier).reopen();
  final area = ref.read(shellAreaProvider);
  showShellArea(ref, area == ShellArea.devices ? ShellArea.sessions : area);
}

/// **The quick start**: a card at the foot of the sidebar,
/// beside the terminal rather than over it. It takes no focus when it appears;
/// every row is a link to the real control, and a step is ticked only once
/// the thing exists.
class QuickStartCard extends ConsumerWidget {
  const QuickStartCard({required this.maxHeight, super.key});

  /// Beside the list, never instead of it: the body scrolls past this.
  final double maxHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(quickStartProvider);
    if (!state.shown) return const SizedBox.shrink();
    final folded = ref.watch(quickStartFoldedProvider);
    final tones = SurfaceTones.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(Insets.sm, 0, Insets.sm, Insets.sm),
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: tones.raised,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Semantics(
        container: true,
        label: 'Quick start',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(state: state, folded: folded),
            if (!folded)
              const Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    Insets.xs,
                    0,
                    Insets.xs,
                    Insets.sm,
                  ),
                  child: _Body(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.state, required this.folded});

  final QuickStartState state;
  final bool folded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final count = state.done.length;
    final total = QuickStartStep.values.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sidebar.labelPadX, 2, 2, 0),
      child: Row(
        children: [
          Icon(
            AppIcons.rocketLaunch,
            size: Chrome.iconSmall,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              'QUICK START',
              style: Sidebar.groupLabelStyle.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            state.allDone ? 'All done' : '$count of $total done',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: folded ? 'Show the quick start' : 'Fold the quick start',
            icon: Icon(
              folded ? AppIcons.caretUp : AppIcons.caretDown,
              size: Chrome.iconSmall,
            ),
            onPressed: () =>
                ref.read(quickStartFoldedProvider.notifier).toggle(),
          ),
        ],
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(quickStartProvider);
    final preflight = ref.watch(preflightProvider);
    final checking = preflight.checking;
    final agentsNote = preflight.foundAgents.isNotEmpty
        ? 'Found: ${preflight.foundAgents.join(', ')}.'
        : preflight.findingAgents
        ? 'Looking for agent CLIs in each environment…'
        : 'No agent CLI found yet — see This machine below.';
    void invoke(Intent intent) => Actions.maybeInvoke(context, intent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepRow(
          step: QuickStartStep.machine,
          done: state.isDone(QuickStartStep.machine),
          note: checking
              ? 'Checking now…'
              : preflight.checked
              ? 'Checked — see This machine below.'
              : 'Read-only: git, agent CLIs, WSL.',
          busy: checking,
          onTap: checking
              ? null
              : () => unawaited(
                  ref.read(systemHealthProvider.notifier).refresh(),
                ),
        ),
        _StepRow(
          step: QuickStartStep.project,
          done: state.isDone(QuickStartStep.project),
          note: 'A folder, a clone or a new app.',
          keys: shellCommandLabel('project.new'),
          onTap: () => invoke(const NewProjectIntent()),
        ),
        _StepRow(
          step: QuickStartStep.session,
          done: state.isDone(QuickStartStep.session),
          note: agentsNote,
          keys: shellCommandLabel('session.new'),
          onTap: () => invoke(const NewSessionIntent()),
        ),
        _StepRow(
          step: QuickStartStep.phone,
          done: state.isDone(QuickStartStep.phone),
          note: 'Optional. Answer asks from your phone.',
          onTap: () =>
              openSettingsTab(ref, anchor: SettingsAnchor.remoteAccess),
        ),
        const _GroupLabel('Where things are'),
        _TipRow(
          icon: AppIcons.warningCircle,
          title: 'Needs you',
          note:
              'An agent waiting on you shows under Needs you in Sessions, '
              'and in the Inbox.',
          keys: shellCommandLabel('attention.nextWaiting'),
          action: 'Inbox',
          onTap: () => showShellArea(ref, ShellArea.inbox),
        ),
        _TipRow(
          icon: AppIcons.sidebarSimple,
          title: 'Context panel',
          note: ContextTab.values.map((t) => t.label).join(' · '),
          keys: shellCommandLabel('view.toggleSidePanel'),
          action: 'Open',
          onTap: () =>
              ref.read(sidePanelProvider.notifier).showTab(ContextTab.changes),
        ),
        const _GroupLabel('Keys'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Sidebar.labelPadX),
          child: KeyboardMap(),
        ),
        const _GroupLabel('This machine'),
        const _MachineReview(),
        const SizedBox(height: Insets.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              final messenger = ScaffoldMessenger.maybeOf(context);
              final palette = shellCommandLabel('quickOpen.commands');
              ref.read(quickStartProvider.notifier).dismiss();
              messenger?.showSnackBar(
                SnackBar(
                  content: Text(
                    'Quick start closed. Reopen it from the command palette'
                    '${palette == null ? '' : ' ($palette)'}: '
                    '$kQuickStartCommandLabel.',
                  ),
                ),
              );
            },
            child: Text(state.allDone ? 'Close' : 'Don’t show again'),
          ),
        ),
      ],
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      Sidebar.labelPadX,
      Insets.md,
      Sidebar.labelPadX,
      Insets.xs,
    ),
    child: Semantics(
      header: true,
      child: Text(
        text.toUpperCase(),
        style: Sidebar.groupLabelStyle.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

/// One step: its mark, its name, what it involves, and the keys for it. The
/// whole row is the link; the mark's shape — not only its colour — says done.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.done,
    required this.note,
    required this.onTap,
    this.keys,
    this.busy = false,
  });

  final QuickStartStep step;
  final bool done;
  final String note;
  final String? keys;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Semantics(
      button: true,
      label: '${step.label}, ${done ? 'done' : 'not done yet'}. $note',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.xs + 2,
            vertical: Insets.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: Chrome.icon,
                height: Chrome.icon + 2,
                child: Center(
                  child: busy
                      ? const InlineSpinner()
                      : Icon(
                          done ? AppIcons.checkCircle : AppIcons.circle,
                          size: Chrome.icon,
                          color: done ? semantic.idle : semantic.neutral,
                        ),
                ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            step.label,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: done
                                  ? FontWeight.normal
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        if (keys case final keys?)
                          Text(keys, style: MonoStyles.small),
                      ],
                    ),
                    Text(note, style: muted),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where something lives, and one link to it. Not a step: looking at the
/// Inbox is not the same as having answered an ask.
class _TipRow extends StatelessWidget {
  const _TipRow({
    required this.icon,
    required this.title,
    required this.note,
    required this.action,
    required this.onTap,
    this.keys,
  });

  final IconData icon;
  final String title;
  final String note;
  final String action;
  final String? keys;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xs + 2,
        vertical: 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              icon,
              size: Chrome.icon,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  keys == null ? title : '$title  ·  $keys',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(note, style: muted),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: onTap,
            child: Text(action),
          ),
        ],
      ),
    );
  }
}

/// The first-run preflight's review: per environment, whether git answered and
/// which agent CLIs were found; then what is missing and the line that
/// installs it — to copy. Nothing is installed from here.
class _MachineReview extends ConsumerWidget {
  const _MachineReview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preflight = ref.watch(preflightProvider);
    final redetect = ref.watch(agentRedetectControllerProvider);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Neither probe can say how far along it is, so each says what it
          // is doing rather than drawing a bar.
          if (preflight.checking)
            _Doing(text: Preflight.checkingWhat, style: muted),
          if (preflight.findingAgents || redetect.busy)
            _Doing(
              text: 'Looking for agent CLIs in each environment (read-only).',
              style: muted,
            ),
          if (preflight.environments.isEmpty)
            Text('No environment recorded yet.', style: muted),
          for (final environment in preflight.environments)
            _EnvironmentLine(environment: environment),
          if (preflight.checked && preflight.gaps.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            Text('Missing', style: theme.textTheme.labelMedium),
            for (final gap in preflight.gaps) _GapLine(gap: gap),
          ],
          if (preflight.checked && preflight.otherIssues > 0)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                '${preflight.otherIssues} other check'
                '${preflight.otherIssues == 1 ? '' : 's'} need a look — '
                'see Details.',
                style: muted,
              ),
            ),
          if (!preflight.checked && !preflight.checking)
            Text(
              'Not checked yet. Nothing here is a claim that anything works.',
              style: muted,
            ),
          const SizedBox(height: Insets.xs),
          Text(
            'Nothing is installed from here: copy a line and run it yourself.',
            style: muted,
          ),
          Wrap(
            spacing: Insets.xs,
            children: [
              TextButton(
                onPressed: preflight.checking
                    ? null
                    : () => unawaited(
                        ref.read(systemHealthProvider.notifier).refresh(),
                      ),
                child: Text(preflight.checked ? 'Check again' : 'Check now'),
              ),
              TextButton(
                onPressed: redetect.busy
                    ? null
                    : () => unawaited(
                        ref
                            .read(agentRedetectControllerProvider.notifier)
                            .redetect(),
                      ),
                child: const Text('Find agents again'),
              ),
              TextButton(
                onPressed: () => EnvironmentHealthDialog.show(context),
                child: const Text('Details'),
              ),
            ],
          ),
          if (redetect.message case final message?) Text(message, style: muted),
        ],
      ),
    );
  }
}

class _Doing extends StatelessWidget {
  const _Doing({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Insets.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(padding: EdgeInsets.only(top: 2), child: InlineSpinner()),
        const SizedBox(width: Insets.xs),
        Expanded(
          child: Semantics(liveRegion: true, child: Text(text, style: style)),
        ),
      ],
    ),
  );
}

class _EnvironmentLine extends StatelessWidget {
  const _EnvironmentLine({required this.environment});

  final PreflightEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final git = switch (environment.git) {
      HealthLevel.healthy => environment.gitVersion ?? 'git found',
      HealthLevel.failed => 'git not found',
      _ => 'git not checked',
    };
    final agents = environment.agents.isEmpty
        ? 'no agent CLI'
        : environment.agents.join(', ');
    final kind = environment.isWsl ? 'WSL · ' : '';
    return Semantics(
      label:
          '${environment.name}: $git; $agents. '
          '${_levelWord(environment.git)}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                healthIcon(environment.git),
                size: Chrome.iconSmall,
                color: healthColor(context, environment.git),
              ),
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$kind${environment.name}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text('$git · $agents', style: MonoStyles.small),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _levelWord(HealthLevel level) => switch (level) {
    HealthLevel.healthy => 'git answered',
    HealthLevel.failed => 'git failed',
    _ => 'not checked',
  };
}

class _GapLine extends StatelessWidget {
  const _GapLine({required this.gap});

  final PreflightGap gap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final level = gap.optional ? HealthLevel.unknown : HealthLevel.warning;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              gap.optional ? AppIcons.info : AppIcons.warningCircle,
              size: Chrome.iconSmall,
              color: gap.optional
                  ? semantic.neutral
                  : healthColor(context, level),
            ),
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  gap.optional ? '${gap.title} (optional)' : gap.title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(gap.summary, style: theme.textTheme.bodySmall),
                if (gap.command case final command?)
                  CopyableCommand(command: command),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
