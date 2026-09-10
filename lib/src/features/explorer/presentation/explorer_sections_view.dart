import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/menus.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/domain/project.dart';
import '../application/checkout.dart';
import '../application/explorer_sections.dart';
import '../domain/explorer_section.dart';
import 'package:karmashala_ui/rows.dart';
import 'session_rows.dart';

/// The saved sections, drawn above the project tree. Returns a list, never a
/// widget: the Explorer's body is one `ListView`, and a `Column` would build
/// every row of every open section. A collapsed one matches nothing, so no count.
List<Widget> explorerSectionNodes(WidgetRef ref) {
  final sections = ref.watch(explorerSectionLayoutProvider).shown;
  if (sections.isEmpty) return const [];

  final nodes = <Widget>[];
  for (final section in sections) {
    if (section.collapsed) {
      nodes.add(_SectionHeader(section: section));
      continue;
    }
    final members = ref.watch(explorerSectionMembersProvider(section.id));
    nodes.add(_SectionHeader(section: section, count: members.length));
    if (members.isEmpty) {
      nodes.add(_SectionEmpty(section: section));
      continue;
    }
    // Where each row is, in the sidebar's own terms: a section crosses
    // projects, so "which one is this" is a fact the tree never supplies.
    final candidates = {
      for (final candidate in ref.watch(sectionCandidatesProvider))
        candidate.id: candidate,
    };
    final projects = {
      for (final project in ref.watch(sortedProjectsProvider))
        project.id: project,
    };
    final pinned = section.isPinned;
    for (final facts in members) {
      final candidate = candidates[facts.id];
      // A member of a hand-filled group whose session has been deleted. The DAO
      // keeps no foreign key on `sessions`, so this is expected, not broken.
      if (candidate == null) continue;
      final where = _whereLabel(candidate, projects);
      final native = candidate.native;
      if (native != null) {
        nodes.add(
          NativeSessionRow(
            key: ValueKey('section:${section.id}:${facts.id}'),
            session: native,
            depth: 1,
            subPath: where,
            pinned: pinned,
          ),
        );
      } else if (candidate.imported case final imported?) {
        nodes.add(
          ImportedSessionRow(
            key: ValueKey('section:${section.id}:${facts.id}'),
            session: imported,
            depth: 1,
            subPath: where,
            pinned: pinned,
          ),
        );
      }
    }
  }
  return nodes;
}

/// Where a section's row lives, as `project/sub/path` — the project name is
/// included here and not in the tree, where it is already established. Falls
/// back to the bare path when the project is not in the sidebar's list.
String? _whereLabel(SectionCandidate candidate, Map<String, Project> projects) {
  final project = projects[candidate.projectId];
  final directory = candidate.worktree ?? candidate.repositoryPath;
  if (project == null) return directory?.path;
  final sub = directory == null
      ? null
      : relativeSubPath(project.root, directory);
  return sub == null || sub.isEmpty ? project.name : '${project.name}/$sub';
}

/// One section's header: the disclosure, the name, what it holds, its menu.
class _SectionHeader extends ConsumerWidget {
  const _SectionHeader({required this.section, this.count});

  final ExplorerSection section;

  /// How many rows the section holds, or null while it is collapsed — see
  /// [explorerSectionNodes].
  final int? count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    final controller = ref.read(explorerSectionsProvider.notifier);

    // One function handed to both the row and its button: `ExplorerRow` carries
    // the right-click and keyboard paths, `RowMenuButton` the pointer's. A
    // literal would build every entry on every build of every header.
    List<PopupMenuEntry<String>> items() => [
      DesktopMenuItem(value: 'new', label: 'New section…', icon: AppIcons.plus),
      if (section.isEditable) ...[
        DesktopMenuItem(
          value: 'edit',
          label: 'Edit section…',
          icon: AppIcons.pencilSimple,
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'delete',
          label: 'Remove section',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ],
    ];
    Future<void> onAction(String action) async {
      switch (action) {
        case 'new':
          await SectionEditorDialog.show(context, ref);
        case 'edit':
          await SectionEditorDialog.show(context, ref, section: section);
        case 'delete':
          controller.remove(section.id);
      }
    }

    return ExplorerRow(
      kind: ExplorerRowKind.project,
      depth: 0,
      selected: false,
      onTap: () => controller.toggleCollapsed(section.id),
      menuItemsBuilder: items,
      onMenu: onAction,
      builder: (context) => Row(
        children: [
          Icon(
            section.collapsed ? AppIcons.caretRight : AppIcons.caretDown,
            size: density.icon,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 2),
          Icon(
            _glyphFor(section.rule.kind),
            size: density.icon,
            // Pinned wears the accent the pin glyph on every row already wears,
            // so the group and the rows in it are visibly the same idea.
            color: section.isPinned ? scheme.tertiary : scheme.onSurfaceVariant,
          ),
          SizedBox(width: density.glyphGap),
          Expanded(
            child: Text(
              section.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: density.title(theme),
            ),
          ),
          if (count != null) ...[
            SizedBox(width: density.glyphGap),
            Text('$count', style: muted),
          ],
          RowMenuButton(
            tooltip: 'Section actions',
            itemBuilder: items,
            onSelected: onAction,
          ),
        ],
      ),
    );
  }
}

/// What an open, empty section says — *why* it is empty, because "nothing
/// matches" and "nothing has been measured yet" have different fixes, and the
/// second is real: a pull request is read when a strip asks, never on a sweep.
class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({required this.section});

  final ExplorerSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xs + ExplorerRow.indent + Insets.lg,
        Insets.xs,
        Insets.sm,
        Insets.sm,
      ),
      child: Text(
        emptySectionMessage(section.rule),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The sentence an empty [rule] deserves.
String emptySectionMessage(SectionRule rule) => switch (rule.kind) {
  SectionRuleKind.pinned =>
    'Nothing pinned. Use "Pin to top" on a session to keep it here.',
  SectionRuleKind.manual =>
    'Nothing here yet. Use "Add to section…" on a session.',
  SectionRuleKind.checksFailing =>
    'No failing checks among the pull requests this app has read. Open a '
        "session's Delivery strip to have its checks fetched.",
  SectionRuleKind.pullRequestOpen =>
    'No open pull requests among the ones this app has read. Open a '
        "session's Delivery strip to have its pull request fetched.",
  SectionRuleKind.awaitingInput => 'No agent is waiting on you.',
  SectionRuleKind.endedInFailure => 'Nothing has ended in failure.',
  SectionRuleKind.branchGlob =>
    'No session is on a branch matching this pattern. A branch is only known '
        'once something has looked at that checkout.',
};

IconData _glyphFor(SectionRuleKind kind) => switch (kind) {
  SectionRuleKind.pinned => AppIcons.pushPinFill,
  SectionRuleKind.manual => AppIcons.folder,
  SectionRuleKind.checksFailing => AppIcons.warningCircle,
  SectionRuleKind.pullRequestOpen => AppIcons.gitBranch,
  SectionRuleKind.awaitingInput => AppIcons.robot,
  SectionRuleKind.endedInFailure => AppIcons.warning,
  SectionRuleKind.branchGlob => AppIcons.gitBranch,
};

/// How a rule reads in a picker.
String describeRule(SectionRuleKind kind) => switch (kind) {
  SectionRuleKind.pinned => 'Pinned sessions',
  SectionRuleKind.manual => 'Sessions I add by hand',
  SectionRuleKind.checksFailing => 'Checks failing',
  SectionRuleKind.pullRequestOpen => 'Pull request open',
  SectionRuleKind.awaitingInput => 'Agent awaiting input',
  SectionRuleKind.endedInFailure => 'Ended in failure',
  SectionRuleKind.branchGlob => 'Branch matches…',
};

/// Creates a section, or edits one. [SectionRuleKind.pinned] is not offered:
/// there is one Pinned section and `Settings.pinnedSessionIds` is its answer.
class SectionEditorDialog extends StatefulWidget {
  const SectionEditorDialog({required this.section, super.key});

  final ExplorerSection? section;

  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    ExplorerSection? section,
  }) async {
    final result = await showDialog<({String name, SectionRule rule})>(
      context: context,
      builder: (context) => SectionEditorDialog(section: section),
    );
    if (result == null) return;
    final controller = ref.read(explorerSectionsProvider.notifier);
    if (section == null) {
      controller.add(name: result.name, rule: result.rule);
    } else {
      controller.edit(section.id, name: result.name, rule: result.rule);
    }
  }

  @override
  State<SectionEditorDialog> createState() => _SectionEditorDialogState();
}

class _SectionEditorDialogState extends State<SectionEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.section?.name ?? '',
  );
  late final TextEditingController _glob = TextEditingController(
    text: widget.section?.rule.pattern ?? 'release/*',
  );
  late SectionRuleKind _kind =
      widget.section?.rule.kind ?? SectionRuleKind.checksFailing;

  static const _offered = [
    SectionRuleKind.checksFailing,
    SectionRuleKind.pullRequestOpen,
    SectionRuleKind.awaitingInput,
    SectionRuleKind.endedInFailure,
    SectionRuleKind.branchGlob,
    SectionRuleKind.manual,
  ];

  @override
  void dispose() {
    _name.dispose();
    _glob.dispose();
    super.dispose();
  }

  /// The name the user typed, or the rule's own words when they typed nothing —
  /// a nameless section is the common case, and forcing a name gets in the way.
  String get _effectiveName {
    final typed = _name.text.trim();
    if (typed.isNotEmpty) return typed;
    return _kind == SectionRuleKind.branchGlob
        ? _glob.text.trim()
        : describeRule(_kind);
  }

  SectionRule? get _rule => switch (_kind) {
    SectionRuleKind.manual => const ManualRule(),
    SectionRuleKind.checksFailing => const ChecksFailingRule(),
    SectionRuleKind.pullRequestOpen => const PullRequestOpenRule(),
    SectionRuleKind.awaitingInput => const AwaitingInputRule(),
    SectionRuleKind.endedInFailure => const EndedInFailureRule(),
    SectionRuleKind.branchGlob =>
      _glob.text.trim().isEmpty ? null : BranchGlobRule(_glob.text.trim()),
    SectionRuleKind.pinned => null,
  };

  @override
  Widget build(BuildContext context) {
    final editing = widget.section != null;
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.plus,
        title: editing ? 'Edit section' : 'New section',
        subtitle: 'A live group over sessions the app already knows about.',
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: describeRule(_kind),
              ),
            ),
            const SizedBox(height: Insets.md),
            DropdownButtonFormField<SectionRuleKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Rule'),
              items: [
                for (final kind in _offered)
                  DropdownMenuItem(
                    value: kind,
                    child: Text(describeRule(kind)),
                  ),
              ],
              onChanged: (kind) {
                if (kind != null) setState(() => _kind = kind);
              },
            ),
            if (_kind == SectionRuleKind.branchGlob) ...[
              const SizedBox(height: Insets.md),
              TextField(
                controller: _glob,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Branch pattern',
                  helperText:
                      '* matches within one path segment, ** across them, '
                      '? one character.',
                ),
              ),
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
          onPressed: _rule == null
              ? null
              : () => Navigator.of(
                  context,
                ).pop((name: _effectiveName, rule: _rule!)),
          child: Text(editing ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}
