import 'package:flutter/material.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';

/// The title and body of a pull request about to be opened. `gh` would take
/// these from an editor it opens in a terminal there is none of here, so the
/// app asks for them plainly — and shows what it will do with them.
class PullRequestDialog extends StatefulWidget {
  const PullRequestDialog({required this.branch, this.title = '', super.key});

  /// The branch the request will be opened from, so the dialog can say it.
  final String branch;

  /// What the title field starts as — the last commit's subject, usually.
  final String title;

  /// The title and body, or null when the user backed out.
  static Future<({String title, String body})?> ask(
    BuildContext context, {
    required String branch,
    String title = '',
  }) => showDialog<({String title, String body})>(
    context: context,
    builder: (_) => PullRequestDialog(branch: branch, title: title),
  );

  @override
  State<PullRequestDialog> createState() => _PullRequestDialogState();
}

class _PullRequestDialogState extends State<PullRequestDialog> {
  late final _title = TextEditingController(text: widget.title);
  final _body = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Open a pull request'),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'From ${widget.branch}, through gh, against the branch the '
              'repository defaults to.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _body,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Description',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ListenableBuilder(
          listenable: _title,
          builder: (context, _) => FilledButton(
            onPressed: _title.text.trim().isEmpty
                ? null
                : () => Navigator.of(
                    context,
                  ).pop((title: _title.text.trim(), body: _body.text.trim())),
            child: const Text('Create'),
          ),
        ),
      ],
    );
  }
}
