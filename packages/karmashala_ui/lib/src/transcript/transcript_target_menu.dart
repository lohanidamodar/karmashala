import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_icons.dart';
import '../design_tokens.dart';

/// Something in a conversation a reader can copy or open from its menu.
sealed class TranscriptTarget {
  const TranscriptTarget();
}

/// A link the author wrote: [href], drawn as [text].
final class TranscriptWebLink extends TranscriptTarget {
  const TranscriptWebLink(this.href, {this.text});

  final String href;
  final String? text;
}

/// A file path exactly as written, `:line` and all.
final class TranscriptPathLink extends TranscriptTarget {
  const TranscriptPathLink(this.path);

  final String path;
}

/// A picture: a [path] in the session's files, or a [uri] it was fetched from.
/// [bytes] reads what is drawn, or null when it cannot.
final class TranscriptImageTarget extends TranscriptTarget {
  const TranscriptImageTarget({required this.bytes, this.path, this.uri});

  final String? path;
  final Uri? uri;
  final Future<Uint8List?> Function() bytes;

  /// The file name a copy or a save suggests.
  String get name {
    final source = path ?? uri?.pathSegments.lastOrNull ?? '';
    final name = source.split(RegExp(r'[\\/]')).last;
    return name.isEmpty ? 'image.png' : name;
  }
}

/// Inline code, copied as written.
final class TranscriptCodeSpan extends TranscriptTarget {
  const TranscriptCodeSpan(this.code);

  final String code;
}

/// Opens the menu for [target]: as a popup at [position] under a pointer, or as
/// a sheet under a thumb.
typedef TranscriptTargetMenuOpener =
    Future<void> Function(
      BuildContext context,
      TranscriptTarget target, {
      Offset? position,
    });

/// The two acts a target offers without its menu: its hover buttons and Ctrl+C.
enum TranscriptTargetAction { copy, open }

typedef TranscriptTargetActionRunner =
    Future<void> Function(
      BuildContext context,
      TranscriptTarget target,
      TranscriptTargetAction action,
    );

/// What a right-click or long-press on a link, path, picture or code span in
/// the conversation below opens. With none above, they have no menu.
class TranscriptTargetMenuScope extends InheritedWidget {
  const TranscriptTargetMenuScope({
    required this.open,
    required this.run,
    required super.child,
    super.key,
  });

  final TranscriptTargetMenuOpener open;
  final TranscriptTargetActionRunner run;

  static TranscriptTargetMenuOpener? of(BuildContext context) =>
      maybeScopeOf(context)?.open;

  static TranscriptTargetMenuScope? maybeScopeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TranscriptTargetMenuScope>();

  @override
  bool updateShouldNotify(TranscriptTargetMenuScope old) =>
      open != old.open || run != old.run;
}

/// A picture with its menu, Ctrl+C to copy it while focus is inside, and —
/// under a pointer — Copy and Open on it while hovered.
class TranscriptImageActions extends StatefulWidget {
  const TranscriptImageActions({
    required this.target,
    required this.child,
    super.key,
  });

  /// Null while the picture is still loading: nothing to act on yet.
  final TranscriptImageTarget? target;
  final Widget child;

  @override
  State<TranscriptImageActions> createState() => _TranscriptImageActionsState();
}

class _TranscriptImageActionsState extends State<TranscriptImageActions> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scope = TranscriptTargetMenuScope.maybeScopeOf(context);
    final target = widget.target;
    if (scope == null || target == null) return widget.child;
    void run(TranscriptTargetAction action) =>
        unawaited(scope.run(context, target, action));
    Widget body = widget.child;
    if (!UiDensity.of(context).isTouch) {
      final scheme = Theme.of(context).colorScheme;
      final style = IconButton.styleFrom(
        backgroundColor: scheme.surfaceContainerHigh,
        foregroundColor: scheme.onSurface,
        visualDensity: VisualDensity.compact,
        minimumSize: const Size.square(Chrome.control),
        padding: EdgeInsets.zero,
        iconSize: Chrome.iconSmall,
      );
      body = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            body,
            if (_hovered)
              Positioned(
                top: Insets.xs,
                right: Insets.xs,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: Insets.xs,
                  children: [
                    IconButton(
                      key: const ValueKey('image-hover-copy'),
                      tooltip: 'Copy image',
                      style: style,
                      icon: const Icon(AppIcons.copySimple),
                      onPressed: () => run(TranscriptTargetAction.copy),
                    ),
                    IconButton(
                      key: const ValueKey('image-hover-open'),
                      tooltip: 'Open',
                      style: style,
                      icon: const Icon(AppIcons.arrowSquareOut),
                      onPressed: () => run(TranscriptTargetAction.open),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
            run(TranscriptTargetAction.copy),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () =>
            run(TranscriptTargetAction.copy),
      },
      child: TranscriptTargetPress(targetAt: (_) => target, child: body),
    );
  }
}

/// The text span drawn at the global [position], if any.
TextSpan? transcriptSpanAt(BuildContext context, Offset position) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(
    result,
    position,
    View.of(context).viewId,
  );
  for (final entry in result.path) {
    if (entry.target case final TextSpan span) return span;
  }
  return null;
}

/// Opens the scope's menu for what [targetAt] finds under a right-click or, on
/// touch, a long-press. A press on nothing is left to the selection around it.
class TranscriptTargetPress extends StatelessWidget {
  const TranscriptTargetPress({
    required this.targetAt,
    required this.child,
    super.key,
  });

  /// The target at a global position, or null to let the press through.
  final TranscriptTarget? Function(Offset position) targetAt;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final open = TranscriptTargetMenuScope.of(context);
    if (open == null) return child;
    void show(TranscriptTarget target, Offset? position) =>
        open(context, target, position: position);
    return RawGestureDetector(
      behavior: HitTestBehavior.deferToChild,
      gestures: {
        _SecondaryPress: GestureRecognizerFactoryWithHandlers<_SecondaryPress>(
          _SecondaryPress.new,
          (press) => press
            ..targetAt = targetAt
            ..onPress = show,
        ),
        _TouchLongPress: GestureRecognizerFactoryWithHandlers<_TouchLongPress>(
          _TouchLongPress.new,
          (press) => press
            ..targetAt = targetAt
            ..onPress = show,
        ),
      },
      child: child,
    );
  }
}

/// A right-click on a target, claimed on the way down: the selection area's
/// own right-click would otherwise fire after a press held past 100 ms.
class _SecondaryPress extends OneSequenceGestureRecognizer {
  TranscriptTarget? Function(Offset position)? targetAt;
  void Function(TranscriptTarget target, Offset position)? onPress;

  TranscriptTarget? _target;
  Offset? _at;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (event.buttons != kSecondaryMouseButton) return false;
    if (!super.isPointerAllowed(event)) return false;
    _target = targetAt?.call(event.position);
    return _target != null;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _at = event.position;
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent) {
      final target = _target;
      final at = _at;
      stopTrackingPointer(event.pointer);
      if (target != null && at != null) onPress?.call(target, at);
    } else if (event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _target = null;
    _at = null;
  }

  @override
  String get debugDescription => 'transcript target right-click';
}

/// A long-press on a target under a thumb, which wins over the selection's
/// own long-press because it is asked first.
class _TouchLongPress extends LongPressGestureRecognizer {
  _TouchLongPress()
    : super(
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      ) {
    onLongPressStart = (details) {
      final target = _target;
      if (target == null) return;
      unawaited(HapticFeedback.lightImpact());
      onPress?.call(target, details.globalPosition);
    };
  }

  TranscriptTarget? Function(Offset position)? targetAt;
  void Function(TranscriptTarget target, Offset? position)? onPress;

  TranscriptTarget? _target;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (!super.isPointerAllowed(event)) return false;
    _target = targetAt?.call(event.position);
    return _target != null;
  }
}
