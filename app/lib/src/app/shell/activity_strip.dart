import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import 'devices_dock.dart';
import 'shell_area.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';
import 'workbench_tabs.dart';

/// Width of the strip, the leftmost column of the window.
const double kActivityStripWidth = 52;

/// **The activity strip** (spec §4): one glyph per area, Settings at the foot.
/// Pressing the area the sidebar already shows hides the sidebar; pressing
/// another shows it with that area.
class ShellActivityStrip extends ConsumerWidget {
  const ShellActivityStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final area = ref.watch(shellAreaProvider);
    final open = ref.watch(
      shellControllerProvider.select((s) => s.explorerPaneVisible),
    );
    final shell = ref.read(shellControllerProvider.notifier);
    return ActivityStrip(
      selected: open ? area : null,
      badges: {
        ShellArea.sessions: ref.watch(needsYouCountProvider),
        ShellArea.devices: ref.watch(readyDeviceCountProvider),
        ShellArea.inbox: ref.watch(attentionCountProvider),
      },
      // A hover worth having teaches the key that reaches the same place.
      hints: {ShellArea.inbox: ?shellChordLabel<OpenAttentionInboxIntent>()},
      settingsHint: shellChordLabel<OpenSettingsIntent>(),
      onSelect: (picked) {
        if (open && picked == area) {
          shell.toggleExplorerPane();
          return;
        }
        ref.read(shellAreaProvider.notifier).select(picked);
        if (!open) shell.toggleExplorerPane();
      },
      onSettings: () => openSettingsTab(ref),
    );
  }
}

/// The strip itself, from values: which area is showing (null when the
/// sidebar is hidden), how many things in each area want the user, and what
/// a press does.
class ActivityStrip extends StatelessWidget {
  const ActivityStrip({
    required this.selected,
    required this.onSelect,
    required this.onSettings,
    this.badges = const {},
    this.hints = const {},
    this.settingsHint,
    super.key,
  });

  final ShellArea? selected;
  final Map<ShellArea, int> badges;

  /// The chord that reaches an area, shown after its name on hover.
  final Map<ShellArea, String> hints;
  final String? settingsHint;
  final ValueChanged<ShellArea> onSelect;
  final VoidCallback onSettings;

  static IconData iconFor(ShellArea area) => switch (area) {
    ShellArea.sessions => AppIcons.chatCircleDots,
    ShellArea.projects => AppIcons.folders,
    ShellArea.terminals => AppIcons.terminalWindow,
    ShellArea.devices => AppIcons.deviceMobile,
    ShellArea.inbox => AppIcons.tray,
  };

  @override
  Widget build(BuildContext context) {
    final tones = SurfaceTones.of(context);
    return Container(
      width: kActivityStripWidth,
      color: tones.strip,
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Column(
        children: [
          for (final area in ShellArea.values)
            _StripButton(
              icon: iconFor(area),
              label: area.label,
              hint: hints[area],
              selected: area == selected,
              badge: badges[area] ?? 0,
              // Devices counts what is there, not what wants the user.
              urgent: area != ShellArea.devices,
              onPressed: () => onSelect(area),
            ),
          const Spacer(),
          _StripButton(
            icon: AppIcons.gearSix,
            label: 'Settings',
            hint: settingsHint,
            selected: false,
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

class _StripButton extends StatelessWidget {
  const _StripButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.badge = 0,
    this.urgent = true,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String? hint;
  final bool selected;
  final int badge;

  /// A count of things waiting on the user, on the attention tone; otherwise
  /// a plain count on a neutral one.
  final bool urgent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final semantic = SemanticColors.of(context);
    final fg = selected
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Tooltip(
        message: hint == null ? label : '$label  ·  $hint',
        preferBelow: false,
        child: Semantics(
          button: true,
          selected: selected,
          label: badge == 0
              ? label
              : urgent
              ? '$label, $badge need you'
              : '$label, $badge connected',
          excludeSemantics: true,
          child: SizedBox(
            width: kActivityStripWidth,
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // The accent edge says which area the sidebar shows.
                if (selected)
                  Positioned(
                    left: 0,
                    top: 10,
                    bottom: 10,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                Material(
                  color: selected ? tones.selected : Colors.transparent,
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.md),
                    onTap: onPressed,
                    child: SizedBox(
                      width: 38,
                      height: 38,
                      child: Icon(icon, size: 19, color: fg),
                    ),
                  ),
                ),
                if (badge > 0)
                  Positioned(
                    right: 6,
                    top: 3,
                    child: IgnorePointer(
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 15),
                        height: 15,
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: urgent
                              ? semantic.attention
                              : theme.colorScheme.onSurfaceVariant,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: tones.strip,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
