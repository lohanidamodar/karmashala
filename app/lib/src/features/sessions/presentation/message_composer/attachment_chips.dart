// The attachment chips: pointer pills and touch rows with upload progress.

part of '../message_composer.dart';

/// The attachments as board N2 draws them: a row of pills, each an image
/// glyph, the file's name and a remove button. Where the files go is the
/// pill's tooltip — a sentence under them, always drawn, cost 31px.
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({
    required this.attachments,
    required this.uploading,
    required this.asImages,
    required this.onRemove,
  });

  final List<_Attachment> attachments;

  /// Whether the agent takes an image as an image, which the tooltip says.
  final bool asImages;

  /// Pasted images still being sent, each drawn as a chip that says so.
  final int uploading;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.md, 0),
    child: Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        for (var i = 0; i < attachments.length; i++)
          _AttachmentChip(
            name: attachments[i].name,
            where: attachments[i].whereFor(asImage: asImages),
            image: attachments[i].image,
            preview: attachments[i].preview,
            onRemove: () => onRemove(i),
          ),
        for (var i = 0; i < uploading; i++)
          const _AttachmentChip(
            name: 'Sending…',
            where: 'Uploading to the server; Send waits until it is there.',
          ),
      ],
    ),
  );
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.name,
    required this.where,
    this.image = false,
    this.preview,
    this.onRemove,
  });

  final String name;
  final String where;
  final bool image;

  /// Drawn in place of the glyph when there is one.
  final ImageProvider? preview;

  /// Null while the image is still being sent: a spinner stands in its place.
  final VoidCallback? onRemove;

  /// The pill's height, which the composer's sizing counts.
  static const height = Chrome.control;

  Widget _glyph(Color muted) {
    final icon = Icon(
      image ? AppIcons.image : AppIcons.file,
      size: Chrome.iconSmall,
      color: muted,
    );
    final preview = this.preview;
    if (preview == null) return icon;
    const edge = height - 2 * Insets.xs;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Image(
        image: preview,
        width: edge,
        height: edge,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => icon,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final onRemove = this.onRemove;
    return Tooltip(
      message: where,
      child: Container(
        height: height,
        padding: const EdgeInsets.only(left: Insets.sm),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glyph(muted),
            const SizedBox(width: Insets.xs),
            ConstrainedBox(
              // A long generated name gives way before the remove button.
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
            if (onRemove == null)
              const SizedBox.square(
                dimension: height,
                child: Center(child: InlineSpinner()),
              )
            else
              IconButton(
                tooltip: 'Remove',
                iconSize: Chrome.iconSmall,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: height,
                  minHeight: height,
                ),
                padding: EdgeInsets.zero,
                color: muted,
                icon: const Icon(AppIcons.x),
                onPressed: onRemove,
              ),
          ],
        ),
      ),
    );
  }
}

/// The attachments at touch density: one 48dp row each, with a thumbnail for
/// a picture and where the file lives as a second line, not a tooltip. An
/// upload in flight shows its percentage and *Cancel*; one that stopped says
/// why, with *Try again*.
class _TouchAttachmentList extends StatelessWidget {
  const _TouchAttachmentList({
    required this.attachments,
    required this.uploads,
    required this.onRemove,
    required this.onCancel,
    required this.onRetry,
  });

  final List<_Attachment> attachments;
  final List<_Upload> uploads;

  /// Null while the composer is sending.
  final ValueChanged<int>? onRemove;
  final ValueChanged<_Upload> onCancel;
  final ValueChanged<_Upload> onRetry;

  @override
  Widget build(BuildContext context) {
    final onRemove = this.onRemove;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.sm, Insets.xs, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < attachments.length; i++)
            _TouchAttachmentRow(
              name: attachments[i].name,
              detail: attachments[i].detail,
              image: attachments[i].image,
              preview: attachments[i].preview,
              actions: [
                _RowAction(
                  tooltip: 'Remove',
                  icon: AppIcons.x,
                  onPressed: onRemove == null ? null : () => onRemove(i),
                ),
              ],
            ),
          for (final upload in uploads) _uploadRow(upload),
        ],
      ),
    );
  }

  Widget _uploadRow(_Upload upload) {
    final failure = upload.failure;
    final size = upload.size;
    if (failure != null) {
      return _TouchAttachmentRow(
        name: upload.pick.name,
        detail: failure,
        failed: true,
        image: upload.image,
        preview: upload.preview,
        actions: [
          _RowAction(
            tooltip: 'Try again',
            icon: AppIcons.arrowClockwise,
            onPressed: () => onRetry(upload),
          ),
          _RowAction(
            tooltip: 'Remove',
            icon: AppIcons.x,
            onPressed: () => onCancel(upload),
          ),
        ],
      );
    }
    if (upload.queued) {
      return _TouchAttachmentRow(
        name: upload.pick.name,
        detail: size == null
            ? 'Uploaded to ${upload.server.name} when you send'
            : '${formatBytes(size)} · uploaded when you send',
        image: upload.image,
        preview: upload.preview,
        actions: [
          _RowAction(
            tooltip: 'Remove',
            icon: AppIcons.x,
            onPressed: () => onCancel(upload),
          ),
        ],
      );
    }
    final fraction = size == null || size == 0
        ? null
        : (upload.sent / size).clamp(0.0, 1.0);
    final server = upload.server.name;
    return _TouchAttachmentRow(
      name: upload.pick.name,
      detail: fraction == null
          ? 'Sending to $server…'
          : fraction >= 1
          ? 'Finishing on $server…'
          : '${(fraction * 100).floor()}% · ${formatBytes(upload.sent)} of '
                '${formatBytes(size!)}',
      progress: fraction ?? 0,
      indeterminate: fraction == null || fraction >= 1,
      image: upload.image,
      preview: upload.preview,
      actions: [
        _RowAction(
          tooltip: 'Cancel the upload',
          icon: AppIcons.x,
          onPressed: () => onCancel(upload),
        ),
      ],
    );
  }
}

class _RowAction {
  const _RowAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
}

class _TouchAttachmentRow extends StatelessWidget {
  const _TouchAttachmentRow({
    required this.name,
    required this.detail,
    required this.image,
    required this.actions,
    this.preview,
    this.failed = false,
    this.progress,
    this.indeterminate = false,
  });

  /// One row, which the composer's sizing counts.
  static const height = Touch.target + Insets.xs;

  final String name;
  final String detail;
  final bool image;
  final ImageProvider? preview;
  final bool failed;

  /// Drawn as a bar under the words while an upload runs; null otherwise.
  final double? progress;
  final bool indeterminate;
  final List<_RowAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final glyph = Icon(
      image ? AppIcons.image : AppIcons.file,
      size: Touch.icon,
      color: muted,
    );
    final preview = this.preview;
    final progress = this.progress;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.target),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: SizedBox.square(
                dimension: _thumbnail,
                child: preview == null
                    ? Center(child: glyph)
                    : Image(
                        image: preview,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => Center(child: glyph),
                      ),
              ),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: failed ? scheme.error : muted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (progress != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.xs),
                      child: LinearProgressIndicator(
                        value: indeterminate ? null : progress,
                        semanticsLabel: 'Sending $name',
                        semanticsValue: indeterminate
                            ? null
                            : '${(progress * 100).floor()}%',
                      ),
                    ),
                ],
              ),
            ),
            for (final action in actions)
              IconButton(
                tooltip: action.tooltip,
                onPressed: action.onPressed,
                constraints: const BoxConstraints(
                  minWidth: Touch.target,
                  minHeight: Touch.target,
                ),
                iconSize: Touch.icon,
                color: muted,
                icon: Icon(action.icon),
              ),
          ],
        ),
      ),
    );
  }
}
