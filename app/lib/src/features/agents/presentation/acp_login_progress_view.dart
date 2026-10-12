import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AcpAuthMethod, AcpLoginProgress, loginLinkReturnsLocally;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:url_launcher/url_launcher.dart';

/// A login under way: the method, a bar that keeps moving, what happens
/// next in words, and the link and code the agent gave — each with Copy, the
/// link with Open — so a phone can finish what the agent's machine started.
class AcpLoginProgressView extends StatelessWidget {
  const AcpLoginProgressView({
    required this.method,
    required this.note,
    this.heard,
    super.key,
  });

  final AcpAuthMethod method;
  final AcpLoginProgress? heard;
  final String note;

  /// Said beside a link whose sign-in returns to a loopback port.
  static const String returnsLocallyNote =
      'This sign-in returns to the machine the agent runs on: open the link '
      'in a browser there.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = heard?.link;
    final code = heard?.code;
    final parsed = link == null ? null : Uri.tryParse(link);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(method.name, style: theme.textTheme.titleSmall),
        const SizedBox(height: Insets.sm),
        const LinearProgressIndicator(),
        const SizedBox(height: Insets.sm),
        Text(note),
        if (link != null) ...[
          const SizedBox(height: Insets.md),
          _CopyableValue(
            label: 'Open this link',
            value: link,
            onOpen: parsed == null
                ? null
                : () => launchUrl(parsed, mode: LaunchMode.externalApplication),
          ),
          if (parsed != null && loginLinkReturnsLocally(parsed))
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(returnsLocallyNote, style: theme.textTheme.bodySmall),
            ),
        ],
        if (code != null) ...[
          const SizedBox(height: Insets.md),
          _CopyableValue(label: 'Code', value: code, large: true),
        ],
      ],
    );
  }
}

/// One value a person carries to a browser: selectable, with Copy, and Open
/// for a link.
class _CopyableValue extends StatelessWidget {
  const _CopyableValue({
    required this.label,
    required this.value,
    this.onOpen,
    this.large = false,
  });

  final String label;
  final String value;
  final VoidCallback? onOpen;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style =
        (large ? theme.textTheme.titleMedium : theme.textTheme.bodySmall)
            ?.copyWith(
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
            );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: Insets.xxs),
        SelectableText(value, style: style, maxLines: large ? 1 : 4),
        Wrap(
          spacing: Insets.sm,
          children: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(
                  context,
                )?.showSnackBar(SnackBar(content: Text('$label copied')));
              },
              icon: const Icon(AppIcons.copy, size: Chrome.iconAction),
              label: Text(large ? 'Copy code' : 'Copy link'),
            ),
            if (onOpen case final open?)
              TextButton.icon(
                onPressed: open,
                icon: const Icon(
                  AppIcons.arrowSquareOut,
                  size: Chrome.iconAction,
                ),
                label: const Text('Open in browser'),
              ),
          ],
        ),
      ],
    );
  }
}
