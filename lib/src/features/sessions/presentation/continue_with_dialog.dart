import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/descriptors.dart';
import '../../agents/presentation/permission_mode_picker.dart';
import '../application/session_handoff_service.dart';
import 'tool_activity_row.dart' show kExpandedOutputMaxHeight;
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/launch.dart';

/// What offering "Continue with…" promises, wherever it is offered from. The
/// row is a shorter path *to* a confirmation, never a way past one.
const String kContinueWithPromise =
    'Nothing is launched until you have seen what the next agent will be told.';

/// "Continue with…" — move a session to another agent, or branch it. Nothing is
/// launched until the user has seen what the next agent will be told.
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

  /// The mode the user picked, or null while the session's own is carried. The
  /// raw pick, not the resolved mode: the agent is still changeable.
  PermissionSelection? _chosenMode;

  bool _newWorktree = false;
  bool _busy = false;
  String? _preview;
  String? _error;

  /// Whether to ask the source session to write its own brief first. **Off by
  /// default**: it spends a turn of the quota people hand off to escape.
  bool _askSource = false;

  /// What the source agent answered, kept so the preview and the launch spend
  /// one turn between them rather than one each.
  HandoffSourceBrief? _sourceBrief;

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

  /// The source agent's brief, asked for at most once. Never throws into the
  /// caller: a failure becomes the sentence the packet prints instead.
  Future<HandoffSourceBrief?> _briefFromSource() async {
    if (!_askSource) return null;
    final held = _sourceBrief;
    if (held != null) return held;
    try {
      final brief = await ref
          .read(sessionHandoffServiceProvider)
          .requestSourceBrief(sessionId: widget.sessionId);
      return _sourceBrief = brief;
    } catch (e) {
      return _sourceBrief = HandoffSourceBrief.notWritten(_message(e));
    }
  }

  Future<void> _buildPreview(List<HandoffTarget> targets) async {
    final target = _selected(targets);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final brief = await _briefFromSource();
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
            sourceBrief: brief,
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
      final brief = await _briefFromSource();
      if (_mode == _Mode.fork) {
        await service.forkSession(
          sessionId: widget.sessionId,
          instruction: _instruction.text,
          unresolvedTasks: _taskLines,
          intoNewWorktree: _newWorktree,
          permissionMode: _chosenMode,
        );
      } else {
        await service.handoffTo(
          sessionId: widget.sessionId,
          targetInstallationId: _selected(targets)!.installation.id,
          instruction: _instruction.text,
          unresolvedTasks: _taskLines,
          intoNewWorktree: _newWorktree,
          permissionMode: _chosenMode,
          sourceBrief: brief,
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

  /// The agent the permission question is about: the one being handed to, or —
  /// on the fork tab, where the agent is not in question — the session's own.
  HandoffTarget? _agentInFocus(List<HandoffTarget> targets) =>
      _mode == _Mode.fork
      ? targets.where((t) => t.isSameAgent).firstOrNull
      : _selected(targets);

  /// What [target] will run under, given whatever has been picked so far —
  /// `target.permission.requested` is all the dialog needs to ask it.
  ContinuationPermission _permissionFor(HandoffTarget target) =>
      resolveContinuationPermission(
        sessionRisk: target.permission.requested,
        target: target.descriptor,
        chosen: _chosenMode,
        targetName: target.agentName,
      );

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
    final focus = _agentInFocus(targets);
    // The agent already running this session, named rather than left as "the
    // previous agent": the row spends its quota, and the user should know whose.
    final sourceName =
        targets.where((t) => t.isSameAgent).firstOrNull?.agentName ??
        'the previous agent';
    final permission = focus == null ? null : _permissionFor(focus);
    final theme = Theme.of(context);

    final canStart =
        !_busy &&
        _instruction.text.trim().isNotEmpty &&
        (_mode == _Mode.fork ? !plan.isRefused : (target?.canReceive ?? false));

    return AlertDialog(
      title: const Text('Continue with…'),
      content: BoundedDialogContent(
        width: DialogWidth.wide,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(
                  value: _Mode.handoff,
                  label: Text('Another agent'),
                  icon: Icon(
                    AppIcons.arrowBendDownRight,
                    size: Chrome.iconAction,
                  ),
                ),
                ButtonSegment(
                  value: _Mode.fork,
                  label: Text('Fork this one'),
                  icon: Icon(AppIcons.gitBranch, size: Chrome.iconAction),
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
                permissionFor: _permissionFor,
                onChanged: (t) => setState(() {
                  _targetInstallationId = t.installation.id;
                  _preview = null;
                }),
              )
            else
              _PlanNote(plan: plan),
            if (permission != null && focus != null) ...[
              const SizedBox(height: Insets.sm),
              _PermissionRow(
                permission: permission,
                descriptor: focus.descriptor,
                followsDefault: focus.followsDefault,
                agentName: focus.agentName,
                onChanged: (mode) => setState(() => _chosenMode = mode),
              ),
            ],
            const SizedBox(height: Insets.md),
            TextField(
              controller: _instruction,
              minLines: 2,
              maxLines: 4,
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
              value: _askSource,
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _askSource = v ?? false;
                      _preview = null;
                    }),
              title: Text('Ask $sourceName to write the brief first'),
              subtitle: Text(
                _sourceBrief?.notWritten != null
                    ? 'It did not: ${_sourceBrief!.notWritten}'
                    : 'Costs $sourceName one turn. The packet is assembled '
                          'from files either way; this adds that agent\'s '
                          'own account beside them, marked as its words.',
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
                // Not "as its first message": an agent that takes a
                // system-prompt file gets the packet as one.
                'This is exactly what the next agent is told:',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: Insets.xs),
              Container(
                constraints: const BoxConstraints(
                  maxHeight: kExpandedOutputMaxHeight,
                ),
                width: double.infinity,
                padding: const EdgeInsets.all(Insets.sm),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: SingleChildScrollView(
                  primary: false,
                  child: SelectableText(
                    _preview!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: kMonoFamily,
                    ),
                  ),
                ),
              ),
            ],
          ],
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

/// The agent picker, with each target's permission consequence beside it. One
/// that cannot receive the packet is **listed and disabled**, never hidden.
class _TargetPicker extends StatelessWidget {
  const _TargetPicker({
    required this.targets,
    required this.selected,
    required this.permissionFor,
    required this.onChanged,
  });

  final List<HandoffTarget> targets;
  final HandoffTarget? selected;

  /// Each row's permission sentence, resolved against the mode picked so far —
  /// the session's alone would answer for a mode already changed.
  final ContinuationPermission Function(HandoffTarget) permissionFor;

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
            subtitle: Builder(
              builder: (context) {
                final permission = permissionFor(target);
                return Text(
                  target.refusal ?? permission.carried.summary,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: target.canReceive
                        ? (permission.carried.enforced
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.error)
                        : theme.colorScheme.error,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// The mode the next session will run under, and where that answer came from.
/// It sits under the agent because the modes on offer are that agent's.
class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.permission,
    required this.descriptor,
    required this.followsDefault,
    required this.agentName,
    required this.onChanged,
  });

  final ContinuationPermission permission;

  /// The target agent, so the picker can draw *its* axes. Re-run on every agent
  /// change, so one CLI's pick is never shown against another's vocabulary.
  final AgentDescriptor? descriptor;

  /// Whether the mode on offer is the Settings default rather than anything
  /// this session or this user decided. See [HandoffTarget.followsDefault].
  final bool followsDefault;

  final String agentName;

  final ValueChanged<PermissionSelection> onChanged;

  /// Where this mode came from in the one case [ContinuationPermission] cannot
  /// know: nobody chose it, so "carried from this session" would be wrong.
  String get _explanation => followsDefault && !permission.wasChosen
      ? 'Following the $agentName default in Settings, as this session does. '
            'It changes when that setting does. ${permission.carried.summary}'
      : permission.explanation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text('Runs under', style: theme.textTheme.labelSmall),
            const SizedBox(width: Insets.sm),
            // Flexible: Codex's label is a pair ("Workspace · On request"),
            // which is wider than the three short words this row used to hold.
            Flexible(
              child: PermissionModePicker(
                descriptor: descriptor,
                selection: permission.selection,
                onChanged: onChanged,
                agentName: agentName,
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        Text(
          _explanation,
          style: theme.textTheme.labelSmall?.copyWith(
            color: permission.carried.enforced
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
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
        Icon(icon, size: Chrome.iconAction, color: colour),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(plan.explanation, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }
}
