import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../workspaces/data/workspace_data.dart';
import '../../projects/application/projects_controller.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../../settings/presentation/settings_theme.dart';
import 'package:karmashala_git/cleanup.dart';
import 'package:karmashala_ui/primitives.dart';
import '../application/worktree_cleanup_providers.dart';

/// Settings → Projects and files → Worktree setup → Automatic cleanup: the
/// policy, a dry run, and the log of what was removed. The server sweeps, on
/// its own schedule; nothing here asks it to until a button is pressed.
class WorktreeCleanupSection extends ConsumerStatefulWidget {
  const WorktreeCleanupSection({super.key});

  @override
  ConsumerState<WorktreeCleanupSection> createState() =>
      _WorktreeCleanupSectionState();
}

class _WorktreeCleanupSectionState
    extends ConsumerState<WorktreeCleanupSection> {
  WorktreeCleanupReport? _report;
  bool _busy = false;
  String? _error;

  WorktreeCleanupController get _controller =>
      ref.read(worktreeCleanupControllerProvider);

  void _save(WorktreeCleanupSettings settings) {
    _controller.save(settings);
    // A preview judged by the old rules would now be a false statement.
    setState(() => _report = null);
  }

  Future<void> _run(Future<WorktreeCleanupReport> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await action();
      if (mounted) setState(() => _report = report);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cleanUpNow() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clean up worktrees now?'),
        content: const Text(
          'Removes every worktree the rules match under the current settings. '
          'Each one is checked again just before it goes: a running session, '
          'uncommitted changes or ignored files still keep it. Branches are '
          'never deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('worktree-cleanup-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(_controller.sweep);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(worktreeCleanupSettingsProvider);
    final cleanup =
        ref.watch(worktreeCleanupLogProvider).value ?? WorktreeCleanupLog.empty;
    final log = cleanup.entries;
    final last = cleanup.lastSweep;
    ref.watch(projectsControllerProvider);
    final projects = ref.watch(workspaceDataProvider).projects;
    final now = ref.watch(clockProvider).nowUtc();
    final small = theme.textTheme.bodySmall;

    return SettingsSection(
      title: 'AUTOMATIC CLEANUP',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsNote(
            'Removes idle worktrees Karmashala made. Branches are kept.',
            child: Text(
              key: const ValueKey('worktree-cleanup-squash-caveat'),
              '"Branch merged" cannot see a squash merge; use "inactive".',
              style: small,
            ),
          ),
          SettingsSwitchRow(
            key: const ValueKey('worktree-cleanup-enabled'),
            label: 'Clean up automatically',
            help: 'Projects can opt out or use their own rules below.',
            value: settings.enabled,
            onChanged: (on) => _save(settings.copyWith(enabled: on)),
          ),
          _RulesEditor(
            key: const ValueKey('worktree-cleanup-rules-default'),
            rules: settings.rules,
            onChanged: (rules) => _save(settings.copyWith(rules: rules)),
          ),
          if (projects.isNotEmpty) ...[
            const SizedBox(height: Insets.md),
            Text('Per project', style: SettingsStyles.sectionLabel(context)),
            const SizedBox(height: Insets.xs),
            for (final project in projects)
              _ProjectPolicyRow(
                key: ValueKey('worktree-cleanup-project ${project.id}'),
                name: project.name,
                policy: settings.policyFor(project.id),
                defaultOn: settings.enabled,
                onChanged: (policy) => _save(
                  settings.copyWith(
                    projects: {...settings.projects, project.id: policy},
                  ),
                ),
              ),
          ],
          const SizedBox(height: Insets.md),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                key: const ValueKey('worktree-cleanup-preview'),
                onPressed: _busy ? null : () => _run(_controller.preview),
                child: const Text('Preview'),
              ),
              TextButton(
                key: const ValueKey('worktree-cleanup-now'),
                onPressed: _busy || !settings.anyEnabled ? null : _cleanUpNow,
                child: const Text('Clean up now'),
              ),
              if (_busy) const InlineSpinner(size: InlineSpinnerSize.medium),
            ],
          ),
          if (last != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(_describeLast(last, now), style: small),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                _error!,
                style: small?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          if (_report != null) ...[
            const SizedBox(height: Insets.sm),
            _ReportView(report: _report!, defaultOff: !settings.anyEnabled),
          ],
          if (log.isNotEmpty) ...[
            const SizedBox(height: Insets.md),
            Text('Removed', style: theme.textTheme.titleSmall),
            for (final entry in log.take(20))
              _LogLine(
                key: ValueKey('worktree-cleanup-log ${entry.worktreePath}'),
                entry: entry,
                now: now,
              ),
          ],
        ],
      ),
    );
  }

  static String _describeLast(WorktreeCleanupSweepSummary last, DateTime now) {
    final who = last.automatic ? 'Last automatic cleanup' : 'Last cleanup';
    final age = describeAge(now.difference(last.startedAt));
    if (last.error != null) return '$who $age failed: ${last.error}';
    if (last.finishedAt == null) return '$who started $age.';
    return '$who $age: removed ${last.removed}, kept ${last.kept}'
        '${last.failed == 0 ? '' : ', ${last.failed} git refused'}.';
  }
}

/// The three rules, their threshold, and the ignored names that don't count.
class _RulesEditor extends StatefulWidget {
  const _RulesEditor({required this.rules, required this.onChanged, super.key});

  final WorktreeCleanupRules rules;
  final ValueChanged<WorktreeCleanupRules> onChanged;

  @override
  State<_RulesEditor> createState() => _RulesEditorState();
}

class _RulesEditorState extends State<_RulesEditor> {
  late final _days = TextEditingController(
    text: '${widget.rules.inactiveDays}',
  );
  late final _exempt = TextEditingController(
    text: widget.rules.exemptIgnored.join(', '),
  );

  @override
  void dispose() {
    _days.dispose();
    _exempt.dispose();
    super.dispose();
  }

  void _commitDays(String text) {
    final days = int.tryParse(text.trim());
    if (days == null || days < 1) {
      _days.text = '${widget.rules.inactiveDays}';
      return;
    }
    if (days != widget.rules.inactiveDays) {
      widget.onChanged(widget.rules.copyWith(inactiveDays: days));
    }
  }

  void _commitExempt(String text) {
    final names = [
      for (final part in text.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    widget.onChanged(widget.rules.copyWith(exemptIgnored: names));
  }

  @override
  Widget build(BuildContext context) {
    final rules = widget.rules;
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Checkbox(
              key: const ValueKey('worktree-cleanup-rule-inactive'),
              value: rules.inactiveEnabled,
              onChanged: (on) => widget.onChanged(
                rules.copyWith(inactiveEnabled: on ?? false),
              ),
            ),
            const Flexible(child: Text('Inactive for')),
            const SizedBox(width: Insets.xs),
            SizedBox(
              width: 56,
              child: TextField(
                key: const ValueKey('worktree-cleanup-days'),
                controller: _days,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(isDense: true),
                onSubmitted: _commitDays,
                onTapOutside: (_) => _commitDays(_days.text),
              ),
            ),
            const SizedBox(width: Insets.xs),
            const Flexible(child: Text('days')),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: Insets.xxl + Insets.sm),
          child: Text(
            'Since HEAD last moved or a session last ran in it.',
            style: small,
          ),
        ),
        CheckboxListTile(
          key: const ValueKey('worktree-cleanup-rule-merged'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: rules.merged,
          onChanged: (on) =>
              widget.onChanged(rules.copyWith(merged: on ?? false)),
          title: const Text('Branch merged'),
          subtitle: const Text('All its commits are on the default branch.'),
        ),
        CheckboxListTile(
          key: const ValueKey('worktree-cleanup-rule-empty'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: rules.noCommitsBeyondDefault,
          onChanged: (on) => widget.onChanged(
            rules.copyWith(noCommitsBeyondDefault: on ?? false),
          ),
          title: const Text('No commits beyond the default branch'),
          subtitle: const Text('Nothing in it that the default branch lacks.'),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Insets.xs),
          child: TextField(
            key: const ValueKey('worktree-cleanup-exempt'),
            controller: _exempt,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Ignored paths that don\'t count',
              helperText:
                  'Folder or file names, comma-separated. Any other ignored '
                  'file — a build output, a local .env — keeps the worktree.',
            ),
            onSubmitted: _commitExempt,
            onTapOutside: (_) {
              if (_exempt.text != rules.exemptIgnored.join(', ')) {
                _commitExempt(_exempt.text);
              }
            },
          ),
        ),
      ],
    );
  }
}

class _ProjectPolicyRow extends StatelessWidget {
  const _ProjectPolicyRow({
    required this.name,
    required this.policy,
    required this.defaultOn,
    required this.onChanged,
    super.key,
  });

  final String name;
  final ProjectCleanupPolicy policy;
  final bool defaultOn;
  final ValueChanged<ProjectCleanupPolicy> onChanged;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
              if (policy.mode == WorktreeCleanupMode.inherit)
                Padding(
                  padding: const EdgeInsets.only(right: Insets.sm),
                  child: Text(defaultOn ? 'on' : 'off', style: small),
                ),
              DropdownButton<WorktreeCleanupMode>(
                value: policy.mode,
                isDense: true,
                onChanged: (mode) {
                  if (mode == null) return;
                  onChanged(
                    ProjectCleanupPolicy(mode: mode, rules: policy.rules),
                  );
                },
                items: [
                  for (final mode in WorktreeCleanupMode.values)
                    DropdownMenuItem(value: mode, child: Text(mode.label)),
                ],
              ),
            ],
          ),
          if (policy.mode == WorktreeCleanupMode.custom)
            Padding(
              padding: const EdgeInsets.only(left: Insets.md),
              child: _RulesEditor(
                rules: policy.rules,
                onChanged: (rules) => onChanged(
                  ProjectCleanupPolicy(mode: policy.mode, rules: rules),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A preview or a sweep: what goes, what stays and why.
class _ReportView extends StatelessWidget {
  const _ReportView({required this.report, required this.defaultOff});

  final WorktreeCleanupReport report;
  final bool defaultOff;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final going = report.dryRun
        ? report.withOutcome(WorktreeCleanupOutcome.wouldRemove).toList()
        : report.withOutcome(WorktreeCleanupOutcome.removed).toList();
    final failed = report.withOutcome(WorktreeCleanupOutcome.failed).toList();
    final kept = report.withOutcome(WorktreeCleanupOutcome.kept).toList();
    // A ruled entry under the buttons, not a bordered box (board N5).
    return SettingsRuled(
      key: const ValueKey('worktree-cleanup-report'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            report.dryRun
                ? (defaultOff
                      ? 'Preview — cleanup is off, so nothing will be removed '
                            'until you turn it on. This is what it would do now:'
                      : 'Preview — nothing was removed.')
                : 'Cleanup ran.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Insets.xs),
          Text(
            report.dryRun
                ? 'Would remove (${going.length})'
                : 'Removed (${going.length})',
            style: theme.textTheme.titleSmall,
          ),
          if (going.isEmpty) Text('Nothing.', style: small),
          for (final v in going)
            _VerdictLine(
              verdict: v,
              icon: AppIcons.trash,
              lines: ['Matched: ${v.matched.map((r) => r.label).join(', ')}.'],
            ),
          if (failed.isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            Text(
              'git refused (${failed.length})',
              style: theme.textTheme.titleSmall,
            ),
            for (final v in failed)
              _VerdictLine(
                verdict: v,
                icon: AppIcons.warning,
                lines: [v.error ?? 'No reason given.'],
              ),
          ],
          const SizedBox(height: Insets.xs),
          Text('Kept (${kept.length})', style: theme.textTheme.titleSmall),
          for (final v in kept)
            _VerdictLine(
              verdict: v,
              icon: AppIcons.checkCircle,
              lines: v.refusals.isNotEmpty
                  ? [
                      if (v.matched.isNotEmpty)
                        'Matched ${v.matched.map((r) => r.label).join(', ')}, '
                            'but kept:',
                      if (v.recheckedBeforeRemoval)
                        'Found when it was checked again just before removal.',
                      for (final r in v.refusals)
                        '${r.kind.label} — ${r.detail}',
                    ]
                  : ['No rule matched.', ...v.unmatched],
            ),
          for (final note in report.notes) Text(note, style: small),
          if (report.notInspected > 0)
            Text(
              '${report.notInspected} more worktree'
              '${report.notInspected == 1 ? '' : 's'} not inspected: one '
              'sweep looks at $kWorktreeCleanupMaxPerSweep at most.',
              style: small,
            ),
        ],
      ),
    );
  }
}

class _VerdictLine extends StatelessWidget {
  const _VerdictLine({
    required this.verdict,
    required this.icon,
    required this.lines,
  });

  final WorktreeCleanupVerdict verdict;
  final IconData icon;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final f = verdict.facts;
    return Padding(
      key: ValueKey('worktree-cleanup-verdict ${f.path.path}'),
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: Chrome.iconSmall),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  '${f.label} · ${f.projectName}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: Insets.lg + Insets.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(f.path.path, style: small),
                for (final line in lines) Text(line, style: small),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry, required this.now, super.key});

  final WorktreeCleanupLogEntry entry;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final rules = entry.rules.map((r) => r.label).join(', ');
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${entry.branch ?? entry.worktreePath} · ${entry.projectName} — '
            '${entry.removed ? 'removed' : 'git refused'} '
            '${describeAge(now.difference(entry.at))}'
            '${entry.automatic ? '' : ' (by hand)'}',
            style: small?.copyWith(
              color: entry.removed ? null : theme.colorScheme.error,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: Insets.md),
            child: Text(
              '${entry.worktreePath}\nRule: $rules. ${entry.detail}',
              style: small,
            ),
          ),
        ],
      ),
    );
  }
}
