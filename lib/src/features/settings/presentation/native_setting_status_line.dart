import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import '../../system/native_status.dart';
import 'settings_notice.dart';

/// What the OS actually did about one setting, shown beside its toggle. Renders
/// nothing when the platform call succeeded, so it appears only where a switch
/// the user turned on did not take effect — otherwise invisible.
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

    return Padding(
      // Owns its own spacing so the rows above stay flush when the OS agreed
      // and this renders nothing at all, which is the normal case.
      padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
      child: SettingsNotice(
        tone: SettingsNoticeTone.danger,
        // "Still trying" and "given up" are different situations: one
        // resolves itself, the other needs the user to act.
        message: status!.exhausted ? '$message (not retrying)' : message,
      ),
    );
  }
}
