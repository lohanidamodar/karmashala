import 'package:flutter/material.dart';

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
                ended ? Icons.link_off : Icons.pause_circle_outline,
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
                icon: const Icon(Icons.restart_alt),
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

/// Says which transport the live view's gestures are using.
///
/// Not a debug detail: on the control socket a drag tracks the finger, and on
/// `adb shell input` nothing moves until release. Someone wondering why the
/// pane feels different today deserves to be able to see why.
class TransportBanner extends StatelessWidget {
  const TransportBanner({super.key, required this.transport});

  final DeviceGestureTransport? transport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch (transport) {
      null => 'Input unavailable',
      DeviceGestureTransport.scrcpyControl =>
        'Control socket — continuous touch. $kPinchHint.',
      DeviceGestureTransport.adbInput =>
        'adb input fallback — gestures apply on release, no pinch.',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            transport?.isContinuous ?? false
                ? Icons.touch_app
                : Icons.info_outline,
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
