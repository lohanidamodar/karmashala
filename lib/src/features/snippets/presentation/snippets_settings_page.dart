import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/snippet_providers.dart';
import '../domain/command_snippet.dart';
import 'snippet_dialogs.dart';

/// Settings → Snippets: the saved commands, somewhere a person can find them.
///
/// The library already had two doors — the terminal toolbar and quick open —
/// and both are *picking* surfaces you have to already know about. Neither is
/// where anyone looks for "the list of things I have saved", which is Settings,
/// beside the notes and the SSH hosts and everything else the app keeps on the
/// user's behalf. This page is that door; the other two stay exactly as they
/// were.
///
/// It is a second **view**, not a second implementation: the form is
/// [SnippetEditorDialog] and every write goes through
/// [CommandSnippetsController], so the two surfaces cannot drift apart in what
/// a snippet is allowed to be.
class SnippetsSettingsPage extends ConsumerWidget {
  const SnippetsSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // **Watched, not read.** A snippet saved anywhere else — the library
    // dialog, the palette's editor, an agent calling `snippet_add` — must
    // appear here while the page is on screen, with nothing reopened and
    // nothing restarted. See `snippets_settings_page_test.dart`.
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
              Text(
                'A command you keep so you can pick it instead of retyping it. '
                'Picking one types it at the prompt of the terminal you are in '
                'and leaves it there to read — it presses Enter only if you '
                'saved it that way.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.xs),
              Text(
                r'Pick one from the book button above a terminal, or from '
                r'quick open with the $ sigil.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.md),
              if (snippets.isEmpty)
                Text(
                  'Nothing saved yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
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

/// One saved command, and everything you can do to it.
class _SnippetCard extends ConsumerWidget {
  const _SnippetCard({required this.snippet, super.key});

  final CommandSnippet snippet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    AppIcons.bookBookmark,
                    size: Chrome.iconTitle,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    snippet.label,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
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
            // pane at all, by design — see [CommandSnippet.fitsShell]. Nothing
            // else in the app can say so, because everything else has already
            // filtered the snippet out.
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
            const SizedBox(height: Insets.sm),
            Row(
              children: [
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
          ],
        ),
      ),
    );
  }
}

/// Opens the editor for a new snippet and saves what comes back.
///
/// The notifier is resolved **before** the dialog is awaited. `ref` is only
/// usable while its widget is mounted, and a helper written the other way round
/// is one route pop away from throwing instead of saving — which is exactly
/// what happens today when the palette's own "New command snippet…" is used.
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

/// Asks first, the way the SSH hosts section does and the library dialog does not.
///
/// The difference is where the button lives rather than what it does: in a
/// modal you opened to tidy up, a delete is the thing you came for; on a
/// settings page you are browsing, it sits beside Edit with no undo behind it.
Future<void> _deleteSnippet(
  BuildContext context,
  WidgetRef ref,
  CommandSnippet snippet,
) async {
  final snippets = ref.read(commandSnippetsProvider.notifier);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete ${snippet.label}?'),
      content: Text(
        'The command itself is not going anywhere — this only forgets that you '
        'saved it.\n\n${snippet.command}',
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  snippets.delete(snippet.id);
}
