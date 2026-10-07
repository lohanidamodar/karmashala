import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart' show phoneWorkbenchOpener;
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../terminal/presentation/session_status.dart' show describeAge;
import '../application/automation_providers.dart';
import 'automation_run_actions.dart';
import '../application/automation_runs_page.dart';
import 'automation_run_status.dart';
import 'automation_undo_dialog.dart';

/// **Runs**: every run across every automation, newest first, filtered and
/// paged; each opens to its steps, its checks and what can be done about it.
class AutomationRunsView extends ConsumerWidget {
  const AutomationRunsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(runsFilterProvider);
    final all = ref.watch(shownRunsProvider);
    final page = ref.watch(olderRunsProvider);
    final automations = ref.watch(automationsProvider);
    final data = ref.read(automationsDataProvider);
    List<AutomationCheckVerdict> checksOf(AutomationRun run) =>
        page.checks[run.id] ?? data.checksFor(run.id);
    final failed = all
        .where((r) => runOutcome(r, checksOf(r)) == RunOutcome.failed)
        .length;
    final live = all.where((r) => r.state.isLive).length;
    final runs = [
      for (final run in all)
        if (switch (filter.shown) {
          RunsShown.all => true,
          RunsShown.failed =>
            runOutcome(run, checksOf(run)) == RunOutcome.failed,
          RunsShown.running => run.state.isLive,
        })
          run,
    ];
    final named = automations
        .where((a) => a.id == filter.automationId)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.sm,
            Insets.sm,
            Insets.xs,
          ),
          child: Wrap(
            spacing: Touch.gap,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              CompactSegmented<RunsShown>(
                key: const ValueKey('runs-shown'),
                segments: [
                  const ButtonSegment(value: RunsShown.all, label: Text('All')),
                  ButtonSegment(
                    value: RunsShown.failed,
                    label: Text('Failed · $failed'),
                  ),
                  ButtonSegment(
                    value: RunsShown.running,
                    label: Text('Running · $live'),
                  ),
                ],
                selected: filter.shown,
                onChanged: ref.read(runsFilterProvider.notifier).show,
              ),
              _AutomationFilter(automations: automations, selected: named),
              if (named != null)
                InputChip(
                  key: const ValueKey('runs-automation-chip'),
                  label: Text(named.name),
                  onDeleted: () =>
                      ref.read(runsFilterProvider.notifier).only(null),
                ),
            ],
          ),
        ),
        Expanded(
          child: runs.isEmpty
              ? const PanePlaceholder(
                  icon: AppIcons.lightning,
                  message: 'No runs match.',
                )
              : LayoutBuilder(
                  builder: (context, constraints) => _RunsColumns(
                    on: WidthClass.of(
                      constraints.maxWidth < Chrome.readableWidth
                          ? constraints.maxWidth
                          : Chrome.readableWidth,
                      textScaler: MediaQuery.textScalerOf(context),
                    ).isExpanded,
                    child: ListView.builder(
                      key: const ValueKey('runs-list'),
                      padding: const EdgeInsets.only(bottom: Insets.lg),
                      itemCount: runs.length + 2,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return runsInColumns(context)
                              ? Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: Chrome.readableWidth,
                                    ),
                                    child: const _RunsHeader(),
                                  ),
                                )
                              : const SizedBox.shrink();
                        }
                        if (index == runs.length + 1) {
                          return const _OlderButton();
                        }
                        final run = runs[index - 1];
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: Chrome.readableWidth,
                            ),
                            child: RunTile(
                              key: ValueKey(run.id),
                              run: run,
                              checks: checksOf(run),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _AutomationFilter extends ConsumerWidget {
  const _AutomationFilter({required this.automations, required this.selected});

  final List<Automation> automations;
  final Automation? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Builder(
    builder: (context) => FilterFunnelButton(
      key: const ValueKey('runs-automation-filter'),
      count: selected == null ? 0 : 1,
      onPressed: () async {
        final box = context.findRenderObject()! as RenderBox;
        final at = box.localToGlobal(box.size.bottomLeft(Offset.zero));
        final picked = await showMenu<String>(
          context: context,
          position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
          items: [
            const PopupMenuItem(value: '', child: Text('Every automation')),
            for (final a in automations)
              PopupMenuItem(value: a.id, child: Text(a.name)),
          ],
        );
        if (picked == null) return;
        ref
            .read(runsFilterProvider.notifier)
            .only(picked.isEmpty ? null : picked);
      },
    ),
  );
}

class _OlderButton extends ConsumerWidget {
  const _OlderButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(olderRunsProvider);
    final bool more = page.more ?? ref.watch(runsCopyTruncatedProvider);
    if (!more) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(Insets.md),
      child: Center(
        child: page.loading
            ? const InlineSpinner(semanticsLabel: 'Reading older runs')
            : TextButton(
                key: const ValueKey('runs-older'),
                onPressed: () =>
                    ref.read(olderRunsProvider.notifier).loadMore(),
                child: const Text('Show older runs'),
              ),
      ),
    );
  }
}

/// Whether Runs is wide enough for its columns, as the list was measured.
bool runsInColumns(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_RunsColumns>()?.on ?? false;

/// Whether the rows below draw columns: only at the expanded width class of
/// the room the list was given, read at the text scale.
class _RunsColumns extends InheritedWidget {
  const _RunsColumns({required this.on, required super.child});

  final bool on;

  @override
  bool updateShouldNotify(_RunsColumns oldWidget) => oldWidget.on != on;
}

const _resultWidth = Touch.target * 2.5;
const _causeWidth = Touch.target * 2;
const _whenWidth = Touch.target * 2;
const _tookWidth = Touch.target * 1.5;

class _Cell extends StatelessWidget {
  const _Cell({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: DefaultTextStyle.merge(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: child,
    ),
  );
}

/// The column names over the rows, where there are columns.
class _RunsHeader extends StatelessWidget {
  const _RunsHeader();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(
      Insets.lg + Touch.iconSmall + Insets.sm,
      Insets.sm,
      Insets.lg,
      Insets.xs,
    ),
    child: Row(
      children: [
        Expanded(child: EyebrowLabel('Automation')),
        SizedBox(width: Insets.sm),
        _Cell(width: _resultWidth, child: EyebrowLabel('Result')),
        _Cell(width: _causeWidth, child: EyebrowLabel('Started by')),
        _Cell(width: _whenWidth, child: EyebrowLabel('When')),
        _Cell(width: _tookWidth, child: EyebrowLabel('Took')),
      ],
    ),
  );
}

/// What started [run], read off its automation when it was not recorded.
AutomationRunCause runCause(AutomationRun run, Automation? automation) =>
    run.startedBy ??
    (automation?.isWebhook ?? false
        ? AutomationRunCause.webhook
        : run.eventSessionId != null
        ? AutomationRunCause.event
        : AutomationRunCause.schedule);

/// "3m 12s", "1h 4m", "running".
String tookWords(AutomationRun run) {
  final took = run.duration;
  if (took == null) return run.state.isLive ? 'running' : '—';
  if (took.inHours > 0) return '${took.inHours}h ${took.inMinutes % 60}m';
  if (took.inMinutes > 0) return '${took.inMinutes}m ${took.inSeconds % 60}s';
  return '${took.inSeconds}s';
}

/// One run: its automation, result, cause, age and length; tapped, its steps
/// and what can be done about it.
class RunTile extends ConsumerStatefulWidget {
  const RunTile({required this.run, required this.checks, super.key});

  final AutomationRun run;
  final List<AutomationCheckVerdict> checks;

  @override
  ConsumerState<RunTile> createState() => _RunTileState();
}

class _RunTileState extends ConsumerState<RunTile> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final run = widget.run;
    final now = ref.watch(clockProvider).nowUtc();
    final automation = ref
        .watch(automationsDataProvider)
        .getById(run.automationId);
    final outcome = runOutcome(run, widget.checks);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final cause = runCause(run, automation).label;
    final age = describeAge(run.firedAt, now: now);
    final took = tookWords(run);
    final meta = '$cause · $age · $took';
    final wide = runsInColumns(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg,
              vertical: Insets.sm,
            ),
            child: Row(
              children: [
                Icon(
                  _open ? AppIcons.caretDown : AppIcons.caretRight,
                  size: Touch.iconSmall,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        automation?.name ?? 'A deleted automation',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (!wide)
                        Text(
                          meta,
                          style: quiet,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: Insets.sm),
                if (wide) ...[
                  _Cell(
                    width: _resultWidth,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: RunOutcomeChip(outcome: outcome),
                    ),
                  ),
                  _Cell(
                    width: _causeWidth,
                    child: Text(cause, style: quiet),
                  ),
                  _Cell(
                    width: _whenWidth,
                    child: Text(age, style: quiet),
                  ),
                  _Cell(
                    width: _tookWidth,
                    child: Text(took, style: quiet),
                  ),
                ] else
                  RunOutcomeChip(outcome: outcome),
              ],
            ),
          ),
        ),
        if (_open) _details(context, automation, outcome),
        const Divider(height: 1),
      ],
    );
  }

  Widget _details(
    BuildContext context,
    Automation? automation,
    RunOutcome outcome,
  ) {
    final theme = Theme.of(context);
    final run = widget.run;
    final now = ref.watch(clockProvider).nowUtc();
    final steps = <_StepLine>[
      _StepLine(
        title: automation?.startsAgent ?? true
            ? 'Start an agent'
            : 'Tell that session',
        outcome: switch (run.state) {
          AutomationRunState.finished => RunOutcome.succeeded,
          AutomationRunState.failed => RunOutcome.failed,
          AutomationRunState.running => RunOutcome.running,
          AutomationRunState.queued => RunOutcome.queued,
          AutomationRunState.missed => RunOutcome.missed,
          AutomationRunState.unrecognised => RunOutcome.unknown,
        },
        detail: run.reason,
      ),
      if (widget.checks.isNotEmpty || run.checksObservedAt != null)
        _StepLine(
          title: 'Check the result',
          outcome: widget.checks.isEmpty
              ? RunOutcome.succeeded
              : widget.checks.any((c) => c.verdict != VerificationVerdict.pass)
              ? RunOutcome.failed
              : RunOutcome.succeeded,
          detail: widget.checks.isEmpty
              ? 'No checks were configured.'
              : [
                  for (final c in widget.checks)
                    '${c.verdict.label} · ${c.name} · '
                        '${describeAge(c.checkedAt, now: now)}'
                        '${c.reason.isEmpty ? '' : '\n${c.reason}'}',
                ].join('\n'),
        ),
      for (final step in run.stepResults)
        _StepLine(
          title: step.kind.label,
          outcome: switch (step.outcome) {
            AutomationStepOutcome.done => RunOutcome.succeeded,
            AutomationStepOutcome.failed => RunOutcome.failed,
            AutomationStepOutcome.skipped => RunOutcome.unknown,
          },
          skipped: step.outcome == AutomationStepOutcome.skipped,
          detail: step.detail,
        ),
    ];
    final undoable =
        !run.state.isLive &&
        (run.sessionId != null || run.eventSessionId == null) &&
        run.baseCheckpointId != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xl + Insets.lg,
        0,
        Insets.lg,
        Insets.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final step in steps) step,
          if (run.commitsMade case final commits?)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                commits == 1 ? '1 commit' : '$commits commits',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              if (run.sessionId case final sessionId?)
                OutlinedButton(
                  key: const ValueKey('run-open-session'),
                  onPressed: () => _openSession(sessionId),
                  child: const Text('Open the session'),
                ),
              if (undoable)
                OutlinedButton(
                  key: const ValueKey('run-undo'),
                  onPressed: () => AutomationUndoDialog.show(context, run: run),
                  child: const Text('Undo this run…'),
                ),
              if (!run.state.isLive && automation != null)
                OutlinedButton(
                  key: const ValueKey('run-again'),
                  onPressed: () => runAutomationNow(context, ref, automation),
                  child: const Text('Run again'),
                ),
              if (run.state.isLive)
                OutlinedButton(
                  key: const ValueKey('run-cancel'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: () => cancelAutomationRun(context, ref, run),
                  child: const Text('Cancel run'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openSession(String id) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final showWorkbench = phoneWorkbenchOpener(context, ref);
    final result = await ref.read(explorerActionsProvider).openNative(id);
    if (!result.isFailure) showWorkbench?.call();
    final message = result.message;
    if (message != null) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({
    required this.title,
    required this.outcome,
    required this.detail,
    this.skipped = false,
  });

  final String title;
  final RunOutcome outcome;
  final String detail;
  final bool skipped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = runOutcomeColor(context, outcome);
    final icon = skipped
        ? AppIcons.minusCircle
        : switch (outcome) {
            RunOutcome.succeeded => AppIcons.checkCircle,
            RunOutcome.failed || RunOutcome.missed => AppIcons.xCircle,
            _ => AppIcons.circle,
          };
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: Touch.iconSmall, color: color),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  skipped ? '$title · skipped' : title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detail.isNotEmpty)
                  SelectableText(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
