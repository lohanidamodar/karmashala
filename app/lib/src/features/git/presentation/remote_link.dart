import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/remote_links.dart';

/// A piece of text that opens a page on the forge — a commit sha, a pull
/// request number, a branch name. With no URL the text is still drawn, plainly:
/// a commit without a remote is still a commit.
class RemoteLink extends ConsumerWidget {
  const RemoteLink({
    required this.text,
    this.url,
    this.style,
    this.tooltip,
    this.icon = false,
    super.key,
  });

  final String text;

  /// The page to open. Null draws [text] with no affordance at all.
  final String? url;

  final TextStyle? style;

  /// What the link promises before it is clicked; defaults to the URL itself.
  final String? tooltip;

  /// Whether to draw the "opens outside the app" mark after the text.
  final bool icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final target = url;
    if (target == null) {
      return Text(text, style: style, overflow: TextOverflow.ellipsis);
    }

    final linked = (style ?? theme.textTheme.labelSmall)?.copyWith(
      color: theme.colorScheme.primary,
    );
    return Tooltip(
      message: tooltip ?? target,
      child: InkWell(
        onTap: () => ref.read(openExternalUrlProvider)(target),
        borderRadius: BorderRadius.circular(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(text, style: linked, overflow: TextOverflow.ellipsis),
            ),
            if (icon) ...[
              const SizedBox(width: Insets.xxs),
              // Subordinate to the link: at Chrome.iconSmall this mark competes
              // with the text instead of qualifying it.
              Icon(
                AppIcons.arrowSquareOut,
                size: 11,
                color: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The first seven characters of a sha — what git itself prints, and what fits
/// in a row.
String shortSha(String sha) => sha.length <= 7 ? sha : sha.substring(0, 7);
