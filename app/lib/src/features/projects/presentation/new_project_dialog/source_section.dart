// Where a new project comes from, and the widgets that section draws.

part of '../new_project_dialog.dart';

// `State.setState` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

extension _NewProjectSource on _NewProjectDialogState {
  /// Where the project comes from: a repository to clone, a folder on the
  /// machine, or both — a clone lands in the folder — and how the folder will
  /// be stored there.
  Widget _source({
    required bool isSsh,
    required bool hasGit,
    required String? preview,
    required bool missing,
    required bool createsFolders,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _gitUrlController,
        decoration: const InputDecoration(
          labelText: 'Git repository URL (optional)',
          hintText: 'https://github.com/owner/repo.git',
        ),
        onChanged: (_) {
          setState(_suggestName);
          _schedulePreview();
        },
      ),
      const SizedBox(height: Insets.md),
      PathFieldRow.inDialog(
        controller: _folderController,
        label: isSsh
            ? (hasGit ? 'Remote folder path (optional)' : 'Remote folder path')
            : (hasGit ? 'Destination folder path' : 'Folder path'),
        hint: isSsh
            ? (hasGit ? '~/karmashala/<repo>' : '/home/user/project')
            : (Platform.isWindows ? r'C:\src\karmashala' : '~/src/karmashala'),
        helper: isSsh && hasGit
            ? 'Defaults to ~/karmashala/<repo> on remote host'
            : null,
        onChanged: (_) {
          setState(() {
            _suggestName();
            _suggestWorkspace();
          });
          _schedulePreview();
        },
        actions: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _browse,
            icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
            label: const Text('Browse'),
          ),
        ],
      ),
      if (preview != null)
        Padding(
          padding: const EdgeInsets.only(top: Insets.xs),
          child: Text(
            'Stored as: $preview',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (missing)
        _MissingFolder(
          createsFolders: createsFolders,
          createFolder: _createFolder,
          initGit: _initGit,
          enabled: !_busy,
          onCreateFolder: (on) => setState(() => _createFolder = on),
          onInitGit: (on) => setState(() => _initGit = on),
        ),
    ],
  );
}

/// Under a folder that is not there yet: whether to make it, and `git init`
/// it — or, from a server too old to make one, that it cannot.
class _MissingFolder extends StatelessWidget {
  const _MissingFolder({
    required this.createsFolders,
    required this.createFolder,
    required this.initGit,
    required this.enabled,
    required this.onCreateFolder,
    required this.onInitGit,
  });

  final bool createsFolders;
  final bool createFolder;
  final bool initGit;
  final bool enabled;
  final ValueChanged<bool> onCreateFolder;
  final ValueChanged<bool> onInitGit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            createsFolders
                ? "This folder doesn't exist yet."
                : "This folder doesn't exist yet, and this server is too old "
                      'to create it. Update the server, or create the folder '
                      'first.',
            key: const ValueKey('new-project-missing-folder'),
            style: muted,
          ),
          if (createsFolders) ...[
            CheckboxListTile(
              key: const ValueKey('new-project-create-folder'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: createFolder,
              onChanged: enabled ? (on) => onCreateFolder(on ?? false) : null,
              title: const Text('Create this folder'),
            ),
            if (createFolder)
              CheckboxListTile(
                key: const ValueKey('new-project-init-git'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: initGit,
                onChanged: enabled ? (on) => onInitGit(on ?? false) : null,
                title: const Text('Initialise Git'),
              ),
          ],
        ],
      ),
    );
  }
}

/// The context picker: which of the user's four or five contexts this project
/// belongs to. Prefilled from the folder, and a plain "None" is a complete
/// answer — an unassigned project is an ordinary project. [naming] swaps the
/// dropdown for a field that names a new context.
class _ContextField extends StatelessWidget {
  const _ContextField({
    required this.workspaces,
    required this.selectedId,
    required this.naming,
    required this.newName,
    required this.enabled,
    required this.onSelected,
    required this.onStartNaming,
    required this.onStopNaming,
  });

  final List<Workspace> workspaces;
  final String? selectedId;
  final bool naming;
  final TextEditingController newName;
  final bool enabled;
  final ValueChanged<String?> onSelected;
  final VoidCallback onStartNaming;
  final VoidCallback onStopNaming;

  @override
  Widget build(BuildContext context) {
    if (naming) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: newName,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'New context',
                hintText: 'Game dev',
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          IconButton(
            tooltip: 'Pick an existing context instead',
            icon: const Icon(AppIcons.x, size: Chrome.icon),
            onPressed: enabled ? onStopNaming : null,
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: DropdownButtonFormField<String?>(
            initialValue: selectedId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Context',
              helperText: 'Suggested from the folder. Change it or leave it.',
            ),
            items: [
              const DropdownMenuItem(value: null, child: _Choice('None')),
              for (final workspace in workspaces)
                DropdownMenuItem(
                  value: workspace.id,
                  child: _Choice(workspace.name),
                ),
            ],
            onChanged: enabled ? onSelected : null,
          ),
        ),
        const SizedBox(width: Insets.sm),
        IconButton(
          tooltip: 'New context',
          icon: const Icon(AppIcons.plus, size: Chrome.icon),
          onPressed: enabled ? onStartNaming : null,
        ),
      ],
    );
  }
}

/// What the folder turned out to hold, read-only (board N3): git and its
/// remote, the app kind, and the agents' earlier conversations there. A clone
/// says only what its URL does, the folder not existing yet.
class _ProjectSourceFacts extends StatelessWidget {
  const _ProjectSourceFacts({
    required this.cloneUrl,
    required this.preview,
    required this.reading,
  });

  final String? cloneUrl;
  final ProjectSourcePreview? preview;
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final url = cloneUrl;
    final lines = <Widget>[];
    void fact(IconData icon, Color colour, String text) =>
        lines.add(_FactLine(icon: icon, colour: colour, text: text));

    if (url != null) {
      fact(
        AppIcons.gitBranch,
        semantic.idle,
        'Git repository to clone · ${repoNameFromUrl(url)} from $url',
      );
      fact(
        AppIcons.info,
        muted,
        'The app kind and earlier conversations are read once it is cloned.',
      );
    } else if (preview == null) {
      fact(
        AppIcons.circle,
        muted,
        reading ? 'Looking in the folder…' : 'Nothing read yet.',
      );
    } else {
      final p = preview!;
      switch (p.git) {
        case GitPresence.notARepository:
          fact(AppIcons.info, muted, 'Not a Git repository · a plain folder');
        case GitPresence.unknown:
          fact(AppIcons.question, muted, 'Whether it is under Git is unknown');
        case GitPresence.repository:
          final parts = [
            'Git repository',
            ?p.branch,
            p.remote == null ? 'no remote' : 'remote ${p.remote}',
          ];
          fact(AppIcons.check, semantic.idle, parts.join(' · '));
      }
      final app = p.app;
      if (app != null) {
        fact(
          AppIcons.check,
          semantic.idle,
          '${app.kind.label} app found'
          '${app.evidence.isEmpty ? '' : ' · ${app.evidence.first}'}',
        );
      } else {
        fact(AppIcons.info, muted, p.appNote ?? 'No app project found');
      }
      final counts = p.conversations;
      if (counts == null) {
        fact(AppIcons.question, muted, 'Earlier conversations: not read');
      } else if (p.conversationCount == 0) {
        fact(AppIcons.info, muted, 'No earlier agent conversations here');
      } else {
        final by = [
          for (final e in counts.entries) '${e.key} ${e.value}',
        ].join(', ');
        fact(
          AppIcons.chatCircleDots,
          theme.colorScheme.primary,
          '${p.conversationCount} earlier conversation'
          '${p.conversationCount == 1 ? '' : 's'} here ($by) · refreshing '
          'the project’s sessions imports them',
        );
      }
      if (reading) {
        fact(AppIcons.circle, muted, 'Looking again…');
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.sm,
      ),
      decoration: BoxDecoration(
        color: SurfaceTones.of(context).raised,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, line) in lines.indexed) ...[
            if (i > 0) const SizedBox(height: Insets.xs),
            line,
          ],
        ],
      ),
    );
  }
}

/// One detected fact: a marker that is not colour alone, and the words.
class _FactLine extends StatelessWidget {
  const _FactLine({
    required this.icon,
    required this.colour,
    required this.text,
  });

  final IconData icon;
  final Color colour;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: Chrome.icon, color: colour),
      const SizedBox(width: Insets.sm),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
    ],
  );
}

/// A dropdown choice: one line, ellipsized, because environment and context
/// names are the user's own and have no length.
class _Choice extends StatelessWidget {
  const _Choice(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
}
