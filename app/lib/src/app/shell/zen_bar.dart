import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'shell_shortcuts.dart';
import 'tab_picker.dart';
import 'workbench.dart' show terminalTabEntries;

/// **The Zen bar** (UI overhaul spec §5): in Zen only the pane is on screen,
/// and this small bar floats at the top edge — which tab, switch to another,
/// how many sessions need you, and the way out.
class ShellZenBar extends ConsumerWidget {
  const ShellZenBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabId = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.activeTab?.id),
    );
    return ZenBar(
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

/// The bar from values.
class ZenBar extends StatelessWidget {
  const ZenBar({
    required this.title,
    required this.needsYou,
    required this.onSwitch,
    required this.onNextWaiting,
    required this.onLeave,
    this.leaveHint,
    super.key,
  });

  final String title;
  final int needsYou;
  final String? leaveHint;
  final VoidCallback onSwitch;
  final VoidCallback onNextWaiting;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final attention = SemanticColors.of(context).attention;
    final label = theme.textTheme.labelMedium;
    ButtonStyle compact = TextButton.styleFrom(
      minimumSize: const Size(0, Chrome.control),
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    return Material(
      color: tones.raised,
      elevation: 4,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: TextButton(
                style: compact,
                onPressed: onSwitch,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: label,
                      ),
                    ),
                    const SizedBox(width: Insets.xs),
                    const Icon(AppIcons.caretDown, size: Chrome.iconSmall),
                  ],
                ),
              ),
            ),
            if (needsYou > 0)
              Tooltip(
                message: 'Go to the next session that needs you',
                child: TextButton.icon(
                  style: compact.copyWith(
                    foregroundColor: WidgetStatePropertyAll(attention),
                  ),
                  onPressed: onNextWaiting,
                  icon: const Icon(
                    AppIcons.warningCircle,
                    size: Chrome.iconSmall,
                  ),
                  label: Text(
                    needsYou == 1 ? '1 needs you' : '$needsYou need you',
                    style: label?.copyWith(color: attention),
                  ),
                ),
              ),
            Tooltip(
              message: leaveHint == null
                  ? 'Leave Zen'
                  : 'Leave Zen  ·  $leaveHint',
              child: TextButton(
                style: compact,
                onPressed: onLeave,
                child: Text('Leave', style: label),
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
