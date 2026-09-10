import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../terminal/application/terminal_profiles.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import '../application/snippet_providers.dart';
import '../domain/command_snippet.dart';

/// The dropdown's stand-in for "no tag". A sentinel, because a
/// `DropdownButtonFormField` reads null as *nothing selected* and shows a hint.
const _anyShell = '';

/// What the user typed in [SnippetEditorDialog].
class SnippetDraft {
  const SnippetDraft({
    required this.label,
    required this.command,
    required this.shellId,
    required this.submit,
  });

  final String label;
  final String command;
  final String? shellId;
  final bool submit;
}

/// Writes one snippet: what it is called, the command, which shell it is for,
/// and whether picking it presses Enter.
class SnippetEditorDialog extends ConsumerStatefulWidget {
  const SnippetEditorDialog({super.key, this.existing, this.suggestedShellId});

  /// The snippet being edited, or null when this is a new one.
  final CommandSnippet? existing;

  /// The shell to preselect for a new snippet — the pane the user was in when
  /// they asked for this, because that is what they are about to write a
  /// command for.
  final String? suggestedShellId;

  static Future<SnippetDraft?> show(
    BuildContext context, {
    CommandSnippet? existing,
    String? suggestedShellId,
  }) => showDialog<SnippetDraft>(
    context: context,
    builder: (_) => SnippetEditorDialog(
      existing: existing,
      suggestedShellId: suggestedShellId,
    ),
  );

  @override
  ConsumerState<SnippetEditorDialog> createState() =>
      _SnippetEditorDialogState();
}

class _SnippetEditorDialogState extends ConsumerState<SnippetEditorDialog> {
  late final _label = TextEditingController(
    text: widget.existing?.label ?? '',
  );
  late final _command = TextEditingController(
    text: widget.existing?.command ?? '',
  );
  late String _shellId =
      widget.existing?.shellId ?? widget.suggestedShellId ?? _anyShell;
  late bool _submit = widget.existing?.submit ?? false;

  @override
  void dispose() {
    _label.dispose();
    _command.dispose();
    super.dispose();
  }

  /// "Any shell" plus one entry per shell this machine can launch — from the
  /// discovered profiles, not [TerminalShell]'s values, so a Mac is not offered
  /// PowerShell. A tag the snippet already carries is kept regardless.
  List<String> _shellOptions() {
    final offered = <String>{
      for (final profile in ref.read(terminalProfilesProvider))
        profile.shell.name,
    };
    final existing = widget.existing?.shellId;
    if (existing != null) offered.add(existing);
    return [_anyShell, ...offered];
  }

  void _save() {
    final command = singleLine(_command.text);
    if (command.isEmpty) return;
    final label = _label.text.trim();
    Navigator.of(context).pop(
      SnippetDraft(
        // A snippet with no name is named by its command, which is what the
        // user would have typed anyway.
        label: label.isEmpty ? command : label,
        command: command,
        shellId: _shellId == _anyShell ? null : _shellId,
        submit: _submit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'New command snippet' : 'Edit snippet',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _label,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Name (optional)',
                  hintText: 'Named by the command itself when left empty',
                ),
              ),
              const SizedBox(height: Insets.md),
              TextField(
                controller: _command,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Command',
                  hintText: 'flutter test --exclude-tags=live-ssh',
                ),
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: theme.textTheme.bodyMedium?.fontSize,
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: Insets.md),
              DropdownButtonFormField<String>(
                initialValue: _shellId,
                isDense: true,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Shell',
                ),
                items: [
                  for (final option in _shellOptions())
                    DropdownMenuItem(
                      value: option,
                      child: Text(
                        option == _anyShell
                            ? 'Any shell'
                            : shellTagLabel(option),
                      ),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _shellId = value ?? _anyShell),
              ),
              const SizedBox(height: Insets.sm),
              Text(
                'A tagged snippet is only offered in a pane running that '
                'shell. Leave it on "Any shell" for something that works '
                'everywhere.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.md),
              CheckboxListTile(
                value: _submit,
                onChanged: (value) => setState(() => _submit = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('Run it as soon as it is picked'),
                subtitle: Text(
                  'Off by default: the command is typed at the prompt and '
                  'waits for you to press Enter. Turn this on only for a '
                  'command that is safe to run by accident.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// The whole snippet library: what is saved, and how to add, edit or remove
/// one. The *picking* surface is quick open; this is where things are kept.
class SnippetLibraryDialog extends ConsumerWidget {
  const SnippetLibraryDialog({super.key, this.suggestedShellId});

  final String? suggestedShellId;

  static Future<void> show(BuildContext context, {String? suggestedShellId}) =>
      showDialog<void>(
        context: context,
        builder: (_) =>
            SnippetLibraryDialog(suggestedShellId: suggestedShellId),
      );

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final draft = await SnippetEditorDialog.show(
      context,
      suggestedShellId: suggestedShellId,
    );
    if (draft == null) return;
    ref
        .read(commandSnippetsProvider.notifier)
        .add(
          label: draft.label,
          command: draft.command,
          shellId: draft.shellId,
          submit: draft.submit,
        );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    CommandSnippet snippet,
  ) async {
    final draft = await SnippetEditorDialog.show(context, existing: snippet);
    if (draft == null) return;
    ref
        .read(commandSnippetsProvider.notifier)
        .edit(
          snippet.id,
          label: draft.label,
          command: draft.command,
          shellId: draft.shellId,
          submit: draft.submit,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final snippets = ref.watch(commandSnippetsProvider);
    return AlertDialog(
      title: const Text('Command snippets'),
      contentPadding: const EdgeInsets.symmetric(vertical: Insets.sm),
      content: SizedBox(
        width: 520,
        child: snippets.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Insets.xl),
                child: Text(
                  'Nothing saved yet. A snippet is a command you keep so you '
                  'can pick it instead of retyping it — in any terminal, from '
                  'the palette or the toolbar.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            : ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: snippets.length,
                itemBuilder: (context, index) {
                  final snippet = snippets[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(
                      AppIcons.bookBookmark,
                      size: Chrome.icon,
                    ),
                    title: Text(
                      snippet.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      snippet.command,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: kMonoFamily,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          snippet.submit
                              ? '${shellTagLabel(snippet.shellId)} · runs'
                              : shellTagLabel(snippet.shellId),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: Insets.sm),
                        IconButton(
                          tooltip: 'Edit ${snippet.label}',
                          icon: const Icon(
                            AppIcons.pencilSimple,
                            size: Chrome.icon,
                          ),
                          onPressed: () => _edit(context, ref, snippet),
                        ),
                        IconButton(
                          tooltip: 'Delete ${snippet.label}',
                          icon: const Icon(AppIcons.trash, size: Chrome.icon),
                          onPressed: () => ref
                              .read(commandSnippetsProvider.notifier)
                              .delete(snippet.id),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () => _add(context, ref),
          icon: const Icon(AppIcons.plus, size: Chrome.icon),
          label: const Text('New snippet'),
        ),
      ],
    );
  }
}
