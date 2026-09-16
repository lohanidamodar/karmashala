import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../devices.dart';
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

  /// Below this height (at 1x text) the explanation is dropped: in a picture a
  /// side panel has squeezed, the way out matters more than the reason.
  static const detailFrom = 220.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onInverseSurface;
    final ended = health.state == DeviceStreamState.ended;
    final scaler = MediaQuery.textScalerOf(context);
    return ColoredBox(
      color: theme.colorScheme.scrim.withValues(alpha: 0.72),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final roomy =
              constraints.maxHeight >=
              WidthClass.scaleBreakpoint(detailFrom, scaler);
          final padding = roomy ? Insets.lg : Insets.sm;
          final column = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (roomy) ...[
                Icon(
                  ended ? AppIcons.linkBreak : AppIcons.pauseCircle,
                  color: ink,
                ),
                const SizedBox(height: Insets.sm),
              ],
              Text(
                ended ? 'Live view disconnected' : 'Live view frozen',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(color: ink),
              ),
              if (roomy) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  health.detail,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: ink),
                ),
                if (health.serverLog.isNotEmpty) ...[
                  const SizedBox(height: Insets.xs),
                  Text(
                    health.serverLog.last,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: ink.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
              SizedBox(height: roomy ? Insets.md : Insets.xs),
              FilledButton.icon(
                onPressed: onRestart,
                icon: const Icon(AppIcons.arrowCounterClockwise),
                label: const Text(
                  'Restart live view',
                  textAlign: TextAlign.center,
                ),
              ),
              if (!exhausted) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  'Reconnecting…',
                  style: theme.textTheme.labelSmall?.copyWith(color: ink),
                ),
              ],
            ],
          );
          // The width is the box's, so the words wrap; whatever height that
          // comes to is scaled down to fit rather than clipped — the button
          // stays on screen and pressable in a picture of any size.
          if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
            return Padding(padding: EdgeInsets.all(padding), child: column);
          }
          final width = math.max(0.0, constraints.maxWidth - padding * 2);
          return Padding(
            padding: EdgeInsets.all(padding),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(width: width, child: column),
              ),
            ),
          );
        },
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
    final ink = theme.colorScheme.onInverseSurface;
    final age = since;
    final uncertain = age != null && age >= kIdleUncertainAfter;
    return Padding(
      padding: const EdgeInsets.all(Insets.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.scrim.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.pauseCircle, size: Chrome.iconAction, color: ink),
              const SizedBox(width: Insets.xs),
              Flexible(
                child: Text(
                  uncertain
                      ? '$detail The picture may be out of date.'
                      : detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: ink),
                ),
              ),
              if (onRestart != null) ...[
                const SizedBox(width: Insets.xs),
                // A real button: a tap target, a Tab stop and a "button" to a
                // screen reader — a GestureDetector on a Text was none of them.
                TextButton(
                  onPressed: onRestart,
                  style: TextButton.styleFrom(
                    foregroundColor: ink,
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, Chrome.control),
                    padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Text(
                    'Reconnect',
                    style: TextStyle(
                      decoration: TextDecoration.underline,
                      decorationColor: ink,
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
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InlineSpinner(
                size: InlineSpinnerSize.large,
                color: theme.colorScheme.onInverseSurface,
              ),
              const SizedBox(height: Insets.sm),
              Text(
                'Reconnecting…',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
              const SizedBox(height: Insets.xs),
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
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.xs,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            transport?.isContinuous ?? false ? AppIcons.handTap : AppIcons.info,
            size: Chrome.iconAction,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: Insets.xs),
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
