import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// How much a [SettingsNotice] asks of the reader.
enum SettingsNoticeTone {
  /// A fact, or a reading nobody has taken yet.
  neutral,

  /// Something measured and fine.
  positive,

  /// Something the user should look at, that is not yet a failure.
  attention,

  /// Something failed or is unsafe.
  danger;

  IconData get defaultIcon => switch (this) {
    neutral => AppIcons.info,
    positive => AppIcons.checkCircle,
    attention || danger => AppIcons.warningCircle,
  };
}

/// One line said under a setting: a glyph, a sentence that wraps, and an
/// optional action. The settings surfaces' single notice — the page draws them
/// unfilled, unlike a pane's `PaneNoticeBar`, because they sit among rows.
///
/// Never colour alone: the [message] says what the tone means.
class SettingsNotice extends StatelessWidget {
  const SettingsNotice({
    required this.message,
    this.tone = SettingsNoticeTone.neutral,
    this.icon,
    this.detail,
    this.action,
    super.key,
  });

  final String message;
  final SettingsNoticeTone tone;

  /// The glyph; [SettingsNoticeTone.defaultIcon] when null.
  final IconData? icon;

  /// A second sentence in the body colour, such as the service's own words
  /// under a headline.
  final String? detail;

  /// A button, typically a `TextButton` — Retry, Check.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    // Status colours, not form chrome: `SemanticColors.failure` rather than
    // `ColorScheme.error`, which also paints validation.
    final (glyph, ink) = switch (tone) {
      SettingsNoticeTone.neutral => (semantic.neutral, scheme.onSurfaceVariant),
      SettingsNoticeTone.positive => (scheme.primary, scheme.onSurfaceVariant),
      SettingsNoticeTone.attention => (semantic.attention, scheme.onSurface),
      SettingsNoticeTone.danger => (semantic.failure, semantic.failure),
    };
    final detail = this.detail;
    final action = this.action;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon ?? tone.defaultIcon, size: Chrome.icon, color: glyph),
        const SizedBox(width: Insets.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(color: ink),
              ),
              if (detail != null)
                Text(detail, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        if (action != null) ...[const SizedBox(width: Insets.xs), action],
      ],
    );
  }
}
