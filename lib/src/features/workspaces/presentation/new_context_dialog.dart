import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../application/workspaces_controller.dart';
import '../domain/workspace.dart';

/// Names a new context and returns it, so the caller can put something in it
/// straight away.
///
/// Exists because "put this project in a context" and "there is no context yet"
/// are the same moment for a user who has never made one. Sending them to the
/// manage dialog would make it three steps — create it, find the project, pick
/// the context — for a decision they have already made. This asks the one
/// question it has to and hands the context back.
///
/// Two fields, one of them optional: the name is what a picker shows, and the
/// description is the line that makes "Appwrite" mean something six weeks
/// later.
class NewContextDialog extends ConsumerStatefulWidget {
  const NewContextDialog({this.forProjectNamed, super.key});

  /// Whose sake this is being created for, named in the subtitle so the dialog
  /// says what will happen when it closes.
  final String? forProjectNamed;

  static Future<Workspace?> show(
    BuildContext context, {
    String? forProjectNamed,
  }) => showDialog<Workspace>(
    context: context,
    builder: (_) => NewContextDialog(forProjectNamed: forProjectNamed),
  );

  @override
  ConsumerState<NewContextDialog> createState() => _NewContextDialogState();
}

class _NewContextDialogState extends ConsumerState<NewContextDialog> {
  final _name = TextEditingController();
  final _description = TextEditingController();
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
      final workspace = ref
          .read(workspacesControllerProvider.notifier)
          .create(name, description: _description.text);
      Navigator.of(context).pop(workspace);
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
      // The column is three fields tall at most, and at 720x560 with text at
      // 1.3x that is the case where the buttons would otherwise leave the
      // window.
      scrollable: true,
      title: DesktopDialogTitle(
        icon: AppIcons.folderPlus,
        title: 'New context',
        subtitle: project == null
            ? 'Group projects by what they are for.'
            : 'Create it and move "$project" into it.',
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
        FilledButton(onPressed: _create, child: const Text('Create')),
      ],
    );
  }
}
