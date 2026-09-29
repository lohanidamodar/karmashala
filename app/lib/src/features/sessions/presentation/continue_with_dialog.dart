import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/descriptors.dart';
import '../application/session_handoff_service.dart';
import 'continue_with_sections.dart';
import 'new_dialog_section.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/launch.dart';

/// What offering "Continue with…" promises, wherever it is offered from. Only
/// what the dialog enforces: it opens first and launches on its own button,
/// and reading what the next agent is told stays optional (owner, 2026-09-29).
const String kContinueWithPromise =
    'Nothing starts until you press Fork or Hand off. What happens says what '
    'that does; Preview shows exactly what the next agent will be told.';

/// "Continue with…" — move a session to another agent, or branch it. Nothing
/// starts before its button is pressed; the "What happens" summary says what
/// that does, and the optional Preview shows what the next agent is told.
///
/// Laid out like New session (spec §5): labelled parts in the order the choice
/// is made — who continues, what they are told, where they work — the rarely
/// changed options folded, and a "what happens" sentence over the buttons.
class ContinueWithDialog extends ConsumerStatefulWidget {
  const ContinueWithDialog({required this.sessionId, super.key});

  final String sessionId;

  /// A dialog at every width: the desktop window's minimum (720px) never
  /// reaches the compact class that would call for a bottom sheet.
  static Future<void> show(BuildContext context, String sessionId) =>
      showDialog<void>(
        context: context,
        builder: (_) => ContinueWithDialog(sessionId: sessionId),
      );

  @override
  ConsumerState<ContinueWithDialog> createState() => _ContinueWithDialogState();
}

enum _Mode { handoff, fork }

/// What the dialog is waiting on, so each button can say it is the one.
enum _Work { none, preview, start }

/// Everything the build draws, worked out from the state in one place.
typedef _View = ({
  List<HandoffTarget> targets,
  SessionForkPlan plan,
  HandoffTarget? target,
  HandoffTarget? focus,
  ContinuationPermission? permission,
  String sourceName,
  String? summary,
  String? blockedReason,
  String subtitle,
});

class _ContinueWithDialogState extends ConsumerState<ContinueWithDialog> {
  final _instruction = TextEditingController();
  final _tasks = TextEditingController();

  _Mode _mode = _Mode.handoff;
  String? _targetInstallationId;

  /// The mode the user picked, or null while the session's own is carried. The
  /// raw pick, not the resolved mode: the agent is still changeable.
  PermissionSelection? _chosenMode;

  bool _newWorktree = false;
  _Work _work = _Work.none;
  String? _preview;

  /// Whether the instruction or tasks changed after [_preview] was built.
  bool _previewStale = false;
  String? _error;

  /// Whether the folded options were opened by hand. They also show whenever
  /// one of them is set — see [_moreShown].
  bool _moreOpen = false;

  /// Whether to ask the source session to write its own brief first. **Off by
  /// default**: it spends a turn of the quota people hand off to escape.
  bool _askSource = false;

  /// What the source agent answered, kept so the preview and the launch spend
  /// one turn between them rather than one each.
  HandoffSourceBrief? _sourceBrief;

  bool get _busy => _work != _Work.none;

  bool get _fork => _mode == _Mode.fork;

  bool get _moreShown => _moreOpen || _askSource || _taskLines.isNotEmpty;

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
      _work = _Work.preview;
      _error = null;
    });
    try {
      final brief = await _briefFromSource();
      final packet = await ref
          .read(sessionHandoffServiceProvider)
          .previewPacket(
            sessionId: widget.sessionId,
            targetAgentName: _fork
                ? (_agentInFocus(targets)?.agentName ?? 'the same agent')
                : (target?.agentName ?? ''),
            instruction: _instruction.text.trim().isEmpty
                ? '(you have not written an instruction yet)'
                : _instruction.text,
            unresolvedTasks: _taskLines,
            isFork: _fork,
            sourceBrief: brief,
          );
      if (mounted) {
        setState(() {
          _preview = packet;
          _previewStale = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _work = _Work.none);
    }
  }

  Future<void> _start(List<HandoffTarget> targets) async {
    setState(() {
      _work = _Work.start;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      final service = ref.read(sessionHandoffServiceProvider);
      final brief = await _briefFromSource();
      if (_fork) {
        await service.forkSession(
          sessionId: widget.sessionId,
          instruction: _instruction.text,
          unresolvedTasks: _taskLines,
          intoNewWorktree: _newWorktree,
          permissionMode: _chosenMode,
          sourceBrief: brief,
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
      // Closed from its title bar while launching: that route is gone, and a
      // pop now would close whatever is under it.
      if (mounted) navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _message(e);
          _work = _Work.none;
        });
      }
    }
  }

  String _message(Object error) =>
      error is StateError ? error.message : '$error';

  /// The agent the permission question is about: the one being handed to, or —
  /// on the fork tab, where the agent is not in question — the session's own.
  HandoffTarget? _agentInFocus(List<HandoffTarget> targets) => _fork
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

  _View _viewOf(SessionContinuation continuation) {
    final targets = continuation.targets;
    final plan = continuation.plan;
    final target = _selected(targets);
    final focus = _agentInFocus(targets);
    // The agent already running this session, named rather than left as "the
    // previous agent": the brief spends its quota, and the user should know
    // whose.
    final sourceName =
        targets.where((t) => t.isSameAgent).firstOrNull?.agentName ??
        'the previous agent';
    final title = continuation.sessionTitle;
    final checkout = continuation.checkoutName;
    return (
      targets: targets,
      plan: plan,
      target: target,
      focus: focus,
      permission: focus == null ? null : _permissionFor(focus),
      sourceName: sourceName,
      summary: continueSummary(
        fork: _fork,
        plan: plan,
        target: target,
        sourceName: sourceName,
        sessionTitle: title,
        checkoutName: checkout,
        newWorktree: _newWorktree,
        withSourceBrief: _askSource,
      ),
      blockedReason: continueBlockedReason(
        fork: _fork,
        plan: plan,
        target: target,
        sourceName: sourceName,
        hasInstruction: _instruction.text.trim().isNotEmpty,
      ),
      subtitle: title == null
          ? 'Hand this session to another agent, or fork it.'
          : checkout == null
          ? title
          : '$title · $checkout',
    );
  }

  void _setMode(_Mode mode) => setState(() {
    _mode = mode;
    _preview = null;
  });

  void _edited() => setState(() {
    if (_preview != null) _previewStale = true;
  });

  @override
  Widget build(BuildContext context) {
    final view = _viewOf(
      ref.watch(sessionContinuationProvider(widget.sessionId)),
    );
    final canStart = !_busy && view.blockedReason == null;
    void start() => _start(view.targets);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (canStart) start();
        },
      },
      child: AlertDialog(
        title: DesktopDialogTitle(
          icon: AppIcons.gitBranch,
          title: 'Continue with…',
          subtitle: view.subtitle,
        ),
        content: BoundedDialogContent(
          width: DialogWidth.wide,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _modeSwitch(),
              NewDialogSection(
                label: _fork ? 'How it forks' : 'Agent',
                child: _agentPart(view),
              ),
              NewDialogSection(
                label: 'Instruction',
                child: _instructionField(),
              ),
              NewDialogSection(label: 'Where it works', child: _placeChoice()),
              const SizedBox(height: Insets.md),
              MoreOptions(
                open: _moreShown,
                // Held open while something folded is set, so it never hides.
                onToggle: _askSource || _taskLines.isNotEmpty
                    ? null
                    : () => setState(() => _moreOpen = !_moreOpen),
                setCount: (_askSource ? 1 : 0) + (_taskLines.isEmpty ? 0 : 1),
                children: _moreChildren(view),
              ),
              const SizedBox(height: Insets.lg),
              ContinueSummary(
                summary: view.summary,
                blockedReason: view.blockedReason,
              ),
              if (_preview case final preview?) ...[
                const SizedBox(height: Insets.md),
                if (_fork && view.plan.isNative)
                  PacketPreview(
                    packet: preview,
                    stale: _previewStale,
                    lead:
                        'The fork keeps its whole conversation. Besides it, '
                        'this is exactly what it is told:',
                  )
                else
                  PacketPreview(packet: preview, stale: _previewStale),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: Insets.md),
                DesktopErrorBanner(error),
              ],
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          _previewButton(view),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: Insets.sm),
              Tooltip(
                message:
                    view.blockedReason ??
                    (_fork ? 'Fork (Ctrl+Enter)' : 'Hand off (Ctrl+Enter)'),
                child: FilledButton(
                  onPressed: canStart ? start : null,
                  child: _work == _Work.start
                      ? InlineSpinner(
                          size: InlineSpinnerSize.medium,
                          semanticsLabel: _fork ? 'Forking' : 'Handing off',
                        )
                      : LabelWithChord(
                          label: _fork ? 'Fork' : 'Hand off',
                          chord: 'Ctrl+Enter',
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _modeSwitch() => SegmentedButton<_Mode>(
    showSelectedIcon: false,
    expandedInsets: EdgeInsets.zero,
    segments: const [
      ButtonSegment(
        value: _Mode.handoff,
        label: Text('Another agent'),
        icon: Icon(AppIcons.arrowBendDownRight, size: Chrome.iconAction),
      ),
      ButtonSegment(
        value: _Mode.fork,
        label: Text('Fork this one'),
        icon: Icon(AppIcons.gitBranch, size: Chrome.iconAction),
      ),
    ],
    selected: {_mode},
    onSelectionChanged: _busy ? null : (s) => _setMode(s.first),
  );

  /// Who continues: the agent list on the hand-off tab, the plan on the fork
  /// tab — and, under either, the mode that agent will run under.
  Widget _agentPart(_View view) {
    final focus = view.focus;
    final permission = view.permission;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_fork)
          ForkPlanNote(plan: view.plan)
        else
          ContinueTargetPicker(
            targets: view.targets,
            selected: view.target,
            permissionFor: _permissionFor,
            onChanged: (t) => setState(() {
              _targetInstallationId = t.installation.id;
              _preview = null;
            }),
          ),
        if (permission != null && focus != null) ...[
          const SizedBox(height: Insets.md),
          ContinuePermissionRow(
            permission: permission,
            descriptor: focus.descriptor,
            followsDefault: focus.followsDefault,
            agentName: focus.agentName,
            onChanged: (mode) => setState(() => _chosenMode = mode),
          ),
        ],
      ],
    );
  }

  Widget _instructionField() => TextField(
    controller: _instruction,
    autofocus: true,
    minLines: 3,
    maxLines: 6,
    onChanged: (_) => _edited(),
    decoration: const InputDecoration(
      labelText: 'What should the next agent do?',
      helperText:
          'The packet carries the conversation. This is the part only you '
          'can write.',
      helperMaxLines: 2,
    ),
  );

  /// Where the next session works — the same two places New session offers,
  /// drawn the same way.
  Widget _placeChoice() => RadioGroup<bool>(
    groupValue: _newWorktree,
    onChanged: (v) {
      if (_busy || v == null) return;
      setState(() => _newWorktree = v);
    },
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        RadioListTile<bool>(
          key: ValueKey('continue-with-place:checkout'),
          value: false,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('The same checkout'),
          subtitle: Text(
            'Continues in the same directory and on the same branch, so the '
            'next agent sees the work the recap describes.',
          ),
        ),
        RadioListTile<bool>(
          key: ValueKey('continue-with-place:worktree'),
          value: true,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('A new worktree'),
          subtitle: Text(
            'Its own folder and branch, so the two sessions cannot trip over '
            'each other.',
          ),
        ),
      ],
    ),
  );

  List<Widget> _moreChildren(_View view) => [
    TextField(
      controller: _tasks,
      minLines: 1,
      maxLines: 4,
      onChanged: (_) => _edited(),
      decoration: const InputDecoration(
        labelText: 'Still open (optional)',
        helperText: 'One per line. Listed in the packet as unfinished.',
      ),
    ),
    const SizedBox(height: Insets.sm),
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
      title: Text('Ask ${view.sourceName} to write the brief first'),
      subtitle: Text(
        _sourceBrief?.notWritten != null
            ? 'It did not: ${_sourceBrief!.notWritten}'
            : _fork && view.plan.isNative
            ? 'Costs ${view.sourceName} one turn. The fork carries the whole '
                  'conversation either way; this adds that agent\'s own '
                  'account of it, marked as its words, to what the fork is '
                  'told.'
            : 'Costs ${view.sourceName} one turn. The packet is assembled '
                  'from files either way; this adds that agent\'s own account '
                  'beside them, marked as its words.',
      ),
    ),
  ];

  /// Secondary, and on the left: reading the packet is optional, and it never
  /// launches anything.
  Widget _previewButton(_View view) {
    final previewing = _work == _Work.preview;
    return TextButton.icon(
      onPressed: _busy ? null : () => _buildPreview(view.targets),
      icon: previewing
          ? const InlineSpinner()
          : const Icon(AppIcons.eye, size: Chrome.iconAction),
      label: Text(
        !previewing
            ? (_fork && view.plan.isNative ? 'Preview' : 'Preview packet')
            : _askSource && _sourceBrief == null
            ? 'Asking ${view.sourceName}…'
            : 'Previewing…',
      ),
    );
  }
}
