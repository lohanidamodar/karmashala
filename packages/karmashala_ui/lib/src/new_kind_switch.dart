import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';

/// What the "new" dialog makes (UI overhaul spec §5): one dialog, two tabs.
enum NewKind { session, project }

/// **Session | Project**, above the new-session and new-project dialogs'
/// titles, so the two read as one dialog with two tabs. Drawn from values:
/// what switching does is the dialog's.
class NewKindSwitch extends StatelessWidget {
  const NewKindSwitch({
    required this.current,
    required this.onChanged,
    super.key,
  });

  final NewKind current;
  final ValueChanged<NewKind> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Insets.md),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: SegmentedButton<NewKind>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(
            value: NewKind.session,
            icon: Icon(AppIcons.chatCircleDots, size: Chrome.iconAction),
            label: Text('Session'),
          ),
          ButtonSegment(
            value: NewKind.project,
            icon: Icon(AppIcons.folderPlus, size: Chrome.iconAction),
            label: Text('Project'),
          ),
        ],
        selected: {current},
        onSelectionChanged: (picked) {
          if (picked.first != current) onChanged(picked.first);
        },
      ),
    ),
  );
}
