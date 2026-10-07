import 'dart:convert';
import 'dart:typed_data';

import '../../environments/application/environment_values.dart'
    show EnvironmentPath;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:karmashala_ui/diagrams.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';
import 'package:yaml/yaml.dart';

import '../../artifacts/application/artifact_actions.dart';
import '../../artifacts/presentation/artifact_pdf_view.dart';
import '../../artifacts/presentation/html_preview.dart';
import '../application/file_preview_loader.dart';
import '../domain/file_preview_kind.dart';

/// The tallest a preview's body draws before it scrolls inside itself.
const double kFilePreviewMaxHeight = 360;

/// A file the conversation named, previewed under the message that named it:
/// read through the server, so a WSL or SSH session's file previews as this
/// machine's does. Outside the session's checkout it asks first.
class TranscriptFilePreview extends ConsumerStatefulWidget {
  const TranscriptFilePreview({
    required this.path,
    required this.inScope,
    required this.onClose,
    required this.onOpenInEditor,
    required this.onOpenInFiles,
    this.line,
    super.key,
  });

  final EnvironmentPath path;

  /// The line the reference named, 1-based.
  final int? line;

  /// Whether [path] is inside one of the session's checkouts.
  final bool inScope;
  final VoidCallback onClose;
  final VoidCallback onOpenInEditor;
  final VoidCallback onOpenInFiles;

  @override
  ConsumerState<TranscriptFilePreview> createState() =>
      _TranscriptFilePreviewState();
}

class _TranscriptFilePreviewState extends ConsumerState<TranscriptFilePreview> {
  late bool _allowed = widget.inScope;
  Future<FilePreviewData>? _load;

  Future<FilePreviewData> _loaded() =>
      _load ??= ref.read(filePreviewLoaderProvider).load(widget.path);

  @override
  void didUpdateWidget(TranscriptFilePreview old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _load = null;
      _allowed = widget.inScope;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final segments = widget.path.path.split(RegExp(r'[\\/]'));
    final name = segments.last;
    final folder = segments.length > 1
        ? widget.path.path.substring(0, widget.path.path.length - name.length)
        : '';
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final header = SelectionContainer.disabled(
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.xs,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  AppIcons.fileCode,
                  size: Chrome.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: name,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (widget.line case final line?)
                          TextSpan(text: ':$line', style: muted),
                        if (folder.isNotEmpty)
                          TextSpan(text: '  $folder', style: muted),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          _Action(
            key: const ValueKey('file-preview-open-editor'),
            label: 'Open in editor',
            onPressed: widget.onOpenInEditor,
          ),
          _Action(
            key: const ValueKey('file-preview-open-files'),
            label: 'Open in Files',
            onPressed: widget.onOpenInFiles,
          ),
          IconButton(
            tooltip: 'Close preview',
            iconSize: Chrome.iconSmall,
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose,
            icon: const Icon(AppIcons.x),
          ),
        ],
      ),
    );
    return Padding(
      key: ValueKey('file-preview-${widget.path.path}'),
      padding: const EdgeInsets.only(top: Insets.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.brightness == Brightness.dark
              ? scheme.surfaceContainerLowest
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Insets.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              header,
              const SizedBox(height: Insets.xs),
              if (!_allowed)
                _Note(
                  text:
                      "This file is outside the session's checkout, so it is "
                      'not read until you ask.',
                  action: 'Preview anyway',
                  onAction: () => setState(() => _allowed = true),
                )
              else
                FutureBuilder<FilePreviewData>(
                  future: _loaded(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return _Note(
                        text: 'Could not read it: ${snapshot.error}',
                      );
                    }
                    final data = snapshot.data;
                    if (data == null) {
                      return const Padding(
                        padding: EdgeInsets.all(Insets.sm),
                        child: InlineSpinner(
                          semanticsLabel: 'Reading the file',
                        ),
                      );
                    }
                    return _body(context, data);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, FilePreviewData data) {
    if (data.missing) return const _Note(text: 'Not on disk.');
    if (data.directory) {
      return _Note(
        text: 'A folder.',
        action: 'Open in Files',
        onAction: widget.onOpenInFiles,
      );
    }
    final size = formatFileSize(data.size);
    if (data.tooLarge) {
      return _Note(text: 'Too large to preview here ($size).');
    }
    final bytes = data.bytes;
    if (data.binary || data.kind == FilePreviewKind.other || bytes == null) {
      final ext = widget.path.path.contains('.')
          ? widget.path.path.split('.').last.toUpperCase()
          : 'binary';
      return _Note(
        key: const ValueKey('file-preview-binary'),
        text: '$ext file · $size · no preview for this kind of file.',
      );
    }
    final body = _drawn(context, data.kind, bytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        body,
        if (data.cut)
          _Note(
            key: const ValueKey('file-preview-cut'),
            text: 'Showing the first ${formatFileSize(bytes.length)} of $size.',
          ),
      ],
    );
  }

  Widget _drawn(BuildContext context, FilePreviewKind kind, List<int> bytes) {
    String text() => utf8.decode(bytes, allowMalformed: true);
    Widget scrolled(Widget child) => ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: kFilePreviewMaxHeight),
      child: SingleChildScrollView(child: child),
    );
    Widget code({String? language}) => NumberedCodeView(
      source: text(),
      language: language ?? previewLanguageFor(widget.path.path),
      focusLine: widget.line,
      maxHeight: kFilePreviewMaxHeight,
    );
    switch (kind) {
      case FilePreviewKind.markdown:
        return scrolled(MarkdownMessage(text()));
      case FilePreviewKind.image:
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: kFilePreviewMaxHeight),
          child: Image.memory(
            Uint8List.fromList(bytes),
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            errorBuilder: (_, error, _) =>
                _Note(text: 'This image could not be decoded.'),
          ),
        );
      case FilePreviewKind.svg:
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: kFilePreviewMaxHeight),
          child: SvgPicture.memory(
            Uint8List.fromList(bytes),
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            errorBuilder: (_, _, _) =>
                const _Note(text: 'This SVG could not be drawn.'),
          ),
        );
      case FilePreviewKind.pdf:
        return SizedBox(
          height: kFilePreviewMaxHeight + Insets.xxl * 3,
          child: ref.watch(artifactPdfViewProvider)(
            context,
            Uint8List.fromList(bytes),
          ),
        );
      case FilePreviewKind.delimited:
        final tsv = widget.path.path.toLowerCase().endsWith('.tsv');
        return scrolled(
          DelimitedTable(parseDelimited(text(), separator: tsv ? '\t' : ',')),
        );
      case FilePreviewKind.json:
        try {
          return scrolled(JsonTreeView(jsonDecode(text())));
        } on FormatException catch (error) {
          return _withError(code(language: 'json'), 'Not valid JSON', error);
        }
      case FilePreviewKind.yaml:
        try {
          return scrolled(JsonTreeView(loadYaml(text())));
        } on YamlException catch (error) {
          return _withError(code(language: 'yaml'), 'Not valid YAML', error);
        }
      case FilePreviewKind.mermaid:
        return MermaidBlock(text());
      case FilePreviewKind.log:
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: kFilePreviewMaxHeight),
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: AnsiText(text(), softWrap: false),
            ),
          ),
        );
      case FilePreviewKind.html:
        final html = text();
        final name = widget.path.path.split(RegExp(r'[\\/]')).last;
        return HtmlPreview(
          html: html,
          maxHeight: kFilePreviewMaxHeight,
          onOpenInBrowser: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            final said = await ref
                .read(artifactActionsProvider)
                .openHtmlInBrowser(html, name);
            messenger?.showSnackBar(SnackBar(content: Text(said)));
          },
        );
      case FilePreviewKind.code:
      case FilePreviewKind.other:
        return code();
    }
  }

  Widget _withError(Widget source, String what, Object error) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      _Note(text: '$what: $error'),
      source,
    ],
  );
}

class _Action extends StatelessWidget {
  const _Action({required this.label, required this.onPressed, super.key});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      textStyle: Theme.of(context).textTheme.labelSmall,
    ),
    child: Text(label),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.action, this.onAction, super.key});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.sm,
        children: [
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (action case final action?)
            _Action(label: action, onPressed: onAction ?? () {}),
        ],
      ),
    );
  }
}
