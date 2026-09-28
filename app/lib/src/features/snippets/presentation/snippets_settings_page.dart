import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../settings/presentation/settings_section.dart';
import '../../settings/presentation/settings_theme.dart';
import '../application/snippet_providers.dart';
import '../domain/command_snippet.dart';
import 'snippet_dialogs.dart';

/// Settings → Snippets: the saved commands, somewhere a person looks for them.
/// A second view, not a second implementation — the same dialog and controller.
class SnippetsSettingsPage extends ConsumerWidget {
  const SnippetsSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // **Watched, not read**: a snippet saved from the library dialog, the palette
    // or `snippet_add` must appear here with nothing reopened.
    final snippets = ref.watch(commandSnippetsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'COMMAND SNIPPETS',
          trailing: TextButton.icon(
            onPressed: () => _addSnippet(context, ref),
            icon: const Icon(AppIcons.plus),
            label: const Text('New snippet'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SettingsNote(
                r'Pick one from the book button above a terminal, or $ in quick open.',
              ),
              if (snippets.isEmpty)
                const SettingsNote('Nothing saved yet.')
              else
                for (final snippet in snippets)
                  _SnippetCard(key: ValueKey(snippet.id), snippet: snippet),
            ],
          ),
        ),
      ],
    );
  }
}

/// One saved command. The buttons stay drawn and worded — this is a settings
/// form — plus the same actions on right-click, `Shift+F10` and the Menu key.
class _SnippetCard extends ConsumerWidget {
  const _SnippetCard({required this.snippet, super.key});

  final CommandSnippet snippet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return RowContextMenu(
      menuLabel: 'Actions for ${snippet.label}',
      itemBuilder: () => [
        DesktopMenuItem(
          value: 'edit',
          label: 'Edit',
          icon: AppIcons.pencilSimple,
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'delete',
          label: 'Delete',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ],
      onSelected: (value) => value == 'edit'
          ? _editSnippet(context, ref, snippet)
          : _deleteSnippet(context, ref, snippet),
      builder: (context) => ItemCard(
        icon: AppIcons.bookBookmark,
        title: Text(
          snippet.label,
          style: SettingsStyles.rowLabel(context),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        details: [
          Text(
            snippet.command,
            style: MonoStyles.body,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Insets.xs),
          // Said in words rather than left to a badge: this page has the room
          // the palette row does not, and "runs" is the one property of a
          // snippet worth reading before you pick it.
          Text(
            snippet.submit
                ? '${shellTagLabel(snippet.shellId)} · runs as soon as it is '
                      'picked'
                : '${shellTagLabel(snippet.shellId)} · typed at the prompt',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          // A tag from a build that knew more shells than this one matches no
          // pane at all, by design; nothing else in the app can say so.
          if (snippet.hasUnknownShell)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                'This build does not know the shell "${snippet.shellId}", so '
                'this snippet is offered in no terminal. Edit it to pick one.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
        actions: [
          TextButton.icon(
            onPressed: () => _editSnippet(context, ref, snippet),
            icon: const Icon(AppIcons.pencilSimple),
            label: const Text('Edit'),
          ),
          TextButton.icon(
            onPressed: () => _deleteSnippet(context, ref, snippet),
            icon: const Icon(AppIcons.trash),
            label: const Text('Delete'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the editor for a new snippet and saves what comes back. The notifier
/// is resolved **before** the await: `ref` is dead once the widget unmounts.
Future<void> _addSnippet(BuildContext context, WidgetRef ref) async {
  final snippets = ref.read(commandSnippetsProvider.notifier);
  final draft = await SnippetEditorDialog.show(context);
  if (draft == null) return;
  snippets.add(
    label: draft.label,
    command: draft.command,
    shellId: draft.shellId,
    submit: draft.submit,
  );
}

Future<void> _editSnippet(
  BuildContext context,
  WidgetRef ref,
  CommandSnippet snippet,
) async {
  final snippets = ref.read(commandSnippetsProvider.notifier);
  final draft = await SnippetEditorDialog.show(context, existing: snippet);
  if (draft == null) return;
  snippets.edit(
    snippet.id,
    label: draft.label,
    command: draft.command,
    shellId: draft.shellId,
    submit: draft.submit,
  );
}

Future<void> _deleteSnippet(
  BuildContext context,
  WidgetRef ref,
  CommandSnippet snippet,
) async {
  final snippets = ref.read(commandSnippetsProvider.notifier);
  if (await confirmSnippetDelete(context, snippet)) snippets.delete(snippet.id);
}
