part of '../chat_transcript.dart';

/// A run of tool calls as one line, opening into the rows it stands for.
/// Settled, the line says what the run did; live, it names the newest call.
/// Collapsed either way, with [TranscriptRow.pinned] drawn beneath it.
class _ToolBatchTile extends StatefulWidget {
  const _ToolBatchTile({
    required this.messages,
    required this.row,
    required this.rowAt,
    super.key,
  });

  /// The whole loaded window; [row] indexes into it.
  final List<ChatMessage> messages;
  final TranscriptRow row;
  final Widget Function(int offset) rowAt;

  @override
  State<_ToolBatchTile> createState() => _ToolBatchTileState();
}

class _ToolBatchTileState extends State<_ToolBatchTile> {
  bool _open = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final row = widget.row;
    final run = widget.messages.sublist(row.from, row.to);
    // Board N2's fold line: 12.5px, muted, turning to the foreground under
    // the pointer along with its wash.
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: _hovered ? scheme.onSurface : scheme.onSurfaceVariant,
    );
    final strong = muted?.copyWith(color: scheme.onSurface);

    final String label;
    final InlineSpan labelSpan;
    final String? detail;
    final IconData? glyph;
    if (row.live) {
      final newest = run.last.tool!;
      final subject = newest.subject?.split('\n').first;
      final name = toolDisplayName(newest.name);
      label = 'Working';
      labelSpan = TextSpan(text: label, style: strong);
      detail =
          subject == null ||
              subject.isEmpty ||
              subject == name ||
              subject == newest.name
          ? name
          : '$name  $subject';
      glyph = _toolIcon(newest.name);
    } else {
      (label, labelSpan) = _settledLabel(run, strong: strong, muted: muted);
      detail = null;
      glyph = null;
    }
    final earlier = row.live && row.length > 1
        ? '${row.length} calls so far'
        : null;

    return MessageBoundary(
      raw: run.map(rawMessageText).join('\n\n'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectionContainer.disabled(
              child: Semantics(
                button: true,
                expanded: _open,
                label: [label, ?detail, ?earlier].join('. '),
                child: InkWell(
                  onTap: () => setState(() => _open = !_open),
                  onHover: (hovered) => setState(() => _hovered = hovered),
                  hoverColor: tones.hover,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: ConstrainedBox(
                    // Board N2: one 26px line, however many calls it stands for;
                    // a thumb's 48 at touch density, where the caret is the sign.
                    constraints: BoxConstraints(
                      minHeight: _lineHeight(context),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.sm,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _open ? AppIcons.caretDown : AppIcons.caretRight,
                            size: Chrome.iconSmall,
                            color: muted?.color,
                          ),
                          const SizedBox(width: Insets.sm),
                          if (glyph != null) ...[
                            // A still glyph, not a spinner: the activity line
                            // under the transcript already spins for the turn.
                            Icon(
                              glyph,
                              size: Chrome.iconSmall,
                              color: SemanticColors.of(context).working,
                            ),
                            const SizedBox(width: Insets.xs),
                          ],
                          Flexible(
                            flex: detail == null ? 1 : 0,
                            child: Text.rich(
                              labelSpan,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (detail != null) ...[
                            const SizedBox(width: Insets.sm),
                            Expanded(
                              child: Text(
                                detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: MonoStyles.body.copyWith(
                                  color: muted?.color,
                                ),
                              ),
                            ),
                          ],
                          if (earlier != null) ...[
                            const SizedBox(width: Insets.sm),
                            Flexible(
                              child: Text(
                                earlier,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: muted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_open)
              // Board N2: the calls indented under the line, on a 1px rule.
              Padding(
                padding: const EdgeInsets.only(
                  left: Insets.lg + Insets.hair * 2,
                  top: Insets.hair * 2,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: Insets.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = row.from; i < row.to; i++)
                          _ToolCallLine(
                            message: widget.messages[i],
                            card: () => widget.rowAt(i),
                          ),
                      ],
                    ),
                  ),
                ),
              )
            else
              for (final i in row.pinned) widget.rowAt(i),
            if (!row.live)
              if (turnChangedFiles(widget.messages, row) case final files?)
                TurnChangedFilesLine(files: files),
          ],
        ),
      ),
    );
  }
}

/// A settled run's line as board N2 writes it — `Worked for 2m 12s · read 4
/// files · ran 3 commands` — with the first phrase in the foreground and the
/// rest muted. Returns the plain text too, for the semantics label.
///
/// With no duration the sentence is [describeToolRun]'s own, commas and all,
/// and only its first phrase is lifted: the words do not change with the
/// colouring, so the plain text reads the same to a finder and a reader.
(String, InlineSpan) _settledLabel(
  List<ChatMessage> run, {
  required TextStyle? strong,
  required TextStyle? muted,
}) {
  final worked = describeWorkedFor(run);
  final did = describeToolRun(run);
  if (worked != null) {
    final rest = did.isEmpty
        ? ''
        : ' · ${did[0].toLowerCase()}${did.substring(1).replaceAll(', ', ' · ')}';
    return (
      '$worked$rest',
      TextSpan(
        children: [
          TextSpan(text: worked, style: strong),
          TextSpan(text: rest, style: muted),
        ],
      ),
    );
  }
  final cut = [
    did.indexOf(', '),
    did.indexOf(' · '),
  ].where((i) => i > 0).fold<int>(did.length, math.min);
  return (
    did,
    TextSpan(
      children: [
        TextSpan(text: did.substring(0, cut), style: strong),
        TextSpan(text: did.substring(cut), style: muted),
      ],
    ),
  );
}

/// Commands whose passing is a result worth colouring: a test, analyze, lint
/// or check run. Anything else that exits cleanly only says how much it wrote.
final _checkCommand = RegExp(
  r'\b(test|tests|analy[sz]e|lint|check|checks|verify)\b',
);

/// One call inside an opened run (board N2): its glyph, its path or command
/// in mono, and what came of it at the far end. A click opens the full card
/// under it, output and all — the line is the index, the card the page.
class _ToolCallLine extends StatefulWidget {
  const _ToolCallLine({required this.message, required this.card});

  final ChatMessage message;

  /// The call's full row, built only once it is opened.
  final Widget Function() card;

  @override
  State<_ToolCallLine> createState() => _ToolCallLineState();
}

class _ToolCallLineState extends State<_ToolCallLine> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final message = widget.message;
    final tool = message.tool!;
    final kind = toolKindOf(tool.name, kind: tool.kind);
    final subject = tool.subject?.split('\n').first.trim();
    final named = switch (kind) {
      ToolKind.read ||
      ToolKind.edit ||
      ToolKind.patch ||
      ToolKind.command ||
      ToolKind.search => false,
      _ => true,
    };
    final what = subject == null || subject.isEmpty
        ? toolDisplayName(tool.name)
        : named
        ? '${toolDisplayName(tool.name)}  $subject'
        : subject;
    final (result, resultColour) = _resultOf(
      message,
      kind,
      subject: subject,
      failure: semantic.failure,
      passed: semantic.idle,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectionContainer.disabled(
          child: Semantics(
            button: true,
            expanded: _open,
            label: '$what, $result',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              hoverColor: SurfaceTones.of(context).hover,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: _lineHeight(context)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                  child: Row(
                    children: [
                      Icon(
                        _kindIcon(kind),
                        size: Chrome.iconSmall,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          what,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MonoStyles.body.copyWith(
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      Text(
                        result,
                        maxLines: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: resultColour ?? scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: widget.card(),
          )
        else if (tool.edits.isNotEmpty)
          // The opened card draws the same diff, so it is drawn once.
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: ToolEditDiffCard(activity: tool),
          ),
      ],
    );
  }
}

/// A fold or call line's height: the board's row, or the touch floor.
double _lineHeight(BuildContext context) =>
    UiDensity.of(context).isTouch ? Touch.target : Chrome.row;

/// The glyph for what a call did, by the same kinds the fold line counts.
IconData _kindIcon(ToolKind kind) => switch (kind) {
  ToolKind.command => AppIcons.terminal,
  ToolKind.read => AppIcons.file,
  ToolKind.edit => AppIcons.pencilSimple,
  ToolKind.patch => AppIcons.gitDiff,
  ToolKind.search => AppIcons.magnifyingGlass,
  ToolKind.webSearch || ToolKind.webFetch => AppIcons.globe,
  ToolKind.delegate => AppIcons.robot,
  ToolKind.plan => AppIcons.listChecks,
  ToolKind.question => AppIcons.question,
  ToolKind.mcp || ToolKind.other => AppIcons.gearSix,
};

/// What came of one call, as the right end of its line says it: a failure in
/// the failure colour, a passing check in the healthy one, and otherwise the
/// plain fact the record holds — never a success nobody recorded.
(String, Color?) _resultOf(
  ChatMessage message,
  ToolKind kind, {
  required String? subject,
  required Color failure,
  required Color passed,
}) {
  final tool = message.tool!;
  if (tool.isError) return ('failed', failure);
  if (message.pending) return ('running', null);
  final output = tool.output?.trimRight() ?? '';
  final lines = output.isEmpty ? 0 : '\n'.allMatches(output).length + 1;
  final more = tool.outputTruncated ? '+' : '';
  String counted(String one, String many) =>
      lines == 1 && more.isEmpty ? '1 $one' : '$lines$more $many';
  return switch (kind) {
    ToolKind.read => ('read', null),
    ToolKind.edit => ('edited', null),
    ToolKind.patch => ('applied', null),
    ToolKind.search =>
      lines == 0 ? ('no matches', null) : (counted('match', 'matches'), null),
    ToolKind.command when subject != null && _checkCommand.hasMatch(subject) =>
      ('passed ✓', passed),
    ToolKind.command =>
      lines == 0 ? ('no output', null) : (counted('line', 'lines'), null),
    ToolKind.webSearch => ('searched', null),
    ToolKind.webFetch => ('fetched', null),
    ToolKind.plan => ('updated', null),
    ToolKind.question => ('answered', null),
    ToolKind.delegate || ToolKind.mcp || ToolKind.other => ('done', null),
  };
}
