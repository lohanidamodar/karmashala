import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../environments/application/environment_values.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/checkout_picker.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../explorer/application/session_selection.dart';
import '../../explorer/presentation/explorer_project_row.dart'
    show ProjectRowActions, showProjectMenu;
import '../../explorer/presentation/explorer_selection_actions.dart'
    show SelectionOrderScope;
import '../../explorer/presentation/session_rows.dart';
import '../../explorer/presentation/session_selection_bar.dart';
import '../../file_explorer/application/file_explorer_providers.dart'
    show fileListingRefreshProvider;
import '../../file_explorer/presentation/file_explorer_view.dart'
    show FileTreeList;
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/presentation/archive_session_action.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_notice.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart' show SettingsCard;
import '../../workspaces/application/workspaces_controller.dart';
import '../application/project_page.dart';
import '../application/projects_controller.dart';
import 'edit_project_dialog.dart';

/// **A project's page** (owner, 2026-11-13): what it is and where, its
/// settings, its checkouts and worktrees, its sessions and its files, one
/// section at a time — and the verbs to manage each. A tab per project on the
/// desktop, a page on the phone. Built only while it is on screen.
class ProjectTabView extends ConsumerWidget {
  const ProjectTabView({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref.watch(projectByIdProvider(projectId));
    if (project == null) {
      return const PanePlaceholder(
        message: 'This project is no longer in the workspace.',
        icon: AppIcons.folder,
      );
    }
    final section = ref.watch(projectPageSectionProvider(projectId));
    final actions = ProjectRowActions(ref, context, project);
    return WorkbenchTabScaffold(
      key: ValueKey('project-page:$projectId'),
      icon: AppIcons.folder,
      title: project.name,
      controls: [
        CompactSegmented<ProjectSection>(
          key: const ValueKey('project-section'),
          tight: WidthClass.of(MediaQuery.sizeOf(context).width).isCompact,
          segments: [
            for (final value in ProjectSection.values)
              ButtonSegment(
                value: value,
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value.label,
                    key: ValueKey('project-section:${value.name}'),
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
          ],
          selected: section,
          onChanged: (value) => ref
              .read(projectPageSectionsProvider.notifier)
              .show(projectId, value),
        ),
      ],
      actions: [
        IconButton(
          key: const ValueKey('project-page-new-session'),
          tooltip: 'New session',
          icon: const Icon(AppIcons.plus),
          onPressed: () => unawaited(actions.startWithDefaults()),
        ),
        IconButton(
          key: const ValueKey('project-page-terminal'),
          tooltip: 'Open terminal',
          icon: const Icon(AppIcons.terminal),
          onPressed: actions.openTerminal,
        ),
        Builder(
          builder: (anchor) => IconButton(
            key: const ValueKey('project-page-menu'),
            tooltip: 'Project actions',
            icon: const Icon(AppIcons.dotsThree),
            onPressed: () =>
                unawaited(showProjectMenu(anchor, ref, project, page: false)),
          ),
        ),
      ],
      body: switch (section) {
        ProjectSection.details => _DetailsSection(project: project),
        ProjectSection.checkouts => _CheckoutsSection(project: project),
        ProjectSection.sessions => _SessionsSection(project: project),
        ProjectSection.files => _FilesSection(project: project),
      },
    );
  }
}

void _say(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// A section's column: the readable width, from a phone up.
class _Column extends StatelessWidget {
  const _Column({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(Insets.lg),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Chrome.readableWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    ],
  );
}

/// A titled group of rows on the page.
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Insets.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EyebrowLabel(title),
        const SizedBox(height: Insets.sm),
        ...children,
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Details and settings

class _DetailsSection extends ConsumerWidget {
  const _DetailsSection({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final missing =
        ref.watch(projectPathMissingProvider(project)).asData?.value ?? false;
    final machine = ref.watch(
      environmentLabelForIdProvider(project.environmentId),
    );
    final workspaces = ref.watch(workspacesControllerProvider);
    final contextName = workspaces
        .where((w) => w.id == project.workspaceId)
        .map((w) => w.name)
        .firstOrNull;
    final counts = ref.watch(projectSessionCountsProvider(project.id));
    final tree = ref.watch(projectCheckoutTreeProvider(project.id));
    final worktrees = [
      for (final checkout in tree)
        if (checkout.isWorktree) checkout,
      for (final checkout in tree) ...checkout.worktrees,
    ].length;
    final checkouts = tree.where((c) => !c.isWorktree).length;
    final label = MediaQuery.textScalerOf(
      context,
    ).scale(Chrome.projectFactLabel);
    Widget fact(String name, Widget value, {Widget? trailing}) =>
        LabeledValueRow(
          label: name,
          labelWidth: label,
          value: value,
          trailing: trailing,
          padding: const EdgeInsets.only(bottom: Insets.sm),
        );
    Widget text(String value, {Key? key}) =>
        Text(value, key: key, style: theme.textTheme.bodyMedium);

    return _Column(
      children: [
        if (missing) ...[
          SettingsNotice(
            tone: SettingsNoticeTone.danger,
            message:
                'Its folder is not there any more. Point the project at '
                'where it lives with Move, or remove it.',
          ),
          const SizedBox(height: Insets.md),
        ],
        _Group(
          title: 'Details',
          children: [
            fact(
              'Machine',
              text(machine, key: const ValueKey('project-fact-machine')),
            ),
            fact(
              'Folder',
              SelectableText(project.root.path, style: MonoStyles.body),
              trailing: IconButton(
                tooltip: 'Copy path',
                iconSize: Chrome.iconSmall,
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.copySimple),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: project.root.path),
                  );
                  if (context.mounted) _say(context, 'Path copied.');
                },
              ),
            ),
            fact('Context', text(contextName ?? 'None')),
            fact('Added', text(_date(project.createdAt.toLocal()))),
            fact(
              'Sessions',
              text(
                counts.archived == 0
                    ? '${counts.total}'
                    : '${counts.total} · ${counts.archived} archived',
                key: const ValueKey('project-fact-sessions'),
              ),
            ),
            fact(
              'Checkouts',
              text(
                worktrees == 0
                    ? '$checkouts'
                    : '$checkouts · $worktrees '
                          '${worktrees == 1 ? 'worktree' : 'worktrees'}',
                key: const ValueKey('project-fact-checkouts'),
              ),
            ),
          ],
        ),
        _Group(
          title: 'Settings',
          children: [
            _NameRow(project: project),
            _ContextRow(project: project),
            _DefaultCheckoutRow(project: project),
            SettingsRow(
              label: 'Pinned',
              help: 'Kept at the top of the Explorer.',
              control: Switch(
                key: const ValueKey('project-setting-pinned'),
                value: ref.watch(
                  settingsControllerProvider.select(
                    (s) => s.isPinned(project.id),
                  ),
                ),
                onChanged: (_) =>
                    ProjectRowActions(ref, context, project).togglePin(),
              ),
            ),
            SettingsRow(
              label: 'Machine and folder',
              help: 'Moving it rewrites the checkouts under it.',
              control: OutlinedButton(
                key: const ValueKey('project-setting-move'),
                onPressed: () =>
                    unawaited(EditProjectDialog.show(context, project)),
                child: const Text('Move…'),
              ),
            ),
          ],
        ),
        _Group(
          title: 'Remove',
          children: [
            SettingsRow(
              label: 'Remove from workspace',
              help: 'Its sessions leave Karmashala. The folder on disk stays.',
              control: OutlinedButton(
                key: const ValueKey('project-setting-remove'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed: () =>
                    ProjectRowActions(ref, context, project).onMenu('delete'),
                child: const Text('Remove…'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _date(DateTime at) =>
      '${at.year}-${_two(at.month)}-${_two(at.day)}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// The project's name, saved on Enter or when the field is left.
class _NameRow extends ConsumerStatefulWidget {
  const _NameRow({required this.project});

  final Project project;

  @override
  ConsumerState<_NameRow> createState() => _NameRowState();
}

class _NameRowState extends ConsumerState<_NameRow> {
  late final _controller = TextEditingController(text: widget.project.name);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) unawaited(_save());
    });
  }

  @override
  void didUpdateWidget(_NameRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Renamed elsewhere while this field is not being typed in.
    if (!_focus.hasFocus && widget.project.name != oldWidget.project.name) {
      _controller.text = widget.project.name;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _controller.text.trim();
    if (name == widget.project.name) return;
    if (name.isEmpty) {
      _controller.text = widget.project.name;
      return;
    }
    try {
      await ref
          .read(projectsControllerProvider.notifier)
          .updateProject(widget.project.id, name: name);
      if (mounted) _say(context, 'Renamed to "$name".');
    } on Object catch (error) {
      if (!mounted) return;
      _controller.text = widget.project.name;
      _say(context, 'Could not rename: $error');
    }
  }

  @override
  Widget build(BuildContext context) => SettingsRow(
    label: 'Name',
    control: TextField(
      key: const ValueKey('project-setting-name'),
      controller: _controller,
      focusNode: _focus,
      onSubmitted: (_) => unawaited(_save()),
      decoration: const InputDecoration(isDense: true),
    ),
  );
}

class _ContextRow extends ConsumerWidget {
  const _ContextRow({required this.project});

  final Project project;

  static const _none = '';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspaces = ref.watch(workspacesControllerProvider);
    final current = project.workspaceId ?? _none;
    return SettingsRow(
      label: 'Context',
      help: 'Which group it is filed in.',
      control: DropdownButton<String>(
        key: const ValueKey('project-setting-context'),
        isExpanded: true,
        value: workspaces.any((w) => w.id == current) ? current : _none,
        items: [
          const DropdownMenuItem(value: _none, child: _Choice('No context')),
          for (final workspace in workspaces)
            DropdownMenuItem(
              value: workspace.id,
              child: _Choice(workspace.name),
            ),
        ],
        onChanged: (value) {
          final target = value == null || value == _none ? null : value;
          if (target == project.workspaceId) return;
          unawaited(
            ref
                .read(workspacesControllerProvider.notifier)
                .assign(project.id, target),
          );
        },
      ),
    );
  }
}

class _DefaultCheckoutRow extends ConsumerWidget {
  const _DefaultCheckoutRow({required this.project});

  final Project project;

  static const _first = '';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checkouts = ref.watch(checkoutsInProjectProvider(project.id));
    final current = project.defaultRepositoryId ?? _first;
    return SettingsRow(
      label: 'Default checkout',
      help: 'Where + starts a session.',
      control: DropdownButton<String>(
        key: const ValueKey('project-setting-default-checkout'),
        isExpanded: true,
        value: checkouts.any((c) => c.id == current) ? current : _first,
        items: [
          const DropdownMenuItem(
            value: _first,
            child: _Choice('First checkout (automatic)'),
          ),
          for (final checkout in checkouts)
            DropdownMenuItem(value: checkout.id, child: _Choice(checkout.name)),
        ],
        onChanged: (value) =>
            unawaited(_setDefault(context, ref, project, value)),
      ),
    );
  }
}

Future<void> _setDefault(
  BuildContext context,
  WidgetRef ref,
  Project project,
  String? repositoryId,
) async {
  final id = repositoryId == null || repositoryId.isEmpty ? null : repositoryId;
  if (id == project.defaultRepositoryId) return;
  try {
    await ref
        .read(projectsControllerProvider.notifier)
        .updateProject(
          project.id,
          defaultRepositoryId: id,
          clearDefaultRepository: id == null,
        );
  } on Object catch (error) {
    if (context.mounted) _say(context, 'Could not save: $error');
  }
}

class _Choice extends StatelessWidget {
  const _Choice(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
}

// ---------------------------------------------------------------------------
// Checkouts and worktrees

class _CheckoutsSection extends ConsumerWidget {
  const _CheckoutsSection({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tree = ref.watch(projectCheckoutTreeProvider(project.id));
    if (tree.isEmpty) {
      return PanePlaceholder(
        message: 'No checkout is recorded under this project yet.',
        icon: AppIcons.gitBranch,
        action: OutlinedButton(
          onPressed: () =>
              ProjectRowActions(ref, context, project).onMenu('rescan'),
          child: const Text('Rescan for repositories'),
        ),
      );
    }
    return _Column(
      children: [
        for (final checkout in tree)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CheckoutLine(project: project, checkout: checkout),
                  for (final worktree in checkout.worktrees)
                    _CheckoutLine(
                      project: project,
                      checkout: worktree,
                      indented: true,
                    ),
                ],
              ),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('project-checkouts-rescan'),
            onPressed: () =>
                ProjectRowActions(ref, context, project).onMenu('rescan'),
            icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.iconSmall),
            label: const Text('Rescan for repositories'),
          ),
        ),
      ],
    );
  }
}

/// One checkout or worktree: its name and where, its branch and what git
/// says of it, + for a session there, and its menu.
class _CheckoutLine extends ConsumerWidget {
  const _CheckoutLine({
    required this.project,
    required this.checkout,
    this.indented = false,
  });

  final Project project;
  final ProjectCheckout checkout;
  final bool indented;

  Repository get _repo => checkout.repository;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    final delivery = ref
        .watch(
          checkoutDeliveryProvider(
            Checkout(_repo.path, repository: checkout.parent?.path),
          ),
        )
        .asData
        ?.value;
    final isDefault = project.defaultRepositoryId == _repo.id;
    final branch = checkout.branch ?? delivery?.branch;
    final facts = [
      ?branch,
      if (delivery?.dirtyFiles case final n? when n > 0) '$n changed',
      if (delivery?.aheadOfBase case final n? when n > 0) '$n ahead',
      if (delivery?.behindBase case final n? when n > 0) '$n behind',
      if (delivery?.unpushed case final n? when n > 0) '$n unpushed',
      if (delivery?.pullRequest case final pr?) 'PR #${pr.number}',
    ];
    return Padding(
      key: ValueKey('project-checkout:${_repo.id}'),
      padding: EdgeInsetsDirectional.only(
        start: indented ? Insets.xl : Insets.md,
        end: Insets.xs,
      ),
      child: Row(
        children: [
          Icon(
            checkout.isWorktree ? AppIcons.gitBranch : AppIcons.folder,
            size: Chrome.icon,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _repo.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: density.rowTitle(theme),
                        ),
                      ),
                      if (isDefault) ...[
                        const SizedBox(width: Insets.xs),
                        Text('· default', style: muted),
                      ],
                      if (checkout.isWorktree && checkout.parent == null) ...[
                        const SizedBox(width: Insets.xs),
                        Text('· worktree', style: muted),
                      ],
                    ],
                  ),
                  Text(
                    _repo.path.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                  if (facts.isNotEmpty)
                    Text(
                      facts.join(' · '),
                      key: ValueKey('project-checkout-facts:${_repo.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'New session here',
            iconSize: Chrome.iconSmall,
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.plus),
            onPressed: () => unawaited(_startHere(context, ref)),
          ),
          RowMenuButton(
            key: ValueKey('project-checkout-menu:${_repo.id}'),
            tooltip: 'Checkout actions',
            itemBuilder: () => [
              DesktopMenuItem(
                value: 'new',
                label: 'New session here',
                icon: AppIcons.plus,
              ),
              DesktopMenuItem(
                value: 'terminal',
                label: 'Open terminal here',
                icon: AppIcons.terminal,
              ),
              DesktopMenuItem(
                value: 'files',
                label: 'Browse files',
                icon: AppIcons.folderOpen,
              ),
              DesktopMenuItem(
                value: 'copy',
                label: 'Copy path',
                icon: AppIcons.copySimple,
              ),
              if (!checkout.isWorktree && !isDefault)
                DesktopMenuItem(
                  value: 'default',
                  label: 'Make default',
                  icon: AppIcons.check,
                ),
              if (checkout.isWorktree) ...[
                const DesktopMenuDivider(),
                DesktopMenuItem(
                  value: 'remove',
                  label: 'Remove worktree…',
                  icon: AppIcons.trash,
                  destructive: true,
                ),
              ],
            ],
            onSelected: (value) => unawaited(_act(context, ref, value)),
          ),
        ],
      ),
    );
  }

  Future<void> _startHere(BuildContext context, WidgetRef ref) async {
    final result = await ref
        .read(explorerActionsProvider)
        .startSession(repository: _repo);
    if (result.message case final message? when context.mounted) {
      _say(context, message);
    }
  }

  Future<void> _act(BuildContext context, WidgetRef ref, String value) async {
    switch (value) {
      case 'new':
        await _startHere(context, ref);
      case 'terminal':
        ProjectRowActions(
          ref,
          context,
          project,
        ).openTerminal(at: _repo.path.path);
      case 'files':
        ref
            .read(projectPageFileRootsProvider.notifier)
            .root(project.id, _repo.path);
        ref
            .read(projectPageSectionsProvider.notifier)
            .show(project.id, ProjectSection.files);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: _repo.path.path));
        if (context.mounted) _say(context, 'Path copied.');
      case 'default':
        await _setDefault(context, ref, project, _repo.id);
      case 'remove':
        await removeProjectWorktree(context, ref, project, checkout);
    }
  }
}

/// "Remove worktree": a worktree a session owns goes through that session's
/// Delete worktree, which keeps its transcript and branch; any other is
/// removed after a confirmation — a second, destructive one when it holds
/// uncommitted changes — and never while a session runs in it.
Future<void> removeProjectWorktree(
  BuildContext context,
  WidgetRef ref,
  Project project,
  ProjectCheckout checkout,
) async {
  final repo = checkout.repository;
  final worktrees = ref.read(projectWorktreesProvider);
  final owners = worktrees.owners(project.id, repo.path);
  if (owners.isNotEmpty) {
    final owner = owners.first;
    if (sessionIsLive(ref, owner)) {
      _say(context, '"${owner.title}" is still running in it. End it first.');
      return;
    }
    await deleteSessionWorktree(context, ref, owner.id);
    if (!context.mounted) return;
    await _rescanQuietly(ref, project.id);
    return;
  }
  final running = [
    for (final row in ref.read(projectPageSessionsProvider(project.id)))
      if (row.native case final session?)
        if (session.repositoryId == repo.id && sessionIsLive(ref, session))
          session,
  ];
  if (running.isNotEmpty) {
    _say(
      context,
      '"${running.first.title}" is still running in it. End it first.',
    );
    return;
  }
  final parent = checkout.parent;
  if (parent == null) {
    _say(
      context,
      'The checkout it was made from is not in this project, so it is not '
      'removed from here.',
    );
    return;
  }
  final delivery = ref
      .read(
        checkoutDeliveryProvider(Checkout(repo.path, repository: parent.path)),
      )
      .asData
      ?.value;
  final dirty = delivery?.dirtyFiles ?? 0;
  final unpushed = delivery?.unpushed ?? 0;
  final branch = checkout.branch;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.trash,
        title: 'Remove worktree "${repo.name}"?',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Text(
          [
            'The folder ${repo.path.path} is removed.',
            if (branch != null) 'The branch $branch is kept.',
            if (unpushed > 0)
              'It has $unpushed unpushed '
                  'commit${unpushed == 1 ? '' : 's'}: they stay on the '
                  'branch, but no remote has them.',
            if (dirty > 0)
              'It has $dirty uncommitted '
                  'change${dirty == 1 ? '' : 's'}, in no commit and no '
                  'branch. They are lost, and this cannot be undone.',
          ].join('\n\n'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        if (dirty > 0)
          DestructiveButton(
            key: const ValueKey('project-worktree-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard and remove'),
          )
        else
          FilledButton(
            key: const ValueKey('project-worktree-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await worktrees.remove(
      projectId: project.id,
      repository: parent.path,
      worktree: repo.path,
      force: dirty > 0,
    );
    if (context.mounted) _say(context, 'Removed the worktree "${repo.name}".');
  } on Object catch (error) {
    if (context.mounted) {
      _say(context, 'Could not remove the worktree: ${_words(error)}');
    }
  }
}

Future<void> _rescanQuietly(WidgetRef ref, String projectId) async {
  try {
    await ref.read(projectsControllerProvider.notifier).rediscover(projectId);
  } on Object {
    // The worktree is gone either way; its row goes at the next rescan.
  }
}

String _words(Object error) => switch (error) {
  StateError(:final message) => message,
  _ => '$error',
};

// ---------------------------------------------------------------------------
// Sessions

class _SessionsSection extends ConsumerWidget {
  const _SessionsSection({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(projectSessionFilterProvider(project.id));
    final rows = ref.watch(projectPageSessionsProvider(project.id));
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final ids = [for (final row in rows) row.native?.id ?? row.imported!.id];
    return SelectionOrderScope(
      order: (kind) => kind == SelectionKind.sessions ? ids : const [],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.md,
              Insets.lg,
              Insets.sm,
            ),
            child: Wrap(
              spacing: Insets.md,
              runSpacing: Insets.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CompactSegmented<ProjectSessionFilter>(
                  key: const ValueKey('project-session-filter'),
                  segments: [
                    for (final value in ProjectSessionFilter.values)
                      ButtonSegment(
                        value: value,
                        label: Text(
                          value.label,
                          key: ValueKey('project-session-filter:${value.name}'),
                        ),
                      ),
                  ],
                  selected: filter,
                  onChanged: (value) => ref
                      .read(projectSessionFiltersProvider.notifier)
                      .show(project.id, value),
                ),
                Text(
                  rows.length == 1 ? '1 session' : '${rows.length} sessions',
                  style: UiDensity.of(context).muted(Theme.of(context)),
                ),
                if (!selecting && rows.isNotEmpty)
                  TextButton(
                    key: const ValueKey('project-sessions-select'),
                    onPressed: () => ref
                        .read(sessionSelectionProvider.notifier)
                        .toggle(ids.first, kind: SelectionKind.sessions),
                    child: const Text('Select'),
                  ),
              ],
            ),
          ),
          if (selecting) const SessionSelectionBar(),
          Expanded(
            child: rows.isEmpty
                ? PanePlaceholder(
                    message: switch (filter) {
                      ProjectSessionFilter.archived =>
                        'No archived session in this project.',
                      _ => 'No session in this project yet.',
                    },
                    icon: AppIcons.chatCircleDots,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: Insets.lg),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      if (row.native case final session?) {
                        return NativeSessionRow(
                          key: ValueKey('project-session:${session.id}'),
                          session: session,
                          depth: 0,
                        );
                      }
                      final imported = row.imported!;
                      return ImportedSessionRow(
                        key: ValueKey('project-session:${imported.id}'),
                        session: imported,
                        depth: 0,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Files

class _FilesSection extends ConsumerWidget {
  const _FilesSection({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tree = ref.watch(projectCheckoutTreeProvider(project.id));
    final folders = <EnvironmentPath>[
      project.root,
      for (final checkout in tree) ...[
        checkout.repository.path,
        for (final worktree in checkout.worktrees) worktree.repository.path,
      ],
    ];
    final seen = <String>{};
    final unique = [
      for (final folder in folders)
        if (seen.add('${folder.environmentId}|${folder.path}')) folder,
    ];
    final chosen = ref.watch(
      projectPageFileRootsProvider.select((roots) => roots[project.id]),
    );
    final root = unique.firstWhere(
      (folder) =>
          chosen != null &&
          folder.environmentId == chosen.environmentId &&
          folder.path == chosen.path,
      orElse: () => project.root,
    );
    final canOpenExternally = ref.watch(
      capabilitiesProvider.select((c) => c.readsServerDisk),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.sm,
            Insets.sm,
            Insets.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<int>(
                  key: const ValueKey('project-files-root'),
                  isExpanded: true,
                  value: unique.indexOf(root),
                  items: [
                    for (final (index, folder) in unique.indexed)
                      DropdownMenuItem(
                        value: index,
                        child: _Choice(
                          index == 0 ? 'Project folder' : _nameOf(folder, tree),
                        ),
                      ),
                  ],
                  onChanged: (index) {
                    if (index == null) return;
                    ref
                        .read(projectPageFileRootsProvider.notifier)
                        .root(project.id, index == 0 ? null : unique[index]);
                  },
                ),
              ),
              if (canOpenExternally)
                IconButton(
                  tooltip: 'Open in editor',
                  icon: const Icon(AppIcons.code),
                  onPressed: () => ProjectRowActions(
                    ref,
                    context,
                    project,
                  ).onMenu('open-editor'),
                ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(AppIcons.arrowsClockwise),
                onPressed: () =>
                    ref.read(fileListingRefreshProvider.notifier).refresh(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: FileTreeList(
            key: ValueKey('project-files:${root.environmentId}|${root.path}'),
            root: root,
          ),
        ),
      ],
    );
  }

  static String _nameOf(EnvironmentPath folder, List<ProjectCheckout> tree) {
    for (final checkout in tree) {
      for (final entry in [checkout, ...checkout.worktrees]) {
        if (entry.repository.path.path == folder.path) {
          return entry.repository.name;
        }
      }
    }
    return folder.path;
  }
}
