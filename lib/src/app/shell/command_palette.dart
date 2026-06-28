import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/git/application/changes_providers.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/repositories/application/repository_providers.dart';
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import 'shell_state.dart';

/// A `Ctrl+K` command palette: fuzzy-jump to any project or session, or run a
/// quick action — the keyboard-first way around a desktop app.
class CommandPalette extends ConsumerStatefulWidget {
  const CommandPalette({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => const CommandPalette(),
  );

  @override
  ConsumerState<CommandPalette> createState() => _CommandPaletteState();
}

class _PaletteEntry {
  _PaletteEntry({
    required this.label,
    required this.icon,
    required this.onSelect,
    this.sublabel,
  });
  final String label;
  final String? sublabel;
  final IconData icon;
  final VoidCallback onSelect;
}

class _CommandPaletteState extends ConsumerState<CommandPalette> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_PaletteEntry> _entries() {
    final entries = <_PaletteEntry>[];

    void run(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    // Quick actions.
    entries.add(
      _PaletteEntry(
        label: 'New project…',
        icon: AppIcons.folderPlus,
        onSelect: () => run(() => NewProjectDialog.show(context)),
      ),
    );
    if (ref.read(selectedRepositoryIdProvider) != null) {
      entries.add(
        _PaletteEntry(
          label: 'New session…',
          icon: AppIcons.chatCircleDots,
          onSelect: () => run(() => NewSessionDialog.show(context)),
        ),
      );
    }
    entries.add(
      _PaletteEntry(
        label: 'Toggle terminal',
        icon: AppIcons.terminal,
        onSelect: () =>
            run(() => ref.read(terminalVisibleProvider.notifier).toggle()),
      ),
    );
    entries.add(
      _PaletteEntry(
        label: 'Toggle Explorer',
        icon: AppIcons.treeStructure,
        onSelect: () => run(
          () => ref.read(shellControllerProvider.notifier).toggleExplorerPane(),
        ),
      ),
    );
    entries.add(
      _PaletteEntry(
        label: 'Open Settings',
        icon: AppIcons.gearSix,
        onSelect: () => run(() => SettingsScreen.show(context)),
      ),
    );

    // Projects and their sessions.
    final repoDao = ref.read(repositoryDaoProvider);
    final sessionDao = ref.read(sessionDaoProvider);
    final importedDao = ref.read(importedSessionDaoProvider);
    for (final project in ref.read(projectsControllerProvider)) {
      entries.add(
        _PaletteEntry(
          label: project.name,
          sublabel: 'Project',
          icon: AppIcons.folder,
          onSelect: () => run(
            () =>
                ref.read(selectedProjectIdProvider.notifier).select(project.id),
          ),
        ),
      );
      for (final repo in repoDao.getByProject(project.id)) {
        for (final s in sessionDao.getByRepository(repo.id)) {
          entries.add(
            _PaletteEntry(
              label: s.title,
              sublabel: '${project.name} · ${repo.name}',
              icon: AppIcons.chatCircle,
              onSelect: () => run(() {
                ref.read(selectedProjectIdProvider.notifier).select(project.id);
                ref.read(selectedRepositoryIdProvider.notifier).select(repo.id);
                ref
                    .read(selectedImportedSessionIdProvider.notifier)
                    .select(null);
                ref.read(selectedSessionIdProvider.notifier).select(s.id);
              }),
            ),
          );
        }
        for (final s in importedDao.getByRepository(repo.id)) {
          entries.add(
            _PaletteEntry(
              label: s.displayTitle,
              sublabel: '${project.name} · ${repo.name} · imported',
              icon: AppIcons.clockCounterClockwise,
              onSelect: () => run(() {
                ref.read(selectedProjectIdProvider.notifier).select(project.id);
                ref.read(selectedRepositoryIdProvider.notifier).select(repo.id);
                ref.read(selectedSessionIdProvider.notifier).select(null);
                ref
                    .read(selectedImportedSessionIdProvider.notifier)
                    .select(s.id);
              }),
            ),
          );
        }
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();
    final results = _entries().where((e) {
      if (query.isEmpty) return true;
      return e.label.toLowerCase().contains(query) ||
          (e.sublabel?.toLowerCase().contains(query) ?? false);
    }).toList();

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 90, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: TextField(
                controller: _controller,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(AppIcons.magnifyingGlass, size: 18),
                  hintText: 'Jump to a project or session, or run an action…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (results.isNotEmpty) results.first.onSelect();
                },
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Insets.lg),
                      child: Text(
                        'No matches.',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final e = results[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(e.icon, size: 18),
                          title: Text(
                            e.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: e.sublabel == null
                              ? null
                              : Text(
                                  e.sublabel!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: e.onSelect,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
