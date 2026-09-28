import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'shell_compact_bar.dart' show ShellActiveTabGlyph;
import 'shell_shortcuts.dart';
import 'tab_picker.dart';
import 'workbench.dart' show terminalTabEntries;

/// **The Zen bar** (UI overhaul spec §5, board N4): in Zen only the pane is
/// on screen, and this small bar floats at the top edge — which tab and
/// what its agent is doing (press to switch), how many sessions need you,
/// and the way out.
class ShellZenBar extends ConsumerWidget {
  const ShellZenBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabId = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.activeTab?.id),
    );
    return ZenBar(
      status: const ShellActiveTabGlyph(),
      title: tabId == null
          ? 'No tab'
          : ref.watch(terminalTabTitleProvider(tabId)),
      needsYou: ref.watch(needsYouCountProvider),
      leaveHint: shellChordLabel<ToggleFocusModeIntent>(),
      onSwitch: () => TabPicker.show(context, terminalTabEntries),
      onNextWaiting: () => ref.read(attentionInboxProvider.notifier).openNext(),
      onLeave: () => ref.read(terminalMaximizedProvider.notifier).toggle(),
    );
  }
}

/// The bar from values: 32px, a 9px corner, the raised tone nearly opaque
/// over the terminal with a floating surface's hairline and shadow.
class ZenBar extends StatelessWidget {
  const ZenBar({
    required this.title,
    required this.needsYou,
    required this.onSwitch,
    required this.onNextWaiting,
    required this.onLeave,
    this.leaveHint,
    this.status,
    super.key,
  });

  final String title;
  final int needsYou;
  final String? leaveHint;
  final VoidCallback onSwitch;
  final VoidCallback onNextWaiting;
  final VoidCallback onLeave;

  /// What the tab's agent is doing, ahead of its name; null draws nothing.
  final Widget? status;

  /// The board's geometry: the bar, the controls inside it, the pill.
  static const _height = 32.0;
  static const _control = 26.0;
  static const _pill = 22.0;
  static const _radius = 9.0;

  /// The widest the tab's name grows before it ends.
  static const _titleMaxWidth = 260.0;

  /// Nearly opaque: the terminal under the bar should not read through it.
  static const _surfaceAlpha = 0.94;

  static const _shadow = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.4),
      offset: Offset(0, 10),
      blurRadius: 28,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final attention = SemanticColors.of(context).attention;
    final density = UiDensity.of(context);
    final muted = scheme.onSurfaceVariant;
    // Floors, not fixed heights: at a large text step the bar grows.
    return Container(
      constraints: const BoxConstraints(minHeight: _height),
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      decoration: BoxDecoration(
        color: tones.raised.withValues(alpha: _surfaceAlpha),
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(color: tones.floatingLine),
        boxShadow: _shadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'Switch session',
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.sm),
                onTap: onSwitch,
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: _control,
                    maxWidth: _titleMaxWidth,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ?status,
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: density.rowTitle(theme),
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      Icon(
                        AppIcons.caretDown,
                        size: Chrome.iconSmall,
                        color: muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (needsYou > 0) ...[
              const SizedBox(width: Insets.xs),
              Tooltip(
                message: [
                  needsYou == 1
                      ? '1 session needs you'
                      : '$needsYou sessions need you',
                  'go to the next',
                ].join('  ·  '),
                child: Semantics(
                  button: true,
                  label: needsYou == 1
                      ? '1 session needs you'
                      : '$needsYou sessions need you',
                  excludeSemantics: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    onTap: onNextWaiting,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: _pill),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.sm,
                      ),
                      decoration: BoxDecoration(
                        color: tones.attentionSurface,
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            AppIcons.warningCircle,
                            size: Chrome.iconSmall,
                            color: attention,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '$needsYou',
                            style: density
                                .muted(theme)
                                ?.copyWith(color: attention),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: Insets.xs),
            Tooltip(
              message: leaveHint == null
                  ? 'Leave Zen'
                  : 'Leave Zen  ·  $leaveHint',
              child: Semantics(
                button: true,
                label: 'Leave Zen',
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  onTap: onLeave,
                  child: SizedBox.square(
                    dimension: _control,
                    child: Icon(
                      AppIcons.arrowsOutSimple,
                      size: Chrome.iconSmall,
                      color: muted,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The room left above the pane in Zen, for the bar that floats there.
const double kZenBarRoom = 44;
