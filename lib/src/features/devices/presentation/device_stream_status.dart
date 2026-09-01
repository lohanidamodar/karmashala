import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../data/device_gesture_sink.dart';
import '../data/device_stream.dart';
import 'device_touch_surface.dart';

/// Covers a frozen live view, says what happened, and offers the way out.
class StreamStalledOverlay extends StatelessWidget {
  const StreamStalledOverlay({
    super.key,
    required this.health,
    required this.exhausted,
    required this.onRestart,
  });

  final DeviceStreamHealth health;
  final bool exhausted;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ended = health.state == DeviceStreamState.ended;
    return ColoredBox(
      color: theme.colorScheme.scrim.withValues(alpha: 0.72),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                ended ? AppIcons.linkBreak : AppIcons.pauseCircle,
                color: theme.colorScheme.onInverseSurface,
              ),
              const SizedBox(height: 8),
              Text(
                ended ? 'Live view disconnected' : 'Live view frozen',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                health.detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
              if (health.serverLog.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  health.serverLog.last,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onInverseSurface.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onRestart,
                icon: const Icon(AppIcons.arrowCounterClockwise),
                label: const Text('Restart live view'),
              ),
              if (!exhausted) ...[
                const SizedBox(height: 6),
                Text(
                  'Reconnecting…',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Says which device the live view is showing, and which transport its
/// gestures are using.
///
/// Neither is a debug detail. The transport changes how the pane feels — on the
/// control socket a drag tracks the finger, on `adb shell input` nothing moves
/// until release. The device name is here because a picture of a phone is
/// anonymous: the pane used to be able to show one device while the rest of the
/// UI named another, and stating it under the picture is what makes that
/// impossible to miss.
class TransportBanner extends StatelessWidget {
  const TransportBanner({super.key, required this.transport, this.deviceLabel});

  final DeviceGestureTransport? transport;

  /// The device on screen, e.g. `Pixel (emulator-5554)`. Named first, so it is
  /// the part that survives when the line is too narrow.
  final String? deviceLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transportText = switch (transport) {
      null => 'Input unavailable',
      DeviceGestureTransport.scrcpyControl =>
        'Control socket — continuous touch. $kPinchHint.',
      DeviceGestureTransport.adbInput =>
        'adb input fallback — gestures apply on release, no pinch.',
      DeviceGestureTransport.webDriverAgent =>
        'WebDriverAgent — gestures apply on release, no pinch.',
    };
    final label = deviceLabel;
    final text = label == null ? transportText : '$label · $transportText';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            transport?.isContinuous ?? false ? AppIcons.handTap : AppIcons.info,
            size: 14,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
