import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/full_screen_form.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_model_catalog_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/model_picker.dart';
import '../../automations/presentation/automation_agent_fields.dart'
    show AutomationPermissionModeField;
import '../application/pipelines_controller.dart';

/// Edits [initial] — a copy of it when it is built in — and saves it as the
/// person's own. Answers what was saved.
Future<PipelineDefinition?> showPipelineEditor(
  BuildContext context, {
  PipelineDefinition? initial,
}) {
  final base = initial ?? kPipelineTemplates.first;
  final draft = initial == null || initial.builtIn
      ? base.copyWith(
          id: '',
          name: initial == null ? 'My pipeline' : '${base.name} (copy)',
          builtIn: false,
        )
      : initial;
  return showFormDialog<PipelineDefinition>(
    context: context,
    builder: (_) => PipelineEditor(initial: draft),
  );
}

/// **The pipeline editor**: a list of stages, each with its role, agent,
/// model, mode, workspace, instruction and gate. A list, not a canvas.
class PipelineEditor extends ConsumerStatefulWidget {
  const PipelineEditor({required this.initial, super.key});

  final PipelineDefinition initial;

  @override
  ConsumerState<PipelineEditor> createState() => _PipelineEditorState();
}

class _StageDraft {
  _StageDraft(PipelineStage stage)
    : role = TextEditingController(text: stage.role),
      instruction = TextEditingController(text: stage.instruction),
      checkCommand = TextEditingController(text: stage.checkCommand),
      stage = stage;

  final TextEditingController role;
  final TextEditingController instruction;
  final TextEditingController checkCommand;

  /// Everything but the three texts above.
  PipelineStage stage;

  PipelineStage get value => stage.copyWith(
    role: role.text.trim(),
    instruction: instruction.text,
    checkCommand: checkCommand.text.trim(),
  );

  void dispose() {
    role.dispose();
    instruction.dispose();
    checkCommand.dispose();
  }
}

class _PipelineEditorState extends ConsumerState<PipelineEditor> {
  late final _name = TextEditingController(text: widget.initial.name);
  late final List<_StageDraft> _stages = [
    for (final stage in widget.initial.stages) _StageDraft(stage),
  ];
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    for (final stage in _stages) {
      stage.dispose();
    }
    super.dispose();
  }

  PipelineDefinition get _value => widget.initial.copyWith(
    name: _name.text.trim(),
    stages: [for (final stage in _stages) stage.value],
  );

  Future<void> _save() async {
    final value = _value;
    final refusal = pipelineDefinitionRefusal(value);
    if (refusal != null) {
      setState(() => _error = refusal);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await ref.read(pipelinesProvider.notifier).save(value);
      if (mounted) Navigator.of(context).pop(saved);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _addStage() => setState(
    () => _stages.add(
      _StageDraft(
        PipelineStage(
          role: 'Stage ${_stages.length + 1}',
          instruction: '{{input}}',
          workspace: _stages.isEmpty
              ? PipelineWorkspace.source
              : PipelineWorkspace.previousWorktree,
        ),
      ),
    ),
  );

  void _move(int from, int to) => setState(() {
    final stage = _stages.removeAt(from);
    _stages.insert(to, stage);
  });

  void _remove(int index) => setState(() => _stages.removeAt(index).dispose());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('pipeline-editor-name'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: Insets.md),
        for (final (i, stage) in _stages.indexed) ...[
          _StageEditor(
            key: ObjectKey(stage),
            index: i,
            draft: stage,
            earlier: [for (final s in _stages.take(i + 1)) s.value],
            canMoveUp: i > 0,
            canMoveDown: i < _stages.length - 1,
            onMoveUp: () => _move(i, i - 1),
            onMoveDown: () => _move(i, i + 1),
            onRemove: _stages.length > 1 ? () => _remove(i) : null,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: Insets.sm),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('pipeline-editor-add-stage'),
            onPressed: _stages.length >= kPipelineMaxStages ? null : _addStage,
            icon: const Icon(AppIcons.plus),
            label: const Text('Add a stage'),
          ),
        ),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('pipeline-editor-error'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
      ],
    );
    final save = FilledButton(
      key: const ValueKey('pipeline-editor-save'),
      onPressed: _busy ? null : _save,
      child: const Text('Save'),
    );
    void cancel() => Navigator.of(context).pop();
    if (opensFullScreen(context)) {
      return FullScreenForm(
        title: 'Pipeline',
        body: body,
        primary: save,
        onClose: cancel,
      );
    }
    return AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.treeStructure,
        title: 'Pipeline',
        subtitle: 'Stages run in order, each one handed the last one\'s work.',
      ),
      scrollable: true,
      content: SizedBox(width: DialogWidth.wide, child: body),
      actions: [
        TextButton(onPressed: cancel, child: const Text('Cancel')),
        save,
      ],
    );
  }
}

class _StageEditor extends ConsumerWidget {
  const _StageEditor({
    required this.index,
    required this.draft,
    required this.earlier,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
    required this.onChanged,
    super.key,
  });

  final int index;
  final _StageDraft draft;

  /// The stages up to and including this one, as they stand.
  final List<PipelineStage> earlier;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback? onRemove;
  final VoidCallback onChanged;

  void _set(PipelineStage stage) {
    draft.stage = stage;
    onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final registry = ref.watch(agentRegistryProvider);
    final installations = [
      for (final i in ref.watch(agentInstallationsControllerProvider))
        if (registry.adapterFor(i.agentId) != null) i,
    ];
    final environments = {for (final i in installations) i.environmentId};
    String nameOf(AgentInstallation i) {
      final name = registry.displayNameFor(i.agentId);
      return environments.length > 1 ? '$name · ${i.environmentId}' : name;
    }

    final stage = draft.stage;
    final installation = installations
        .where((i) => i.id == stage.agentInstallationId)
        .firstOrNull;
    final descriptor = installation == null
        ? null
        : registry.byId(installation.agentId);
    final key = pipelineStageKey(draft.role.text);
    return DecoratedBox(
      key: ValueKey('pipeline-editor-stage:$index'),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Insets.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('pipeline-editor-role:$index'),
                    controller: draft.role,
                    onChanged: (_) => onChanged(),
                    decoration: InputDecoration(
                      labelText: 'Stage ${index + 1} role',
                      helperText: 'In fields: {{$key.answer}}',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Move up',
                  visualDensity: VisualDensity.compact,
                  onPressed: canMoveUp ? onMoveUp : null,
                  icon: const Icon(AppIcons.caretUp),
                ),
                IconButton(
                  tooltip: 'Move down',
                  visualDensity: VisualDensity.compact,
                  onPressed: canMoveDown ? onMoveDown : null,
                  icon: const Icon(AppIcons.caretDown),
                ),
                IconButton(
                  key: ValueKey('pipeline-editor-remove:$index'),
                  tooltip: 'Remove this stage',
                  visualDensity: VisualDensity.compact,
                  onPressed: onRemove,
                  icon: const Icon(AppIcons.trash),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            DropdownButtonFormField<String?>(
              key: ValueKey('pipeline-editor-agent:$index'),
              initialValue: installation?.id,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Agent'),
              items: [
                const DropdownMenuItem<String?>(
                  child: Text("The checkout's default agent"),
                ),
                for (final i in installations)
                  DropdownMenuItem<String?>(
                    value: i.id,
                    child: Text(nameOf(i), overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) => _set(
                stage.copyWith(
                  agentInstallationId: id,
                  clearAgent: id == null,
                  clearModel: true,
                  clearPermission: true,
                ),
              ),
            ),
            if (descriptor != null) ...[
              const SizedBox(height: Insets.xs),
              Row(
                children: [
                  Text('Model', style: theme.textTheme.bodySmall),
                  const SizedBox(width: Insets.sm),
                  Flexible(
                    child: ModelPicker(
                      options: modelOptionsFor(
                        descriptor,
                        current: stage.modelId,
                        support: ref.watch(
                          agentModelSupportProvider(descriptor.id),
                        ),
                      ),
                      selected: stage.modelId,
                      onChanged: (choice) => _set(
                        stage.copyWith(
                          modelId: choice.modelId,
                          clearModel: choice.modelId == null,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              AutomationPermissionModeField(
                agentName: descriptor.displayName,
                support: descriptor.launch.permission,
                value: PermissionSelection.parse(stage.permissionMode),
                onChanged: (mode) => _set(
                  stage.copyWith(
                    permissionMode: mode?.canonical,
                    clearPermission: mode == null,
                  ),
                ),
              ),
            ],
            const SizedBox(height: Insets.xs),
            DropdownButtonFormField<PipelineWorkspace>(
              key: ValueKey('pipeline-editor-workspace:$index'),
              initialValue: stage.workspace,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Works in'),
              items: [
                for (final workspace in PipelineWorkspace.values)
                  if (index > 0 ||
                      workspace != PipelineWorkspace.previousWorktree)
                    DropdownMenuItem(
                      value: workspace,
                      child: Text(workspace.label),
                    ),
              ],
              onChanged: (w) =>
                  w == null ? null : _set(stage.copyWith(workspace: w)),
            ),
            const SizedBox(height: Insets.xs),
            TextField(
              key: ValueKey('pipeline-editor-instruction:$index'),
              controller: draft.instruction,
              minLines: 3,
              maxLines: 10,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                labelText: 'Instruction',
                alignLabelWithHint: true,
                suffixIcon: _FieldMenu(
                  index: index,
                  stages: earlier,
                  onPick: (field) => _insert(draft.instruction, field),
                ),
              ),
            ),
            const SizedBox(height: Insets.xs),
            DropdownButtonFormField<PipelineGateKind>(
              key: ValueKey('pipeline-editor-gate:$index'),
              initialValue: stage.gate,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Then'),
              items: [
                for (final gate in PipelineGateKind.values)
                  DropdownMenuItem(value: gate, child: Text(_gateLabel(gate))),
              ],
              onChanged: (g) =>
                  g == null ? null : _set(stage.copyWith(gate: g)),
            ),
            if (stage.gate == PipelineGateKind.check) ...[
              const SizedBox(height: Insets.xs),
              TextField(
                key: ValueKey('pipeline-editor-check:$index'),
                controller: draft.checkCommand,
                decoration: const InputDecoration(
                  labelText: 'Check command',
                  helperText: "Blank runs the checkout's project checks.",
                ),
              ),
            ],
            const SizedBox(height: Insets.xs),
            DropdownButtonFormField<String?>(
              key: ValueKey('pipeline-editor-loop:$index'),
              initialValue: earlier.any((s) => s.key == stage.loopBackTo)
                  ? stage.loopBackTo
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'When it fails its check or answers VERDICT: FAIL',
              ),
              items: [
                const DropdownMenuItem<String?>(child: Text('Stop the run')),
                for (final s in earlier)
                  DropdownMenuItem<String?>(
                    value: s.key,
                    child: Text(
                      'Go back to ${s.role}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (to) => _set(
                stage.copyWith(loopBackTo: to, clearLoopBack: to == null),
              ),
            ),
            if (stage.loopBackTo != null) ...[
              const SizedBox(height: Insets.xs),
              DropdownButtonFormField<int>(
                key: ValueKey('pipeline-editor-loop-cap:$index'),
                initialValue: stage.loopCap.clamp(1, kPipelineLoopCapMax),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'At most'),
                items: [
                  for (var n = 1; n <= kPipelineLoopCapMax; n++)
                    DropdownMenuItem(
                      value: n,
                      child: Text('$n time${n == 1 ? '' : 's'}'),
                    ),
                ],
                onChanged: (n) =>
                    n == null ? null : _set(stage.copyWith(loopCap: n)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _gateLabel(PipelineGateKind gate) => switch (gate) {
    PipelineGateKind.auto => 'Go on when it is done',
    PipelineGateKind.approval => 'Ask me to approve the hand-off',
    PipelineGateKind.check => 'Run checks; go on if they pass',
  };

  static void _insert(TextEditingController controller, String field) {
    final selection = controller.selection;
    final text = controller.text;
    final at = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    controller.value = TextEditingValue(
      text: text.replaceRange(at, end, field),
      selection: TextSelection.collapsed(offset: at + field.length),
    );
  }
}

/// Inserts a template field: the run's input, a loop's feedback, and each
/// earlier stage's answer, artifacts, worktree, branch and checks.
class _FieldMenu extends StatelessWidget {
  const _FieldMenu({
    required this.index,
    required this.stages,
    required this.onPick,
  });

  final int index;
  final List<PipelineStage> stages;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final fields = <(String, String)>[
      ('{{input}}', 'What the run was started with'),
      if (index > 0) ('{{previous.answer}}', "The previous stage's hand-off"),
      for (final s in stages.take(index)) ...[
        ('{{${s.key}.answer}}', "${s.role}'s answer"),
        ('{{${s.key}.artifact:spec.md}}', 'An artifact ${s.role} wrote'),
        ('{{${s.key}.worktree}}', "${s.role}'s worktree"),
        ('{{${s.key}.branch}}', "${s.role}'s branch"),
        ('{{${s.key}.checks}}', "${s.role}'s checks"),
      ],
      ('{{loop.feedback}}', 'Why the run came back here'),
    ];
    return PopupMenuButton<String>(
      key: ValueKey('pipeline-editor-fields:$index'),
      tooltip: 'Insert a field',
      icon: const Icon(AppIcons.plusCircle),
      onSelected: onPick,
      itemBuilder: (_) => [
        for (final (field, meaning) in fields)
          PopupMenuItem(
            value: field,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(field),
              subtitle: Text(meaning),
            ),
          ),
      ],
    );
  }
}
