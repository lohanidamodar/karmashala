import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../system/native_status.dart';

/// What the OS actually did about one setting, shown beside its toggle.
///
/// Renders nothing at all when the platform call succeeded — which is almost
/// always — so the settings page stays quiet. It appears only when a switch the
/// user turned on did not take effect, which until Loop 61 was invisible: the
/// setting persisted, the toggle stayed on, and the global hotkey simply never
/// worked.
class NativeSettingStatusLine extends ConsumerWidget {
  const NativeSettingStatusLine(this.setting, {this.enabled = true, super.key});

  final NativeSetting setting;

  /// The toggle's current position, so the line agrees with the switch above
  /// it — turning a setting off is a platform call that can fail too.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(
      nativeIntegrationStatusProvider.select((all) => all[setting]),
    );
    final message = status?.messageFor(setting, enabled: enabled);
    if (message == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      // Owns its own spacing so the rows above stay flush when the OS agreed
      // and this renders nothing at all, which is the normal case.
      padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            AppIcons.warningCircle,
            size: 16,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              // "Still trying" and "given up" are different situations for the
              // user: one resolves itself, the other needs them to change
              // something.
              status!.exhausted ? '$message (not retrying)' : message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
