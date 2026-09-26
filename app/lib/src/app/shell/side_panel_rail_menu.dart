import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';

import '../../features/notes/application/notes_providers.dart';
import '../../features/settings/application/settings_controller.dart';
import 'side_panel.dart';
import 'side_panel_state.dart';

/// What the rail's menu can do, as the value a menu row carries.
sealed class RailMenuChoice {
  const RailMenuChoice();
}

/// Hide or show one surface: the checklist rows and "Hide '…'".
class RailMenuToggle extends RailMenuChoice {
  const RailMenuToggle(this.surface, {required this.hide});

  final SidePanelSurface surface;
  final bool hide;
}

class RailMenuShowAll extends RailMenuChoice {
  const RailMenuShowAll();
}

/// The surfaces the rail can list, in rail order — what is switched off (Notes,
/// Logs outside debug mode) is not listed, because it has no glyph to hide.
List<SidePanelSurface> railMenuSurfaces(WidgetRef ref) =>
    SidePanelSurface.offered(
      debugMode: ref.read(settingsControllerProvider).debugMode,
      notesEnabled: ref.read(notesEnabledProvider),
    );

/// The rail's right-click menu, as VS Code's activity bar has it: "Hide" for
/// the glyph under the pointer, then every surface with a check, then Show all.
List<PopupMenuEntry<RailMenuChoice>> railMenuItems({
  required List<SidePanelSurface> surfaces,
  required Set<SidePanelSurface> hidden,
  SidePanelSurface? target,
}) => [
  if (target != null) ...[
    if (hidden.contains(target))
      // A temporary glyph: its surface is open but hidden.
      DesktopMenuItem<RailMenuChoice>(
        value: RailMenuToggle(target, hide: false),
        icon: AppIcons.pushPin,
        label: "Keep '${target.label}' on the rail",
      )
    else
      DesktopMenuItem<RailMenuChoice>(
        value: RailMenuToggle(target, hide: true),
        icon: AppIcons.minusCircle,
        label: "Hide '${target.label}'",
      ),
    const DesktopMenuDivider(),
  ],
  for (final surface in surfaces)
    DesktopMenuCheckItem<RailMenuChoice>(
      value: RailMenuToggle(surface, hide: !hidden.contains(surface)),
      icon: SidePanel.iconFor(surface),
      label: surface.label,
      checked: !hidden.contains(surface),
    ),
  const DesktopMenuDivider(),
  DesktopMenuItem<RailMenuChoice>(
    value: const RailMenuShowAll(),
    icon: AppIcons.arrowCounterClockwise,
    label: 'Show all',
    enabled: hidden.isNotEmpty,
  ),
];

/// Applies a pick from any of the lists that hide surfaces.
void applyRailMenuChoice(WidgetRef ref, RailMenuChoice choice) {
  final settings = ref.read(settingsControllerProvider.notifier);
  switch (choice) {
    case RailMenuToggle(:final surface, :final hide):
      settings.setSidePanelSurfaceHidden(surface.name, hidden: hide);
    case RailMenuShowAll():
      settings.showAllSidePanelSurfaces();
  }
}

/// Opens the rail menu at [position] (a right-click), or under the widget
/// [context] belongs to when there is no pointer (the rail's own button).
Future<void> showRailMenu(
  BuildContext context,
  WidgetRef ref, {
  Offset? position,
  SidePanelSurface? target,
}) async {
  final items = railMenuItems(
    surfaces: railMenuSurfaces(ref),
    hidden: ref.read(hiddenSidePanelSurfacesProvider),
    target: target,
  );
  final choice = position == null
      ? await showDesktopMenuUnder(context, items)
      : await showDesktopMenuAt(context, position, items);
  if (choice != null && context.mounted) applyRailMenuChoice(ref, choice);
}
