import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../git/application/remote_links.dart' show openExternalUrlProvider;
import 'artifact_fallback_view.dart';

/// The canvas an HTML page is laid out on: the web's own default, white with
/// near-black text, whatever the app's theme — a page assumes it.
const _pageCanvas = Color(0xFFFFFFFF);
const _pageInk = Color(0xDE000000);
const _pageMuted = Color(0x8A000000);
const _pageShade = Color(0xFFF1F1F1);

/// An HTML artifact drawn natively: its markup and CSS laid out as widgets,
/// and **no script ever run**. Nothing is read from this machine — no file, no
/// app asset — and nothing from the network unless the person allowed it for
/// this artifact. A page that carries scripts says it was drawn without them
/// and offers the browser, where it runs inside the sandbox shell.
class ArtifactHtmlView extends ConsumerWidget {
  const ArtifactHtmlView({
    required this.artifact,
    required this.revision,
    required this.html,
    this.compact = false,
    super.key,
  });

  final Artifact artifact;
  final int revision;
  final String html;

  /// Inside a thread card: no notice, and links still open in the browser.
  final bool compact;

  static final _script = RegExp(r'<script\b', caseSensitive: false);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowNetwork = artifact.networkAllowed;
    final open = ref.read(openExternalUrlProvider);
    final page = HtmlWidget(
      html,
      // Re-laid out when the network is allowed or taken back.
      key: ValueKey('artifact-html-net-$allowNetwork'),
      // A light page, as it was written to be read.
      textStyle: const TextStyle(color: _pageInk),
      factoryBuilder: () => _SandboxedFactory(allowNetwork: allowNetwork),
      customWidgetBuilder: (element) => element.localName == 'img'
          ? _image(element.attributes['src'] ?? '', allowNetwork)
          : null,
      onTapUrl: (url) async {
        // Links leave Karmashala for the person's browser, and only http(s).
        await open(url);
        return true;
      },
    );
    final scripted = _script.hasMatch(html);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (scripted && !compact)
          _ScriptsNotice(artifact: artifact, revision: revision),
        DecoratedBox(
          decoration: const BoxDecoration(color: _pageCanvas),
          child: Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: page,
          ),
        ),
      ],
    );
  }

  /// What an `<img>` shows: a `data:` picture, a web one when allowed, and
  /// otherwise a line saying why it is not here.
  static Widget _image(String src, bool allowNetwork) {
    final uri = Uri.tryParse(src.trim());
    if (uri != null && uri.scheme == 'data') {
      final data = uri.data;
      if (data == null) return _blocked('file', 'an image that is not data');
      final bytes = data.contentAsBytes();
      return data.mimeType == 'image/svg+xml'
          ? SvgPicture.memory(bytes)
          : Image.memory(bytes, errorBuilder: (_, _, _) => const SizedBox());
    }
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      if (!allowNetwork) {
        return _blocked(
          'network',
          'an image from ${uri.host} — the network is off for this artifact',
        );
      }
      return Image.network(
        uri.toString(),
        errorBuilder: (_, _, _) =>
            _blocked('failed', 'an image from ${uri.host} that did not load'),
      );
    }
    return _blocked(
      'file',
      'an image from a file — a page shown here reads no file',
    );
  }

  static Widget _blocked(String why, String what) => Builder(
    builder: (context) => Container(
      key: ValueKey('artifact-html-blocked-$why'),
      padding: const EdgeInsets.all(Insets.xs),
      color: _pageShade,
      child: Text(
        'Not shown: $what.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: _pageMuted),
      ),
    ),
  );
}

/// The library's own image sources, narrowed to what an artifact may reach:
/// never an app asset or a file, and the network only when allowed. Covers
/// what the `<img>` hook does not, such as a CSS background.
class _SandboxedFactory extends WidgetFactory {
  _SandboxedFactory({required this.allowNetwork});

  final bool allowNetwork;

  @override
  ImageProvider? imageProviderFromAsset(String url) => null;

  @override
  ImageProvider? imageProviderFromFileUri(String url) => null;

  @override
  ImageProvider? imageProviderFromNetwork(String url) =>
      allowNetwork ? super.imageProviderFromNetwork(url) : null;
}

class _ScriptsNotice extends StatelessWidget {
  const _ScriptsNotice({required this.artifact, required this.revision});

  final Artifact artifact;
  final int revision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const ValueKey('artifact-html-scripts'),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.xs,
        ),
        child: Row(
          children: [
            const Icon(AppIcons.code),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                'This page runs scripts, and is drawn here without them. Open '
                'it in your browser to run it — still sandboxed.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            ArtifactActionButtons(
              artifact: artifact,
              revision: revision,
              save: false,
              dense: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// The bytes of an HTML artifact as text.
String artifactHtmlText(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true);
