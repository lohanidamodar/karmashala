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

/// Says the picture is standing still, without claiming anything is wrong.
///
/// A device nobody is touching sends no frames — scrcpy encodes on change — so
/// this is the ordinary state of a phone on a desk, and it gets a chip rather
/// than the scrim [StreamStalledOverlay] draws. The counter is there because
/// "is it live or has it frozen?" is a fair question to have about a still
/// picture, and this is the answer to it.
class StreamIdleBadge extends StatelessWidget {
  const StreamIdleBadge({super.key, required this.detail});

  /// The stream's own line, e.g. `No screen changes for 20s.`
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.scrim.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.pauseCircle,
                size: 14,
                color: theme.colorScheme.onInverseSurface,
              ),
              const SizedBox(width: 6),
              Text(
                detail,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Covers the last frame of a stream that is being restarted.
///
/// The picture underneath is deliberately kept — a held frame is a far better
/// thing to look at than the spinner that used to replace it — which is
/// exactly why this has to be over it. A stale frame with nothing said about
/// it is indistinguishable from a live one, and it is a picture people tap.
class StreamReconnectingOverlay extends StatelessWidget {
  const StreamReconnectingOverlay({super.key, required this.deviceLabel});

  final String? deviceLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = deviceLabel;
    return ColoredBox(
      color: theme.colorScheme.scrim.withValues(alpha: 0.72),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Reconnecting…',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label == null
                    ? 'This is the last frame received, not a live picture.'
                    : 'This is the last frame received from $label, not a '
                          'live picture.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
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
