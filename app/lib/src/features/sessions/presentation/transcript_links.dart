import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../git/application/remote_links.dart' show openExternalUrlProvider;

/// A link the agent wrote, tapped in any transcript. A path without a scheme
/// goes to [openPath], or is refused when the transcript has none; a web link
/// asks first on a touch screen, since a stray tap while scrolling must not
/// leave the app.
Future<void> openTranscriptLink(
  BuildContext context,
  WidgetRef ref,
  String href, {
  required Future<void> Function(String path)? openPath,
  required ValueChanged<String> say,
}) async {
  final uri = Uri.tryParse(href);
  if (uri != null && !uri.hasScheme) {
    if (openPath == null) {
      say('Karmashala cannot place $href for this conversation.');
      return;
    }
    await openPath(href);
    return;
  }
  if (uri == null ||
      !(uri.isScheme('http') ||
          uri.isScheme('https') ||
          uri.isScheme('mailto'))) {
    say('Only web links open from here: $href');
    return;
  }
  if (UiDensity.of(context).isTouch) {
    final go = await showAdaptiveModal<bool>(
      context: context,
      title: 'Open in the browser?',
      builder: (context) => _OpenLinkBody(uri: uri),
    );
    if (go != true || !context.mounted) return;
  }
  try {
    final opened = uri.isScheme('mailto')
        ? await launchUrl(uri, mode: LaunchMode.externalApplication)
        : await ref.read(openExternalUrlProvider)(uri.toString());
    if (!opened) say('Nothing on this device could open $href.');
  } on Exception {
    say('Nothing on this device could open $href.');
  }
}

/// The link in full, so the reader sees where it goes, and the two answers.
class _OpenLinkBody extends StatelessWidget {
  const _OpenLinkBody({required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            '$uri',
            style: MonoStyles.body.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: Touch.gap),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Open'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
