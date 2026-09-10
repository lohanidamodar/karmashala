import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import 'package:karmashala_devices/devices.dart';
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

/// Says the picture is standing still without claiming anything is wrong: a
/// device nobody is touching sends no frames, since scrcpy encodes on change.
class StreamIdleBadge extends StatelessWidget {
  const StreamIdleBadge({
    super.key,
    required this.detail,
    this.since,
    this.onRestart,
  });

  /// The stream's own line, e.g. `No screen changes for 20s.`
  final String detail;

  /// How long the picture has stood still, when the stream said.
  final Duration? since;

  /// Reconnects. Idleness is the one state the app cannot be certain about:
  /// a quiet device and a stopped stream make the same still picture.
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final age = since;
    final uncertain = age != null && age >= kIdleUncertainAfter;
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
              Flexible(
                child: Text(
                  uncertain
                      ? '$detail The picture may be out of date.'
                      : detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
                ),
              ),
              if (onRestart != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onRestart,
                  child: Text(
                    'Reconnect',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                      decoration: TextDecoration.underline,
                      decorationColor: theme.colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w600,
                    ),
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

/// How long a still picture is allowed to pass without comment before the badge
/// admits the app cannot tell a quiet device from a stopped one.
const Duration kIdleUncertainAfter = Duration(seconds: 45);

/// The last frame of the previous session, with the thing that says so. One
/// widget, so no edit can part a held frame from the label explaining it.
class HeldPicture extends StatelessWidget {
  const HeldPicture({super.key, required this.child, this.deviceLabel});

  /// The frozen picture — a video view whose session has ended.
  final Widget child;

  final String? deviceLabel;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [child, StreamReconnectingOverlay(deviceLabel: deviceLabel)],
  );
}

/// Covers the last frame of a stream being restarted. The picture underneath
/// is kept on purpose, which is exactly why something must be said over it.
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

/// Says which device the live view shows, and which transport its gestures
/// use: on the control socket a drag tracks the finger, on adb it jumps.
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
