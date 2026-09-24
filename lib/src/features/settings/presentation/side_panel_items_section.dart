import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/side_panel.dart';
import '../../../app/shell/side_panel_state.dart';
import '../../notes/application/notes_providers.dart';
import '../application/settings_controller.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Appearance → Side panel: which surfaces keep a glyph on the rail.
/// The same list as the rail's right-click menu and View › Side panel items.
class SidePanelItemsSection extends ConsumerWidget {
  const SidePanelItemsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hidden = ref.watch(hiddenSidePanelSurfacesProvider);
    final surfaces = SidePanelSurface.offered(
      debugMode: ref.watch(
        settingsControllerProvider.select((s) => s.debugMode),
      ),
      notesEnabled: ref.watch(notesEnabledProvider),
    );
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.sidePanel.heading,
      trailing: TextButton(
        onPressed: hidden.isEmpty ? null : controller.showAllSidePanelSurfaces,
        child: const Text('Show all'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Which tools keep a glyph on the rail.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.xs),
          for (final surface in surfaces)
            SidePanelSurfaceCheckRow(
              surface: surface,
              visible: !hidden.contains(surface),
              onChanged: (visible) => controller.setSidePanelSurfaceHidden(
                surface.name,
                hidden: !visible,
              ),
            ),
          const SizedBox(height: Insets.sm),
          SettingsSwitchRow(
            label: 'Project details in the Explorer',
            help: 'A second line with folder, branch and state.',
            value: ref.watch(
              settingsControllerProvider.select(
                (s) => s.explorerProjectDetails,
              ),
            ),
            onChanged: controller.setExplorerProjectDetails,
          ),
        ],
      ),
    );
  }
}

/// One surface in a show-or-hide list: a checkbox, its rail glyph and its name,
/// the whole row a target.
class SidePanelSurfaceCheckRow extends StatelessWidget {
  const SidePanelSurfaceCheckRow({
    required this.surface,
    required this.visible,
    required this.onChanged,
    super.key,
  });

  final SidePanelSurface surface;
  final bool visible;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => onChanged(!visible),
        child: Row(
          children: [
            Checkbox(
              value: visible,
              visualDensity: VisualDensity.compact,
              onChanged: (value) => onChanged(value ?? false),
            ),
            const SizedBox(width: Insets.xs),
            Icon(
              SidePanel.iconFor(surface),
              size: Chrome.icon,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(surface.label, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}
