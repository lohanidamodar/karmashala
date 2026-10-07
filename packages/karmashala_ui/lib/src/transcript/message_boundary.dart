import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';
import '../app_icons.dart';

/// Lets a [MessageBoundary] catch a build failure beneath it. Installed once at
/// start-up; answers the restore, which a test must call.
///
/// Flutter offers no per-subtree boundary: a throwing build becomes
/// [ErrorWidget.builder]'s widget, and in a list that box is 100,000 px tall.
VoidCallback installMessageBoundaries() {
  final previous = ErrorWidget.builder;
  ErrorWidget.builder = (details) =>
      _ContainedError(details: details, outside: previous);
  return () => ErrorWidget.builder = previous;
}

/// One message, drawn — or, when its build throws, a line saying it could not
/// be, with its raw text a tap away. The rest of the conversation is untouched.
class MessageBoundary extends StatefulWidget {
  const MessageBoundary({required this.raw, required this.child, super.key});

  /// What "Show raw" shows; a change retries the message.
  final String raw;
  final Widget child;

  @override
  State<MessageBoundary> createState() => _MessageBoundaryState();
}

class _MessageBoundaryState extends State<MessageBoundary> {
  FlutterErrorDetails? _failure;
  bool _reported = false;
  bool _showRaw = false;

  void _report(FlutterErrorDetails details) {
    if (_reported) return;
    _reported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _failure = details);
    });
  }

  @override
  void didUpdateWidget(MessageBoundary old) {
    super.didUpdateWidget(old);
    if (old.raw != widget.raw) {
      _failure = null;
      _reported = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure == null) return widget.child;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final failed = SemanticColors.of(context).failure;
    return Column(
      key: const ValueKey('message-boundary-fallback'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectionContainer.disabled(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Insets.xs,
            children: [
              Icon(
                AppIcons.warningCircle,
                size: Chrome.iconSmall,
                color: failed,
              ),
              Text(
                "This message couldn't be shown",
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              TextButton(
                onPressed: () => setState(() => _showRaw = !_showRaw),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelSmall,
                ),
                child: Text(_showRaw ? 'Hide raw' : 'Show raw'),
              ),
              IconButton(
                tooltip: 'Copy raw',
                iconSize: Chrome.iconSmall,
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: widget.raw)),
                icon: const Icon(AppIcons.copySimple),
              ),
            ],
          ),
        ),
        if (_showRaw)
          Text(
            widget.raw,
            style: MonoStyles.small.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
      ],
    );
  }
}

class _ContainedError extends StatelessWidget {
  const _ContainedError({required this.details, required this.outside});

  final FlutterErrorDetails details;
  final ErrorWidgetBuilder outside;

  @override
  Widget build(BuildContext context) {
    final boundary = context.findAncestorStateOfType<_MessageBoundaryState>();
    if (boundary == null) return outside(details);
    boundary._report(details);
    return const SizedBox.shrink();
  }
}
