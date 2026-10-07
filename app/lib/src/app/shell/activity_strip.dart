import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart' show AskPulse;
import 'package:karmashala_ui/tokens.dart';

import '../../core/capabilities/capabilities.dart';
import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/settings/application/settings_controller.dart';
import 'devices_dock.dart';
import 'shell_area.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';
import 'workbench_tabs.dart';

/// Width of the strip, the leftmost column of the window.
const double kActivityStripWidth = 52;

/// The height one strip button takes.
const double _buttonExtent = 40;

/// **The activity strip** (spec §4): one glyph per area, Usage and Settings
/// at the foot.
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
    final areas = visibleShellAreas(ref.watch(capabilitiesProvider));
    return ActivityStrip(
      selected: open ? area : null,
      areas: areas,
      badges: {
        ShellArea.sessions: ref.watch(needsYouCountProvider),
        // Not even read without a Devices area: it would run adb.
        if (areas.contains(ShellArea.devices))
          ShellArea.devices: ref.watch(readyDeviceCountProvider),
        // What waits on an answer, as the Sessions badge; an unread update
        // is only the neutral dot below.
        ShellArea.inbox: ref.watch(inboxAskCountProvider),
      },
      news: {if (ref.watch(inboxHasUnseenUpdateProvider)) ShellArea.inbox},
      // A hover worth having teaches the key that reaches the same place.
      hints: {
        for (final area in areas)
          area: ?shellChordLabel<ShowShellAreaIntent>(
            where: (intent) => intent.area == area,
          ),
      },
      settingsHint: shellChordLabel<OpenSettingsIntent>(),
      usageHint: shellChordLabel<OpenUsageIntent>(),
      onSelect: (picked) => toggleShellArea(ref, picked),
      onSettings: () => openSettingsTab(ref),
      onUsage: () => openUsageTab(ref),
      onOverview: () => openOverviewTab(ref),
      overviewHint: shellChordLabel<OpenOverviewIntent>(),
      onStores: () => openStoresTab(ref),
      onRunning: () => openRunningTab(ref),
      onAutomations: () => openAutomationsTab(ref),
      // A diagnostic, not a daily tool: in the strip only while debug mode is
      // on. Quick open, Settings and a keymap reach it either way.
      onLogs: ref.watch(settingsControllerProvider.select((s) => s.debugMode))
          ? () => openLogsTab(ref)
          : null,
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
    this.areas = ShellArea.values,
    this.badges = const {},
    this.news = const {},
    this.hints = const {},
    this.settingsHint,
    this.onUsage,
    this.usageHint,
    this.onStores,
    this.onRunning,
    this.onAutomations,
    this.onLogs,
    this.onOverview,
    this.overviewHint,
    super.key,
  });

  final ShellArea? selected;

  /// The glyphs drawn, in order: [visibleShellAreas].
  final List<ShellArea> areas;
  final Map<ShellArea, int> badges;

  /// Areas holding something unread that does not need the user: a small
  /// neutral dot, drawn only where there is no count.
  final Set<ShellArea> news;

  /// The chord that reaches an area, shown after its name on hover.
  final Map<ShellArea, String> hints;
  final String? settingsHint;
  final ValueChanged<ShellArea> onSelect;
  final VoidCallback onSettings;

  /// Opens the Usage tab (spec §5). Null leaves its glyph out — a strip
  /// drawn with no way to open the tab should not offer one.
  final VoidCallback? onUsage;
  final String? usageHint;

  /// Opens the Stores tab. Null leaves its glyph out, as [onUsage] does.
  final VoidCallback? onStores;

  /// Opens the Running tab. Null leaves its glyph out, as [onUsage] does.
  final VoidCallback? onRunning;

  /// Opens the Automations tab. Null leaves its glyph out, as [onUsage] does.
  final VoidCallback? onAutomations;

  /// Opens the Logs tab. Null leaves its glyph out, as [onUsage] does.
  final VoidCallback? onLogs;

  /// Opens the Overview tab. Null leaves its glyph out, as [onUsage] does.
  final VoidCallback? onOverview;
  final String? overviewHint;

  static IconData iconFor(ShellArea area) => switch (area) {
    ShellArea.sessions => AppIcons.chatCircleDots,
    ShellArea.projects => AppIcons.folders,
    ShellArea.terminals => AppIcons.terminalWindow,
    ShellArea.devices => AppIcons.deviceMobile,
    ShellArea.inbox => AppIcons.tray,
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // The Automations launcher is the one left out of a strip too short to
      // hold it; quick open reaches it either way.
      final buttons =
          areas.length +
          [onOverview, onLogs, onRunning, onStores, onUsage].nonNulls.length +
          2;
      final roomy =
          constraints.maxHeight >=
          buttons * (_buttonExtent + Insets.xs) + Insets.sm * 2;
      return _strip(context, automations: roomy ? onAutomations : null);
    },
  );

  Widget _strip(BuildContext context, {required VoidCallback? automations}) {
    final tones = SurfaceTones.of(context);
    return Container(
      width: kActivityStripWidth,
      color: tones.strip,
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Column(
        children: [
          for (final area in areas)
            _StripButton(
              icon: iconFor(area),
              label: area.label,
              hint: hints[area],
              selected: area == selected,
              badge: badges[area] ?? 0,
              news: news.contains(area),
              // Devices counts what is there, not what wants the user.
              urgent: area != ShellArea.devices,
              onPressed: () => onSelect(area),
            ),
          const Spacer(),
          // Above Settings, and like it never marked selected: both open a
          // tab, and the tab strip already says which tab is in front.
          if (onOverview case final onOverview?)
            _StripButton(
              icon: AppIcons.squaresFour,
              label: 'Overview',
              hint: overviewHint,
              selected: false,
              onPressed: onOverview,
            ),
          if (onLogs case final onLogs?)
            _StripButton(
              icon: AppIcons.article,
              label: 'Logs',
              selected: false,
              onPressed: onLogs,
            ),
          if (onRunning case final onRunning?)
            _StripButton(
              icon: AppIcons.listMagnifyingGlass,
              label: 'Running',
              selected: false,
              onPressed: onRunning,
            ),
          if (automations case final automations?)
            _StripButton(
              icon: AppIcons.lightning,
              label: 'Automations',
              selected: false,
              onPressed: automations,
            ),
          if (onStores case final onStores?)
            _StripButton(
              icon: AppIcons.package,
              label: 'Stores',
              selected: false,
              onPressed: onStores,
            ),
          if (onUsage case final onUsage?)
            _StripButton(
              icon: AppIcons.chartBar,
              label: 'Usage',
              hint: usageHint,
              selected: false,
              onPressed: onUsage,
            ),
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
    this.news = false,
    this.urgent = true,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String? hint;
  final bool selected;
  final int badge;

  /// Something unread that is not an ask: a neutral dot, never amber.
  final bool news;

  /// A count of things waiting on the user, on the attention tone and
  /// breathing with the ask's shield; otherwise a plain count on a neutral one.
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
              ? (news ? '$label, new updates' : label)
              : urgent
              ? '$label, $badge need you'
              : '$label, $badge connected',
          excludeSemantics: true,
          child: SizedBox(
            width: kActivityStripWidth,
            height: _buttonExtent,
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
                      child: _maybePulse(
                        Container(
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
                  )
                else if (news)
                  Positioned(
                    right: 9,
                    top: 7,
                    child: IgnorePointer(
                      child: Container(
                        width: Chrome.dot,
                        height: Chrome.dot,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurfaceVariant,
                          shape: BoxShape.circle,
                          border: Border.all(color: tones.strip, width: 1.5),
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

  /// Only a count of asks breathes: a count of devices is not waiting.
  Widget _maybePulse(Widget badge) => urgent ? AskPulse(child: badge) : badge;
}
