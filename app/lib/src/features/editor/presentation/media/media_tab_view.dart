import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../../core/capabilities/capabilities.dart';
import '../../application/media_documents.dart';
import '../../domain/media_document.dart';
import '../../domain/media_kind.dart';
import 'image_viewer.dart';
import 'media_clipboard.dart';
import 'media_player_view.dart';

/// One open image, video or audio file, as the content of a workbench tab. The
/// file lives in [mediaDocumentsProvider], not here; this widget opens it but
/// never closes it — the tab's owner does, when the tab goes.
class MediaTabView extends ConsumerStatefulWidget {
  const MediaTabView({
    required this.hostPath,
    required this.onCopyPath,
    this.onOpenExternally,
    this.onAttachToChat,
    this.attachDisabledReason,
    this.showing = true,
    super.key,
  });

  /// Whether its tab is the one on screen; off screen a player pauses.
  final bool showing;

  /// The document id (`document_id.dart`).
  final String hostPath;
  final VoidCallback onCopyPath;

  /// Null hides "Open externally": nothing on this machine can open the file.
  final VoidCallback? onOpenExternally;

  /// Null disables "Attach to chat", with [attachDisabledReason] as its
  /// tooltip.
  final VoidCallback? onAttachToChat;
  final String? attachDisabledReason;

  @override
  ConsumerState<MediaTabView> createState() => _MediaTabViewState();
}

class _MediaTabViewState extends ConsumerState<MediaTabView> {
  final _zoom = ImageViewerController();

  /// The decoded size of the bytes it was measured from, so a reload never
  /// shows the last picture's dimensions under the new one.
  (Uint8List, Size)? _decoded;

  /// The bytes that would not decode; a new revision gets another try.
  Uint8List? _undecodable;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(MediaTabView old) {
    super.didUpdateWidget(old);
    if (old.hostPath != widget.hostPath) _open();
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  /// After the frame: a provider must not change while the tree builds.
  void _open() {
    final hostPath = widget.hostPath;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(mediaDocumentsProvider.notifier).open(hostPath));
    });
  }

  void _retry() => unawaited(
    ref.read(mediaDocumentsProvider.notifier).reload(widget.hostPath),
  );

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(
      mediaDocumentsProvider.select((open) => open[widget.hostPath]),
    );
    final client = ref.watch(clientCapabilitiesProvider);
    final kind = document?.kind ?? mediaKindOf(widget.hostPath);
    final image = kind == MediaKind.image;
    final playsHere = client.mediaPlayback;
    // Copying a picture is a desktop act; a phone shares a file instead.
    // pasteboard 0.5's writeImage is a no-op on Linux, and a button that says
    // "copied" having copied nothing is worse than no button.
    final copiesImages =
        !client.density.isTouch &&
        defaultTargetPlatform != TargetPlatform.linux;
    final bytes = document?.bytes;
    final showsImage =
        image &&
        document != null &&
        document.isReady &&
        !identical(bytes, _undecodable);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(
          document: document,
          kind: kind,
          zoomable: showsImage,
          copyImage: showsImage && copiesImages ? bytes : null,
        ),
        if (document != null &&
            document.error != null &&
            document.refusal == MediaRefusal.none &&
            document.isReady)
          PaneNoticeBar(
            icon: AppIcons.warningCircle,
            tone: NoticeTone.attention,
            message: document.error!,
            action: TextButton(onPressed: _retry, child: const Text('Retry')),
          ),
        Expanded(
          child: _body(document, kind: kind, playsHere: playsHere),
        ),
        if (showsImage)
          _statusLine(bytes!, document.name)
        else if (!image && document != null)
          // Video and audio: what the file's stat said, when it said it.
          if (document.stamp?.length case final length? when length > 0)
            _strip(mediaStatusLine(byteCount: length, name: document.name)),
      ],
    );
  }

  Widget _toolbar({
    required MediaDocument? document,
    required MediaKind? kind,
    required bool zoomable,
    required Uint8List? copyImage,
  }) {
    final attach = widget.onAttachToChat;
    final openExternally = widget.onOpenExternally;
    return PaneHeader(
      icon: switch (kind) {
        MediaKind.video => AppIcons.fileVideo,
        MediaKind.audio => AppIcons.playCircle,
        MediaKind.image || null => AppIcons.image,
      },
      title: document?.name ?? 'Opening…',
      actions: [
        if (zoomable) ...[
          _TextAction(
            label: 'Fit',
            tooltip: 'Fit to pane',
            onPressed: _zoom.fit,
          ),
          _TextAction(
            label: '100%',
            tooltip: 'Actual size',
            onPressed: _zoom.actualSize,
          ),
          _IconAction(
            tooltip: 'Zoom out',
            icon: AppIcons.minusCircle,
            onPressed: _zoom.zoomOut,
          ),
          ListenableBuilder(
            listenable: _zoom,
            builder: (context, _) => Text(
              '${(_zoom.scale * 100).round()}%',
              style: MonoStyles.small.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _IconAction(
            tooltip: 'Zoom in',
            icon: AppIcons.plusCircle,
            onPressed: _zoom.zoomIn,
          ),
          const SizedBox(
            height: Chrome.iconAction,
            child: VerticalDivider(width: Insets.md),
          ),
        ],
        _IconAction(
          tooltip: attach != null
              ? 'Attach to chat'
              : (widget.attachDisabledReason ?? 'Attach to chat'),
          icon: AppIcons.chat,
          onPressed: attach,
        ),
        if (copyImage != null)
          _IconAction(
            tooltip: 'Copy image',
            icon: AppIcons.copy,
            onPressed: () =>
                unawaited(copyImageToClipboard(context, copyImage)),
          ),
        _IconAction(
          tooltip: 'Copy path',
          icon: AppIcons.copySimple,
          onPressed: widget.onCopyPath,
        ),
        if (openExternally != null)
          _IconAction(
            tooltip: 'Open externally',
            icon: AppIcons.arrowSquareOut,
            onPressed: openExternally,
          ),
      ],
    );
  }

  Widget _body(
    MediaDocument? document, {
    required MediaKind? kind,
    required bool playsHere,
  }) {
    if (document == null) return const _Spinner();
    if (document.refusal != MediaRefusal.none) {
      return _Refused(
        message: document.error ?? _refusalText(document.refusal),
        onOpenExternally: widget.onOpenExternally,
      );
    }
    if (kind != MediaKind.image && !playsHere) {
      return _NoPlaybackCard(
        onCopyPath: widget.onCopyPath,
        onAttachToChat: widget.onAttachToChat,
        attachDisabledReason: widget.attachDisabledReason,
      );
    }
    if (document.copyProgress case final progress? when !document.isReady) {
      return _CopyProgress(progress: progress);
    }
    if (!document.isReady) {
      if (document.error case final error?) {
        return PanePlaceholder(
          icon: AppIcons.warningCircle,
          message: error,
          action: TextButton(onPressed: _retry, child: const Text('Retry')),
        );
      }
      return const _Spinner();
    }
    if (document.kind == MediaKind.image) {
      final bytes = document.bytes!;
      if (identical(bytes, _undecodable)) {
        return _Refused(
          message: "Can't display this image.",
          onOpenExternally: widget.onOpenExternally,
        );
      }
      return ImageViewer(
        bytes: bytes,
        controller: _zoom,
        onDecoded: (size) => setState(() => _decoded = (bytes, size)),
        onFailed: () => setState(() => _undecodable = bytes),
      );
    }
    return MediaPlayerView(
      path: document.localPath!,
      kind: document.kind,
      revision: document.revision,
      showing: widget.showing,
    );
  }

  static String _refusalText(MediaRefusal refusal) => switch (refusal) {
    MediaRefusal.notFound => 'This file is no longer on disk.',
    MediaRefusal.unreadable => 'This file cannot be read.',
    MediaRefusal.tooLarge => 'This file is too large to show here.',
    MediaRefusal.none => '',
  };

  /// `1280×720 · 84 KB · PNG` — what a reader checks a screenshot for.
  Widget _statusLine(Uint8List bytes, String name) {
    final decoded = _decoded;
    final size = decoded != null && identical(decoded.$1, bytes)
        ? decoded.$2
        : null;
    return _strip(
      mediaStatusLine(
        width: size?.width.round(),
        height: size?.height.round(),
        byteCount: bytes.length,
        name: name,
      ),
    );
  }

  /// The strip under a media file: its size and format, right-aligned.
  Widget _strip(String text) {
    final theme = Theme.of(context);
    return Container(
      height: Chrome.paneStrip,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      color: theme.colorScheme.surfaceContainerLow,
      alignment: Alignment.centerRight,
      child: Text(
        text,
        style: MonoStyles.small.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A media file's status line: dimensions (images, once decoded), size and
/// format.
String mediaStatusLine({
  int? width,
  int? height,
  required int byteCount,
  required String name,
}) => [
  if (width != null && height != null) '$width×$height',
  formatByteSize(byteCount),
  ?imageFormatOf(name),
].join(' · ');

/// `512 B`, `84 KB`, `3.2 MB`, `1.4 GB`.
String formatByteSize(int bytes) {
  const mb = 1024 * 1024;
  if (bytes < 1024) return '$bytes B';
  if (bytes < mb) return '${(bytes / 1024).round()} KB';
  if (bytes < 1024 * mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * mb)).toStringAsFixed(1)} GB';
}

/// The format a file's extension names, as it is usually written: `PNG`,
/// `JPEG`, `MP4`, `MP3`.
String? imageFormatOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  final extension = name.substring(dot + 1).toUpperCase();
  return extension == 'JPG' ? 'JPEG' : extension;
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const Center(child: InlineSpinner(size: InlineSpinnerSize.large));
}

/// Why the file is not shown, with the one way out there may be.
class _Refused extends StatelessWidget {
  const _Refused({required this.message, this.onOpenExternally});

  final String message;
  final VoidCallback? onOpenExternally;

  @override
  Widget build(BuildContext context) {
    final open = onOpenExternally;
    return PanePlaceholder(
      icon: AppIcons.warningCircle,
      message: message,
      action: open == null
          ? null
          : TextButton.icon(
              onPressed: open,
              icon: const Icon(AppIcons.arrowSquareOut),
              label: const Text('Open externally'),
            ),
    );
  }
}

/// A remote film on its way into the media cache: playable once it lands.
class _CopyProgress extends StatelessWidget {
  const _CopyProgress({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Copying to this machine… ${(progress * 100).round()}%',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Insets.sm),
              LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Video or audio on a client with no media backend: what can still be done
/// with the file, rather than a player that cannot start.
class _NoPlaybackCard extends StatelessWidget {
  const _NoPlaybackCard({
    required this.onCopyPath,
    this.onAttachToChat,
    this.attachDisabledReason,
  });

  final VoidCallback onCopyPath;
  final VoidCallback? onAttachToChat;
  final String? attachDisabledReason;

  @override
  Widget build(BuildContext context) {
    final attach = TextButton.icon(
      onPressed: onAttachToChat,
      icon: const Icon(AppIcons.chat),
      label: const Text('Attach to chat'),
    );
    return PanePlaceholder(
      icon: AppIcons.fileVideo,
      message: "Playback on this device isn't supported yet.",
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: Insets.sm,
        children: [
          TextButton.icon(
            onPressed: onCopyPath,
            icon: const Icon(AppIcons.copySimple),
            label: const Text('Copy path'),
          ),
          if (onAttachToChat == null && attachDisabledReason != null)
            Tooltip(message: attachDisabledReason, child: attach)
          else
            attach,
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    iconSize: Chrome.iconAction,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}

class _TextAction extends StatelessWidget {
  const _TextAction({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: TextButton(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        minimumSize: Size.zero,
      ),
      onPressed: onPressed,
      child: Text(label),
    ),
  );
}
