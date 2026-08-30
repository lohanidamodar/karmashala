import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/session_handoff_service.dart';
import '../domain/session_fork.dart';

/// "Continue with…" — move a session to another agent, or branch it.
///
/// The dialog exists to make one thing true: **nothing is launched until the
/// user has seen what the next agent will be told.** A handoff spends the
/// receiving agent's first turn on this document, and the moment before launch
/// is the only one at which a missing instruction or a wrong recap costs
/// nothing. So the packet is built and previewed here, and the button that
/// starts it is the same one that dismisses the preview.
///
/// It also states, before the launch and not after it, the two things that
/// silently differ between agents:
///
/// * what the session's **permission mode** becomes on the way over (Loop 49's
///   fidelity, applied across a provider boundary), and
/// * whether a fork is the CLI's own or a written substitute for one.
class ContinueWithDialog extends ConsumerStatefulWidget {
  const ContinueWithDialog({required this.sessionId, super.key});

  final String sessionId;

  static Future<void> show(BuildContext context, String sessionId) =>
      showDialog<void>(
        context: context,
        builder: (_) => ContinueWithDialog(sessionId: sessionId),
      );

  @override
  ConsumerState<ContinueWithDialog> createState() => _ContinueWithDialogState();
}

enum _Mode { handoff, fork }

class _ContinueWithDialogState extends ConsumerState<ContinueWithDialog> {
  final _instruction = TextEditingController();
  final _tasks = TextEditingController();

  _Mode _mode = _Mode.handoff;
  String? _targetInstallationId;
  bool _newWorktree = false;
  bool _busy = false;
  String? _preview;
  String? _error;

  @override
  void dispose() {
    _instruction.dispose();
    _tasks.dispose();
    super.dispose();
  }

  List<String> get _taskLines => [
    for (final line in _tasks.text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  Future<void> _buildPreview(List<HandoffTarget> targets) async {
    final target = _selected(targets);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final packet = await ref
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: widget.sessionId,
            targetAgentName: _mode == _Mode.fork
                ? (target?.agentName ?? 'the same agent')
                : (target?.agentName ?? ''),
            instruction: _instruction.text.trim().isEmpty
                ? '(you have not written an instruction yet)'
                : _instruction.text,
            unresolvedTasks: _taskLines,
            isFork: _mode == _Mode.fork,
          );
      if (mounted) setState(() => _preview = packet.render());
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start(List<HandoffTarget> targets, SessionForkPlan plan) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      final service = ref.read(sessionHandoffServiceProvider);
      if (_mode == _Mode.fork) {
        await service.forkSession(
          sessionId: widget.sessionId,
          instruction: _instruction.text,
          unresolvedTasks: _taskLines,
          intoNewWorktree: _newWorktree,
        );
      } else {
        await service.handoffTo(
          sessionId: widget.sessionId,
          targetInstallationId: _selected(targets)!.installation.id,
          instruction: _instruction.text,
          unresolvedTasks: _taskLines,
          intoNewWorktree: _newWorktree,
        );
      }
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _message(e);
          _busy = false;
        });
      }
    }
  }

  String _message(Object error) =>
      error is StateError ? error.message : '$error';

  HandoffTarget? _selected(List<HandoffTarget> targets) {
    for (final target in targets) {
      if (target.installation.id == _targetInstallationId) return target;
    }
    return targets.where((t) => t.canReceive).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final continuation = ref.watch(
      sessionContinuationProvider(widget.sessionId),
    );
    final targets = continuation.targets;
    final plan = continuation.plan;
    final target = _selected(targets);
    final theme = Theme.of(context);

    final canStart =
        !_busy &&
        _instruction.text.trim().isNotEmpty &&
        (_mode == _Mode.fork ? !plan.isRefused : (target?.canReceive ?? false));

    return AlertDialog(
      title: const Text('Continue with…'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<_Mode>(
                segments: const [
                  ButtonSegment(
                    value: _Mode.handoff,
                    label: Text('Another agent'),
                    icon: Icon(AppIcons.arrowBendDownRight, size: 14),
                  ),
                  ButtonSegment(
                    value: _Mode.fork,
                    label: Text('Fork this one'),
                    icon: Icon(AppIcons.gitBranch, size: 14),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() {
                  _mode = s.first;
                  _preview = null;
                }),
              ),
              const SizedBox(height: Insets.md),
              if (_mode == _Mode.handoff)
                _TargetPicker(
                  targets: targets,
                  selected: target,
                  onChanged: (t) => setState(() {
                    _targetInstallationId = t.installation.id;
                    _preview = null;
                  }),
                )
              else
                _PlanNote(plan: plan),
              const SizedBox(height: Insets.md),
              TextField(
                controller: _instruction,
                minLines: 2,
                maxLines: 4,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'What should the next agent do?',
                  helperText:
                      'The packet carries the conversation. This is the part '
                      'only you can write.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: Insets.sm),
              TextField(
                controller: _tasks,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Still open (one per line, optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _newWorktree,
                onChanged: (v) => setState(() => _newWorktree = v ?? false),
                title: const Text('Start in a new worktree'),
                subtitle: const Text(
                  'Off: continues in the same directory and on the same '
                  'branch, so the next agent sees the work the recap '
                  'describes.',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: Insets.sm),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (_preview != null) ...[
                const SizedBox(height: Insets.md),
                Text(
                  'This is exactly what the next agent receives, as its first '
                  'message:',
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(height: Insets.xs),
                Container(
                  constraints: const BoxConstraints(maxHeight: 260),
                  width: double.infinity,
                  padding: const EdgeInsets.all(Insets.sm),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _preview!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _busy ? null : () => _buildPreview(targets),
          child: const Text('Preview packet'),
        ),
        FilledButton(
          onPressed: canStart ? () => _start(targets, plan) : null,
          child: Text(_mode == _Mode.fork ? 'Fork' : 'Hand off'),
        ),
      ],
    );
  }
}

/// The agent picker, with each target's permission consequence beside it.
///
/// A target that cannot receive the packet is **listed and disabled**, with the
/// reason, rather than hidden — the same rule the permission chip follows, for
/// the same reason: a missing option leaves the user hunting for it, while a
/// disabled one with a sentence beside it answers the question.
class _TargetPicker extends StatelessWidget {
  const _TargetPicker({
    required this.targets,
    required this.selected,
    required this.onChanged,
  });

  final List<HandoffTarget> targets;
  final HandoffTarget? selected;
  final ValueChanged<HandoffTarget> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (targets.isEmpty) {
      return Text(
        'No agent is installed in this session\'s environment. Run "Discover '
        'agents" in Settings.',
        style: theme.textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final target in targets)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            enabled: target.canReceive,
            selected: target.installation.id == selected?.installation.id,
            onTap: target.canReceive ? () => onChanged(target) : null,
            leading: Icon(
              target.installation.id == selected?.installation.id
                  ? AppIcons.checkCircle
                  : AppIcons.circle,
              size: 16,
              color: target.canReceive
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
            title: Row(
              children: [
                Flexible(child: Text(target.agentName)),
                if (target.isSameAgent) ...[
                  const SizedBox(width: Insets.xs),
                  Text(
                    'same agent, fresh conversation',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
            subtitle: Text(
              target.refusal ?? target.permission.summary,
              style: theme.textTheme.labelSmall?.copyWith(
                color: target.canReceive
                    ? (target.permission.enforced
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error)
                    : theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// What forking will really do, in the CLI's terms, before it happens.
class _PlanNote extends StatelessWidget {
  const _PlanNote({required this.plan});

  final SessionForkPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, colour) = switch (plan.kind) {
      SessionForkKind.native => (AppIcons.check, theme.colorScheme.primary),
      SessionForkKind.handoff => (AppIcons.info, theme.colorScheme.tertiary),
      SessionForkKind.refused => (
        AppIcons.warningCircle,
        theme.colorScheme.error,
      ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: colour),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(plan.explanation, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }
}
