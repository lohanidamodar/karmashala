import 'dart:async';

import '../../environments/application/environment_values.dart'
    show EnvironmentPath;
import 'package:agent_cli/stream.dart' show looksLikeImagePath;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../application/file_preview_loader.dart';
import '../domain/file_preview_kind.dart';
import '../../../core/clipboard/image_clipboard.dart'
    show imageClipboardProvider;
import 'chat_target_menu.dart' show keepTranscriptTargetMenu;

/// The most pictures one row draws; the rest are counted, not fetched.
const int kInlineImageStripMax = 24;

/// Places a path the conversation wrote in the session's environment, or null
/// when there is no record of where the session runs.
typedef InlineImagePlace = EnvironmentPath? Function(String path);

/// Lets the rows below draw the pictures their text names, read through the
/// server wherever the session runs. With none above, rows draw no strip.
class TranscriptInlineImages extends StatelessWidget {
  const TranscriptInlineImages({
    required this.place,
    required this.child,
    this.onOpen,
    super.key,
  });

  final InlineImagePlace place;

  /// Reveals a path as a click on it does; null hides Open.
  final ValueChanged<String>? onOpen;
  final Widget child;

  @override
  Widget build(BuildContext context) => _InlineImageScope(
    place: place,
    onOpen: onOpen,
    child: MarkdownImageScope(builder: _markdownImage, child: child),
  );
}

Widget _markdownImage(BuildContext context, String path, String? alt) =>
    TranscriptImageStrip(paths: [path]);

class _InlineImageScope extends InheritedWidget {
  const _InlineImageScope({
    required this.place,
    required this.onOpen,
    required super.child,
  });

  final InlineImagePlace place;
  final ValueChanged<String>? onOpen;

  static _InlineImageScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_InlineImageScope>();

  @override
  bool updateShouldNotify(_InlineImageScope old) =>
      place != old.place || onOpen != old.onOpen;
}

/// Whether [path] names a picture drawn inline.
bool isInlineImagePath(String path) =>
    looksLikeImagePath(path) || path.toLowerCase().endsWith('.svg');

final _markdownImageSyntax = RegExp(r'!\[[^\]\n]*\]\([^)\n]*\)');

/// A picture named with no folder, `shot.png`, which the path links leave
/// alone; never the tail of a longer path or address.
final _bareImageName = RegExp(
  r'(?<![\w.+%@:~/\\-])[\w+%@-]+(?:\.[\w+%@-]+)*\.(?:png|jpe?g|gif|webp|svg|bmp)(?![\w+%@/\\-])',
  caseSensitive: false,
);

/// The picture paths [text] names, in order and once each. Those it embeds
/// as `![alt](path)` are left out: the markdown draws them where they stand.
List<String> inlineImagePaths(String? text) {
  if (text == null || text.isEmpty) return const [];
  final plain = text.replaceAll(_markdownImageSyntax, ' ');
  final found = <(int, String)>[
    for (final match in kTranscriptPathPattern.allMatches(plain))
      if (tokenForMatch(match[0]!).path case final path
          when isInlineImagePath(path))
        (match.start, path),
    for (final match in _bareImageName.allMatches(plain))
      (match.start, match[0]!),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return {for (final (_, path) in found) path}.toList();
}

/// The pictures a row names: one drawn large, several as a strip of
/// thumbnails built — and so read — only as they scroll into view.
class TranscriptImageStrip extends StatelessWidget {
  const TranscriptImageStrip({required this.paths, super.key});

  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    final scope = _InlineImageScope.of(context);
    if (scope == null || paths.isEmpty) return const SizedBox.shrink();
    final shown = paths.length > kInlineImageStripMax
        ? paths.sublist(0, kInlineImageStripMax)
        : paths;
    final hidden = paths.length - shown.length;
    final Widget body;
    if (shown.length == 1) {
      body = _InlineImage(path: shown.single, scope: scope, thumb: false);
    } else {
      body = SizedBox(
        key: const ValueKey('inline-image-strip'),
        height: Chrome.imageThumb,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: shown.length,
          separatorBuilder: (_, _) => const SizedBox(width: Insets.xs),
          itemBuilder: (context, i) =>
              _InlineImage(path: shown[i], scope: scope, thumb: true),
        ),
      );
    }
    final theme = Theme.of(context);
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(top: Insets.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            body,
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Text(
                  'and $hidden more',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InlineImage extends ConsumerStatefulWidget {
  const _InlineImage({
    required this.path,
    required this.scope,
    required this.thumb,
  });

  final String path;
  final _InlineImageScope scope;
  final bool thumb;

  @override
  ConsumerState<_InlineImage> createState() => _InlineImageState();
}

class _InlineImageState extends ConsumerState<_InlineImage> {
  EnvironmentPath? _placed;
  Future<FilePreviewData>? _load;

  String get _name => widget.path.split(RegExp(r'[\\/]')).last;

  Future<FilePreviewData>? _loaded() {
    if (_load != null) return _load;
    final placed = _placed = widget.scope.place(widget.path);
    if (placed == null) return null;
    return _load = ref.read(filePreviewLoaderProvider).load(placed);
  }

  @override
  void didUpdateWidget(_InlineImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.scope.place != widget.scope.place) {
      _load = null;
      _placed = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final load = _loaded();
    if (load == null) {
      return _note(context, 'No record of where this session runs.');
    }
    return FutureBuilder<FilePreviewData>(
      future: load,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _note(context, 'Could not be read.');
        final data = snapshot.data;
        if (data == null) return _frame(context, null);
        final bytes = data.bytes;
        if (data.missing) return _note(context, 'Not on disk.');
        if (data.tooLarge) {
          return _note(
            context,
            'Too large to preview (${formatFileSize(data.size)}).',
          );
        }
        if (bytes == null) return _note(context, 'No preview.');
        return _frame(context, bytes);
      },
    );
  }

  double get _height => widget.thumb ? Chrome.imageThumb : Chrome.inlineImage;

  Widget _picture(BuildContext context, Uint8List bytes, {required bool full}) {
    Widget broken(BuildContext context, Object _, StackTrace? _) => Center(
      child: Icon(
        AppIcons.image,
        size: Chrome.icon,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    final fit = widget.thumb && !full ? BoxFit.cover : BoxFit.contain;
    if (previewKindFor(widget.path) == FilePreviewKind.svg) {
      return SvgPicture.memory(
        bytes,
        fit: fit,
        alignment: full ? Alignment.center : Alignment.centerLeft,
        errorBuilder: broken,
      );
    }
    final ImageProvider image = full
        ? MemoryImage(bytes)
        : ResizeImage(
            MemoryImage(bytes),
            height: (_height * MediaQuery.devicePixelRatioOf(context)).round(),
          );
    return Image(
      image: image,
      fit: fit,
      alignment: full ? Alignment.center : Alignment.centerLeft,
      semanticLabel: _name,
      errorBuilder: broken,
    );
  }

  Widget _frame(BuildContext context, Uint8List? bytes) {
    final scheme = Theme.of(context).colorScheme;
    final Widget content = bytes == null
        ? const Center(child: InlineSpinner(semanticsLabel: 'Reading image'))
        : _picture(context, bytes, full: false);
    final framed = DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: content,
      ),
    );
    final sized = widget.thumb || bytes == null
        ? SizedBox.square(dimension: Chrome.imageThumb, child: framed)
        : ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: Chrome.imageThumb,
              minHeight: Chrome.imageThumb,
              maxHeight: Chrome.inlineImage,
            ),
            child: framed,
          );
    final tile = Semantics(
      button: bytes != null,
      label: 'Image $_name',
      child: Tooltip(
        message: _name,
        child: InkWell(
          key: ValueKey('inline-image-${widget.path}'),
          onTap: bytes == null ? null : () => _enlarge(bytes),
          borderRadius: BorderRadius.circular(Radii.sm),
          child: sized,
        ),
      ),
    );
    final withActions = TranscriptImageActions(
      target: _target(bytes),
      child: tile,
    );
    if (widget.thumb) return withActions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(alignment: Alignment.centerLeft, child: withActions),
        _Actions(
          name: _name,
          onOpen: _open,
          onCopy: _copy,
          onCopyImage: _copyImage(context, bytes),
        ),
      ],
    );
  }

  TranscriptImageTarget? _target(Uint8List? bytes) => bytes == null
      ? null
      : TranscriptImageTarget(path: widget.path, bytes: () async => bytes);

  /// Copy image where the chat has a menu to run it and this device's
  /// clipboard takes a picture.
  VoidCallback? _copyImage(BuildContext context, Uint8List? bytes) {
    final scope = TranscriptTargetMenuScope.maybeScopeOf(context);
    final target = _target(bytes);
    if (scope == null ||
        target == null ||
        !ref.read(imageClipboardProvider).supported) {
      return null;
    }
    return () =>
        unawaited(scope.run(context, target, TranscriptTargetAction.copy));
  }

  VoidCallback? get _open {
    final open = widget.scope.onOpen;
    return open == null ? null : () => open(widget.path);
  }

  void _copy() {
    final path = _placed?.path ?? widget.path;
    Clipboard.setData(ClipboardData(text: path));
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Path copied to clipboard')));
  }

  void _enlarge(Uint8List bytes) {
    final full = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Builder(
          builder: (dialog) => Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.xs,
              Insets.xs,
              Insets.xs,
            ),
            child: _Actions(
              name: _placed?.path ?? widget.path,
              onOpen: _open == null
                  ? null
                  : () {
                      Navigator.of(dialog).pop();
                      _open!();
                    },
              onCopy: _copy,
              onCopyImage: _copyImage(dialog, bytes),
              onClose: () => Navigator.of(dialog).pop(),
            ),
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: TranscriptImageActions(
            target: _target(bytes),
            child: InteractiveViewer(
              maxScale: 8,
              child: _picture(context, bytes, full: true),
            ),
          ),
        ),
      ],
    );
    // The dialog's route is outside the chat, so its menu is carried over.
    final menu = keepTranscriptTargetMenu(context, body);
    showDialog<void>(
      context: context,
      builder: (_) => full
          ? Dialog.fullscreen(child: SafeArea(child: menu))
          : Dialog(insetPadding: const EdgeInsets.all(Insets.xl), child: menu),
    );
  }

  Widget _note(BuildContext context, String text) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final line = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(AppIcons.image, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.xs),
        Flexible(
          child: Text(
            widget.thumb ? text : '$_name: $text',
            maxLines: widget.thumb ? 3 : null,
            overflow: widget.thumb ? TextOverflow.ellipsis : null,
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
    if (!widget.thumb) return line;
    return Tooltip(
      message: '$_name: $text',
      child: SizedBox.square(
        dimension: Chrome.imageThumb,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Padding(
            padding: const EdgeInsets.all(Insets.xs),
            child: Center(child: line),
          ),
        ),
      ),
    );
  }
}

/// A picture's name with Open, Copy path and, in the viewer, Close.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.name,
    required this.onOpen,
    required this.onCopy,
    this.onCopyImage,
    this.onClose,
  });

  final String name;
  final VoidCallback? onOpen;
  final VoidCallback onCopy;
  final VoidCallback? onCopyImage;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      textStyle: theme.textTheme.labelSmall,
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: Insets.xs,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Chrome.readableWidth),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MonoStyles.small.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (onOpen case final open?)
          TextButton(
            key: const ValueKey('inline-image-open'),
            onPressed: open,
            style: style,
            child: const Text('Open'),
          ),
        if (onCopyImage case final copyImage?)
          TextButton(
            key: const ValueKey('inline-image-copy-image'),
            onPressed: copyImage,
            style: style,
            child: const Text('Copy image'),
          ),
        TextButton(
          key: const ValueKey('inline-image-copy'),
          onPressed: onCopy,
          style: style,
          child: const Text('Copy path'),
        ),
        if (onClose case final close?)
          IconButton(
            tooltip: 'Close',
            iconSize: Chrome.iconSmall,
            visualDensity: VisualDensity.compact,
            onPressed: close,
            icon: const Icon(AppIcons.x),
          ),
      ],
    );
  }
}
