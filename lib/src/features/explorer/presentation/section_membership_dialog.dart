import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/explorer_sections.dart';
import '../domain/explorer_section.dart';

/// Which hand-filled sections one session is in. Only the manual ones: pinning
/// has its own verb on the same menu, and rule sections have nothing to decide —
/// a checkbox that could not be honoured would be a lie with a tick in it.
class SectionMembershipDialog extends ConsumerWidget {
  const SectionMembershipDialog({required this.sessionId, super.key});

  final String sessionId;

  static Future<void> show(
    BuildContext context,
    WidgetRef ref,
    String sessionId,
  ) => showDialog<void>(
    context: context,
    builder: (context) => SectionMembershipDialog(sessionId: sessionId),
  );

  /// Whether this dialog has anything to offer. The row menus ask before
  /// drawing the entry: one that opens an empty dialog teaches distrust.
  static bool hasManualSections(WidgetRef ref) => ref
      .watch(explorerSectionsProvider)
      .any((section) => section.rule.kind == SectionRuleKind.manual);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = [
      for (final section in ref.watch(explorerSectionsProvider))
        if (section.rule.kind == SectionRuleKind.manual) section,
    ];
    final controller = ref.read(explorerSectionsProvider.notifier);

    return AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.folder,
        title: 'Add to section',
        subtitle: 'Sections you fill by hand.',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final section in sections)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: section.members.contains(sessionId),
                title: Text(section.name),
                onChanged: (checked) => (checked ?? false)
                    ? controller.addMember(section.id, sessionId)
                    : controller.removeMember(section.id, sessionId),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
