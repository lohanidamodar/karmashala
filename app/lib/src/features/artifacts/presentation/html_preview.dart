import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../git/application/remote_links.dart' show openExternalUrlProvider;

/// Draws an HTML page in the app. Behind a provider so a web view can take
/// its place in one spot; today it is [nativeHtmlEngine] on every platform.
typedef HtmlEngine =
    Widget Function(
      BuildContext context,
      String html, {
      required bool allowNetwork,
      required Future<void> Function(String url) openUrl,
    });

final htmlEngineProvider = Provider<HtmlEngine>((ref) => nativeHtmlEngine);

/// Whether [htmlEngineProvider]'s engine runs a page's scripts. The native
/// one never does, so the preview says where they do run.
final htmlEngineRunsScriptsProvider = Provider<bool>((ref) => false);

/// The canvas a page is laid out on: the web's own default, white with
/// near-black text, whatever the app's theme — a page assumes it.
const _pageCanvas = Color(0xFFFFFFFF);
const _pageInk = Color(0xDE000000);
const _pageMuted = Color(0x8A000000);
const _pageShade = Color(0xFFF1F1F1);

final _script = RegExp(r'<script\b', caseSensitive: false);
final _remote = RegExp(
  r'''(src|href)\s*=\s*["']?https?://''',
  caseSensitive: false,
);

/// The page's markup and CSS laid out as widgets, and **no script ever run**.
/// Nothing is read from this machine — no file, no app asset — and nothing
/// from the network unless [allowNetwork].
Widget nativeHtmlEngine(
  BuildContext context,
  String html, {
  required bool allowNetwork,
  required Future<void> Function(String url) openUrl,
}) => DecoratedBox(
  decoration: const BoxDecoration(color: _pageCanvas),
  child: Padding(
    padding: const EdgeInsets.all(Insets.md),
    child: HtmlWidget(
      html,
      key: ValueKey('artifact-html-net-$allowNetwork'),
      textStyle: const TextStyle(color: _pageInk),
      factoryBuilder: () => _SandboxedFactory(allowNetwork: allowNetwork),
      customWidgetBuilder: (element) => element.localName == 'img'
          ? _image(element.attributes['src'] ?? '', allowNetwork)
          : null,
      onTapUrl: (url) async {
        await openUrl(url);
        return true;
      },
    ),
  ),
);

/// An HTML page, shown here: a Preview / Source switch, Copy, full screen and
/// the browser, and a plain line on what does not happen here. Grows with
/// the page up to [maxHeight], then scrolls inside itself.
class HtmlPreview extends ConsumerStatefulWidget {
  const HtmlPreview({
    required this.html,
    this.allowNetwork = false,
    this.onOpenInBrowser,
    this.maxHeight,
    this.fullScreen = true,
    super.key,
  });

  final String html;
  final bool allowNetwork;

  /// Opens the page in the person's browser, inside the sandbox shell.
  final Future<void> Function()? onOpenInBrowser;

  /// The tallest the preview grows; null takes what its parent gives.
  final double? maxHeight;

  /// Whether to offer full screen; false inside the full-screen view itself.
  final bool fullScreen;

  @override
  ConsumerState<HtmlPreview> createState() => _HtmlPreviewState();
}

class _HtmlPreviewState extends ConsumerState<HtmlPreview> {
  bool _source = false;

  Future<void> _openFull() => showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Insets.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(AppIcons.x),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: Insets.xs),
                  Expanded(
                    child: Text(
                      'HTML preview',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: HtmlPreview(
                  html: widget.html,
                  allowNetwork: widget.allowNetwork,
                  onOpenInBrowser: widget.onOpenInBrowser,
                  fullScreen: false,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final engine = ref.watch(htmlEngineProvider);
    final runsScripts = ref.watch(htmlEngineRunsScriptsProvider);
    final open = ref.read(openExternalUrlProvider);
    final scripted = _script.hasMatch(widget.html);
    final remote = _remote.hasMatch(widget.html);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final notes = <(String, String)>[
      if (scripted && !runsScripts)
        (
          'artifact-html-scripts',
          'Scripts do not run here; they run only when you open the page in '
              'your browser, still sandboxed.',
        ),
      if (remote)
        (
          'artifact-html-network',
          widget.allowNetwork
              ? 'Network allowed for this page: https only.'
              : 'Network off: nothing loads from the web.',
        ),
    ];
    final bar = SelectionContainer.disabled(
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.xs,
        children: [
          SegmentedButton<bool>(
            key: const ValueKey('html-preview-mode'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: false, label: Text('Preview')),
              ButtonSegment(value: true, label: Text('Source')),
            ],
            selected: {_source},
            onSelectionChanged: (s) => setState(() => _source = s.first),
          ),
          CopyTextButton(text: widget.html, tooltip: 'Copy HTML'),
          if (widget.fullScreen)
            IconButton(
              key: const ValueKey('html-preview-full'),
              tooltip: 'Open full screen',
              iconSize: Chrome.iconSmall,
              visualDensity: VisualDensity.compact,
              onPressed: _openFull,
              icon: const Icon(AppIcons.arrowsOutSimple),
            ),
          if (widget.onOpenInBrowser case final browse?)
            IconButton(
              key: const ValueKey('html-preview-browser'),
              tooltip: 'Open in browser: scripts run there, sandboxed',
              iconSize: Chrome.iconSmall,
              visualDensity: VisualDensity.compact,
              onPressed: browse,
              icon: const Icon(AppIcons.globe),
            ),
        ],
      ),
    );
    final body = _source
        ? CodeBlock(source: widget.html, language: 'html')
        : engine(
            context,
            widget.html,
            allowNetwork: widget.allowNetwork,
            openUrl: (url) async => open(url),
          );
    final max = widget.maxHeight;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: max == null ? MainAxisSize.max : MainAxisSize.min,
      children: [
        bar,
        const SizedBox(height: Insets.xs),
        // Grows with the page, then scrolls inside itself — the notes with
        // it, so a narrow, scaled-up card never runs out of room for them.
        Flexible(
          fit: max == null ? FlexFit.tight : FlexFit.loose,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (key, note) in notes)
                  Padding(
                    key: ValueKey(key),
                    padding: const EdgeInsets.only(bottom: Insets.xs),
                    child: Text(note, style: muted),
                  ),
                body,
              ],
            ),
          ),
        ),
      ],
    );
    return max == null
        ? column
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: max),
            child: column,
          );
  }
}

Widget _image(String src, bool allowNetwork) {
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
        'an image from ${uri.host} — the network is off for this page',
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

Widget _blocked(String why, String what) => Builder(
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

/// The library's own image sources, narrowed to what a page may reach: never
/// an app asset or a file, and the network only when allowed. Covers what the
/// `<img>` hook does not, such as a CSS background.
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
