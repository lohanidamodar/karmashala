import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/menus.dart';
import '../application/explorer_sections.dart';
import '../domain/explorer_section.dart';
import 'package:karmashala_ui/rows.dart';

/// One section's header: the disclosure, the name, what it holds, its menu.
class ExplorerSectionHeader extends ConsumerWidget {
  const ExplorerSectionHeader({required this.section, this.count, super.key});

  final ExplorerSection section;

  /// How many rows the section holds, or null while it is collapsed.
  final int? count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
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
      kind: ExplorerRowKind.group,
      depth: 0,
      selected: false,
      expanded: !section.collapsed,
      onTap: () => controller.toggleCollapsed(section.id),
      menuItemsBuilder: items,
      onMenu: onAction,
      builder: (context) => ExplorerRowLine(
        lead: ExplorerRowLead(
          expanded: !section.collapsed,
          glyph: Icon(
            _glyphFor(section.rule.kind),
            size: ExplorerRow.glyphSize,
            // Pinned wears the accent the pin glyph on every row already wears,
            // so the group and the rows in it are visibly the same idea.
            color: section.isPinned ? scheme.tertiary : scheme.onSurfaceVariant,
          ),
        ),
        title: Text(
          section.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: density.rowTitle(theme),
        ),
        trailing: ExplorerRowTrailing(
          meta: count == null ? null : ExplorerRowMeta('$count'),
          menu: RowMenuButton(
            tooltip: 'Section actions',
            itemBuilder: items,
            onSelected: onAction,
          ),
        ),
      ),
    );
  }
}

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
