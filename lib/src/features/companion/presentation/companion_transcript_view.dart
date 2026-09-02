import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../sessions/presentation/markdown_message.dart';
import '../client/companion_gateway.dart';

/// The phone's transcript: a conversation drawn from its newest message
/// upwards.
///
/// The desktop's [ChatTranscriptView] is a forward list that jumps to
/// `maxScrollExtent` once, after the first frame. On a lazy list that extent is
/// an *estimate* from the children laid out so far, and a real session's newest
/// turns are its longest — measured on a 300-message window, opening one landed
/// 4391px short of the end with the newest message never built. That is the
/// "I cannot find the edge of the session" report. A reversed list has no
/// estimate to be wrong about: offset zero **is** the newest message, on the
/// first frame and on every frame after it.
class CompanionTranscriptView extends StatefulWidget {
  const CompanionTranscriptView({
    required this.messages,
    this.footer,
    this.emptyHint = 'No messages yet.',
    super.key,
  });

  /// Oldest first, exactly as the gateway holds it; the list draws bottom-up.
  final List<CompanionChatMessage> messages;

  /// Pinned under the conversation — the approval card and the composer.
  final Widget? footer;

  final String emptyHint;

  @override
  State<CompanionTranscriptView> createState() =>
      _CompanionTranscriptViewState();
}

class _CompanionTranscriptViewState extends State<CompanionTranscriptView> {
  /// How far off the newest message still counts as being at the bottom.
  static const _slack = 24.0;

  final _scroll = ScrollController();
  bool _atLatest = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(CompanionTranscriptView old) {
    super.didUpdateWidget(old);
    // Only the reader who is already at the newest message is carried to the
    // next one; anyone reading history keeps the pixel they were on, which a
    // reversed list gives for free.
    if (_atLatest && widget.messages.length != old.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (_scroll.position.pixels > 0) _scroll.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atLatest = _scroll.position.pixels <= _slack;
    if (atLatest != _atLatest) setState(() => _atLatest = atLatest);
  }

  Future<void> _toLatest() =>
      _scroll.animateTo(0, duration: Motion.base, curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = widget.messages.length;

    return Column(
      children: [
        Expanded(
          child: total == 0
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.xl),
                    child: Text(
                      widget.emptyHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : Stack(
                  children: [
                    ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.md,
                        vertical: Insets.sm,
                      ),
                      itemCount: total,
                      // Keyed by position in the whole window so a message
                      // that only moved because a newer one arrived keeps its
                      // element — the sliver then corrects its own offsets
                      // instead of redrawing different text under a reader.
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<int>) return null;
                        final index = total - 1 - key.value;
                        return index >= 0 && index < total ? index : null;
                      },
                      itemBuilder: (context, index) {
                        final ordinal = total - 1 - index;
                        final message = widget.messages[ordinal];
                        return message.role == kCompanionNoticeRole
                            ? _WindowTopNotice(
                                key: ValueKey<int>(ordinal),
                                text: message.text,
                              )
                            : _MessageTile(
                                key: ValueKey<int>(ordinal),
                                message: message,
                              );
                      },
                    ),
                    if (!_atLatest)
                      Positioned(
                        left: Insets.md,
                        right: Insets.md,
                        bottom: Insets.md,
                        child: Center(child: _JumpToLatest(onPressed: _toLatest)),
                      ),
                  ],
                ),
        ),
        if (widget.footer != null) widget.footer!,
      ],
    );
  }
}

/// The way back to the newest message, shown only once the reader has left it.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: onPressed,
    icon: const Icon(AppIcons.arrowDown),
    label: const Text('Jump to latest', maxLines: 1),
  );
}

/// The top of what the phone was sent: the history the host kept back.
///
/// Drawn as a boundary rather than as a message on purpose — the same words in
/// a `tool` row read as something the agent said, and a reader looking for the
/// end of a conversation can mistake any message for the last one.
class _WindowTopNotice extends StatelessWidget {
  const _WindowTopNotice({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Container(
        padding: const EdgeInsets.all(Insets.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              AppIcons.caretUp,
              size: density.iconSmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            SizedBox(width: density.glyphGap),
            Expanded(child: Text(text, style: density.muted(theme))),
          ],
        ),
      ),
    );
  }
}

/// One turn, in the desktop chat's shapes at a thumb's sizes.
class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, super.key});

  final CompanionChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);

    final (String gutter, Color color, String label) = switch (message.role) {
      'user' => ('›', scheme.primary, 'You'),
      'tool' => ('⏺', scheme.tertiary, 'Tool'),
      'error' => ('✗', SemanticColors.of(context).failure, 'Error'),
      _ => ('●', scheme.onSurface, 'Agent'),
    };
    final prose = message.role == 'user' || message.role == 'agent';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: Touch.icon,
            child: Text(
              gutter,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(width: density.glyphGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _CopyButton(text: message.text),
                  ],
                ),
                SizedBox(height: density.lineGap),
                if (prose)
                  MarkdownMessage(message.text)
                else
                  SelectableText(
                    message.text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: kMonoFamily,
                      height: 1.35,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Copy-to-clipboard, at a size a thumb can hit.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final density = UiDensity.of(context);
    return IconButton(
      tooltip: _copied ? 'Copied' : 'Copy message',
      iconSize: density.icon,
      constraints: BoxConstraints(
        minWidth: density.minRow,
        minHeight: density.minRow,
      ),
      padding: EdgeInsets.zero,
      color: _copied ? SemanticColors.of(context).idle : scheme.onSurfaceVariant,
      icon: Icon(_copied ? AppIcons.check : AppIcons.copySimple),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        if (!mounted) return;
        setState(() => _copied = true);
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _copied = false);
      },
    );
  }
}
