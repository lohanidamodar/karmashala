import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../application/workspaces_controller.dart';
import '../domain/workspace.dart';

/// Names a new context and returns it, so the caller can put something in it
/// straight away: "file this" and "there is no context yet" are one moment.
class NewContextDialog extends ConsumerStatefulWidget {
  const NewContextDialog({
    this.forProjectNamed,
    this.movingCount,
    this.editing,
    super.key,
  });

  /// The context being renamed or re-described; null creates one.
  final Workspace? editing;

  /// Whose sake this is being created for, named in the subtitle so the dialog
  /// says what will happen when it closes.
  final String? forProjectNamed;

  /// How many selected projects will move into it, when it is for several.
  final int? movingCount;

  static Future<Workspace?> show(
    BuildContext context, {
    String? forProjectNamed,
    int? movingCount,
  }) => showDialog<Workspace>(
    context: context,
    builder: (_) => NewContextDialog(
      forProjectNamed: forProjectNamed,
      movingCount: movingCount,
    ),
  );

  /// Renames or re-describes [workspace], and returns it as saved.
  static Future<Workspace?> edit(BuildContext context, Workspace workspace) =>
      showDialog<Workspace>(
        context: context,
        builder: (_) => NewContextDialog(editing: workspace),
      );

  @override
  ConsumerState<NewContextDialog> createState() => _NewContextDialogState();
}

class _NewContextDialogState extends ConsumerState<NewContextDialog> {
  late final _name = TextEditingController(text: widget.editing?.name);
  late final _description = TextEditingController(
    text: widget.editing?.description,
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A context needs a name.');
      return;
    }
    try {
      final controller = ref.read(workspacesControllerProvider.notifier);
      final editing = widget.editing;
      if (editing == null) {
        Navigator.of(
          context,
        ).pop(controller.create(name, description: _description.text));
        return;
      }
      controller.edit(editing.id, name: name, description: _description.text);
      Navigator.of(context).pop(
        ref
            .read(workspacesControllerProvider)
            .where((w) => w.id == editing.id)
            .firstOrNull,
      );
    } on DuplicateWorkspaceName catch (e) {
      setState(() => _error = e.toString());
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.forProjectNamed;
    return AlertDialog(
      // At 720x560 with text at 1.3x the buttons would otherwise leave the window.
      scrollable: true,
      title: DesktopDialogTitle(
        icon: widget.editing == null
            ? AppIcons.folderPlus
            : AppIcons.pencilSimple,
        title: widget.editing == null ? 'New context' : 'Edit context',
        subtitle: switch ((project, widget.movingCount)) {
          _ when widget.editing != null => 'Its projects stay where they are.',
          (final String project, _) => 'Create it and move "$project" into it.',
          (_, final int count) =>
            'Create it and move ${count == 1 ? '1 project' : '$count projects'} '
                'into it.',
          _ => 'Group projects by what they are for.',
        },
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Game dev',
              ),
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _description,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'What this context is for. Optional.',
              ),
              onSubmitted: (_) => _create(),
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              DesktopErrorBanner(_error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _create,
          child: Text(widget.editing == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
