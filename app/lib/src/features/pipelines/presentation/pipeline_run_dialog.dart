import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/full_screen_form.dart';
import '../../automations/application/automation_providers.dart'
    show automationCheckoutsProvider;
import '../../git/application/changes_providers.dart'
    show selectedRepositoryIdProvider;
import '../application/pipelines_controller.dart';
import 'pipeline_editor.dart';
import 'pipeline_run_detail.dart';

/// **Run a pipeline**: which one, on which checkout, with what input. A
/// person's run: its stages launch ahead of background work.
Future<void> showRunPipeline(BuildContext context) => showFormDialog<void>(
  context: context,
  builder: (_) => const RunPipelineDialog(),
);

class RunPipelineDialog extends ConsumerStatefulWidget {
  const RunPipelineDialog({super.key});

  @override
  ConsumerState<RunPipelineDialog> createState() => _RunPipelineDialogState();
}

class _RunPipelineDialogState extends ConsumerState<RunPipelineDialog> {
  final _input = TextEditingController();
  String? _pipelineId;
  String? _repositoryId;
  String? _error;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _repositoryId = ref.read(selectedRepositoryIdProvider);
    _input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  PipelineDefinition? _picked(List<PipelineDefinition> all) =>
      all.where((p) => p.id == _pipelineId).firstOrNull ?? all.firstOrNull;

  Future<void> _run(PipelineDefinition definition, String repositoryId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(pipelinesProvider.notifier)
          .start(
            definition: definition,
            repositoryId: repositoryId,
            input: _input.text,
          );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(PipelineDefinition? definition) async {
    final saved = await showPipelineEditor(context, initial: definition);
    if (saved != null && mounted) setState(() => _pipelineId = saved.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(pipelinesProvider);
    final all = state.all.isEmpty ? kPipelineTemplates : state.all;
    final picked = _picked(all);
    final repositories = ref.watch(automationCheckoutsProvider);
    final repositoryId = repositories.any((r) => r.id == _repositoryId)
        ? _repositoryId
        : repositories.firstOrNull?.id;
    final canRun =
        !_busy &&
        picked != null &&
        repositoryId != null &&
        _input.text.trim().isNotEmpty;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('pipeline-run-pick'),
          initialValue: picked?.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Pipeline'),
          items: [
            for (final p in all)
              DropdownMenuItem(
                value: p.id,
                child: Text(p.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (id) => setState(() => _pipelineId = id),
        ),
        if (picked != null && picked.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              picked.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Wrap(
          spacing: Insets.xs,
          children: [
            TextButton.icon(
              key: const ValueKey('pipeline-run-edit'),
              onPressed: picked == null ? null : () => _edit(picked),
              icon: const Icon(AppIcons.pencilSimple),
              label: Text(picked?.builtIn ?? true ? 'Edit a copy…' : 'Edit…'),
            ),
            TextButton.icon(
              key: const ValueKey('pipeline-run-new'),
              onPressed: () => _edit(null),
              icon: const Icon(AppIcons.plus),
              label: const Text('New…'),
            ),
            TextButton.icon(
              key: const ValueKey('pipeline-run-history'),
              onPressed: () => unawaited(showPipelineRuns(context)),
              icon: const Icon(AppIcons.list),
              label: const Text('Runs'),
            ),
          ],
        ),
        const SizedBox(height: Insets.md),
        DropdownButtonFormField<String>(
          key: const ValueKey('pipeline-run-checkout'),
          initialValue: repositoryId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Runs in'),
          hint: const Text('Pick a checkout'),
          items: [
            for (final r in repositories)
              DropdownMenuItem(
                value: r.id,
                child: Text(r.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (id) => setState(() => _repositoryId = id),
        ),
        const SizedBox(height: Insets.sm),
        TextField(
          key: const ValueKey('pipeline-run-input'),
          controller: _input,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'What should it do?',
            alignLabelWithHint: true,
            helperText: 'Every stage gets this as {{input}}.',
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
    final run = FilledButton(
      key: const ValueKey('pipeline-run-start'),
      onPressed: canRun ? () => _run(picked, repositoryId) : null,
      child: const Text('Run'),
    );
    void cancel() => Navigator.of(context).pop();
    if (opensFullScreen(context)) {
      return FullScreenForm(
        title: 'Run a pipeline',
        body: body,
        primary: run,
        onClose: cancel,
      );
    }
    return AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.treeStructure,
        title: 'Run a pipeline',
        subtitle: 'Stages of agents, each handed the last one\'s work.',
      ),
      scrollable: true,
      content: SizedBox(width: DialogWidth.narrow, child: body),
      actions: [
        TextButton(onPressed: cancel, child: const Text('Cancel')),
        run,
      ],
    );
  }
}
