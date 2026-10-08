part of '../chat_transcript.dart';

/// A run of tool calls as one line, opening into the rows it stands for.
/// Settled, the line says what the run did; live, it names the newest call.
/// Collapsed either way, with [TranscriptRow.pinned] drawn beneath it.
class _ToolBatchTile extends StatefulWidget {
  const _ToolBatchTile({
    required this.messages,
    required this.row,
    required this.rowAt,
    this.resolveHostPath,
    super.key,
  });

  /// The whole loaded window; [row] indexes into it.
  final List<ChatMessage> messages;
  final TranscriptRow row;
  final Widget Function(int offset) rowAt;
  final String? Function(String path)? resolveHostPath;

  @override
  State<_ToolBatchTile> createState() => _ToolBatchTileState();
}

class _ToolBatchTileState extends State<_ToolBatchTile> {
  bool _open = false;
  bool _hovered = false;

  (List<ChatMessage>, TranscriptRow)? _imagesFor;
  List<String> _named = const [];
  List<String> _returned = const [];

  /// The pictures the folded calls named or answered with, so a fold never
  /// hides one. A pinned call draws its own.
  void _foldedImages() {
    final key = (widget.messages, widget.row);
    if (_imagesFor case (
      final m,
      final r,
    ) when identical(m, key.$1) && r == key.$2) {
      return;
    }
    _imagesFor = key;
    final named = <String>{};
    final returned = <String>{};
    final row = widget.row;
    for (var i = row.from; i < row.to; i++) {
      if (row.pinned.contains(i)) continue;
      final tool = widget.messages[i].tool;
      if (tool == null) continue;
      named
        ..addAll(inlineImagePaths(tool.subject))
        ..addAll(inlineImagePaths(tool.output));
      if (tool.imagePath case final path?) returned.add(path);
    }
    _named = named.toList();
    _returned = returned.difference(named).toList();
  }

  Widget _folded() {
    _foldedImages();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TranscriptImageStrip(paths: _named),
        if (_returned.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: SelectionContainer.disabled(
              child: Wrap(
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                children: [
                  for (final path in _returned)
                    TranscriptImagePreview(
                      path: path,
                      resolveHostPath: widget.resolveHostPath,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

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
      (label, labelSpan) = _settledLabel(
        run,
        strong: strong,
        muted: muted,
        failure: muted?.copyWith(color: SemanticColors.of(context).failure),
      );
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
                          if (row.live)
                            _CommandTime(
                              message: run.last,
                              lead: ' · ',
                              style: muted,
                            ),
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
                        for (final (from, to) in toolCallLines(
                          widget.messages,
                          row.from,
                          row.to,
                        ))
                          if (to - from == 1)
                            _ToolCallLine(
                              message: widget.messages[from],
                              card: () => widget.rowAt(from),
                            )
                          else
                            _ToolLookupLine(
                              messages: widget.messages,
                              from: from,
                              to: to,
                              rowAt: widget.rowAt,
                            ),
                      ],
                    ),
                  ),
                ),
              )
            else ...[
              for (final i in row.pinned) widget.rowAt(i),
              // A settled run's failures stay in sight under its line, each
              // with its first words; the card is a click away.
              if (!row.live)
                for (var i = row.from; i < row.to; i++)
                  if (toolCallFailed(widget.messages[i]))
                    _ToolCallLine(
                      message: widget.messages[i],
                      card: () => widget.rowAt(i),
                      showError: true,
                    ),
              _folded(),
            ],
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
  required TextStyle? failure,
}) {
  final worked = describeWorkedFor(run);
  var did = describeToolRun(run);
  // The failure count in the failure colour: it is what the line is for.
  final failedAt = did.lastIndexOf(_failedCount);
  final failed = failedAt < 0 ? '' : did.substring(failedAt);
  if (failedAt >= 0) did = did.substring(0, failedAt);
  final failedSpan = failed.isEmpty
      ? null
      : TextSpan(text: failed, style: failure);
  if (worked != null) {
    final rest = did.isEmpty
        ? ''
        : ' · ${did[0].toLowerCase()}${did.substring(1).replaceAll(', ', ' · ')}';
    return (
      '$worked$rest$failed',
      TextSpan(
        children: [
          TextSpan(text: worked, style: strong),
          TextSpan(text: rest, style: muted),
          ?failedSpan,
        ],
      ),
    );
  }
  final cut = did.indexOf(', ') > 0 ? did.indexOf(', ') : did.length;
  return (
    '$did$failed',
    TextSpan(
      children: [
        TextSpan(text: did.substring(0, cut), style: strong),
        TextSpan(text: did.substring(cut), style: muted),
        ?failedSpan,
      ],
    ),
  );
}

final _failedCount = RegExp(r' · \d+ failed$');

/// Commands whose passing is a result worth colouring: a test, analyze, lint
/// or check run. Anything else that exits cleanly only says how much it wrote.
final _checkCommand = RegExp(
  r'\b(test|tests|analy[sz]e|lint|check|checks|verify)\b',
);

/// One call inside an opened run: a status dot, the verb, its path or command
/// in mono, and what came of it at the far end. A click opens the full card
/// under it, output and all — the line is the index, the card the page.
class _ToolCallLine extends StatefulWidget {
  const _ToolCallLine({
    required this.message,
    required this.card,
    this.showError = false,
  });

  final ChatMessage message;

  /// The call's full row, built only once it is opened.
  final Widget Function() card;

  /// Under a settled run's line: the failure's first words beneath it.
  final bool showError;

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
    final verb = toolVerb(kind);
    final what = subject == null || subject.isEmpty
        ? toolDisplayName(tool.name)
        : verb == null
        ? '${toolDisplayName(tool.name)}  $subject'
        : subject;
    final failed = toolCallFailed(message);
    final (result, resultColour) = failed
        ? ('failed', semantic.failure)
        : _resultOf(
            message,
            kind,
            subject: subject,
            failure: semantic.failure,
            passed: semantic.idle,
          );
    final took = commandDuration(message);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final resultStyle = muted?.copyWith(color: resultColour);
    final (dotColour, state) = message.pending && !failed
        ? (semantic.working, 'running')
        : failed
        ? (semantic.failure, 'failed')
        : (semantic.idle, 'done');
    final headline = widget.showError ? toolErrorHeadline(tool) : null;

    final line = Row(
      children: [
        StatusDot(color: dotColour, label: state),
        const SizedBox(width: Insets.sm),
        // One text, so a narrow line gives way inside it rather than past it.
        Expanded(
          flex: 3,
          child: Text.rich(
            TextSpan(
              children: [
                if (verb != null) TextSpan(text: '$verb  ', style: muted),
                TextSpan(
                  text: what,
                  style: MonoStyles.body.copyWith(
                    color: failed ? semantic.failure : scheme.onSurface,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (result.isNotEmpty) ...[
          const SizedBox(width: Insets.sm),
          Flexible(
            // At the line's far end, however short.
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                result,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: resultStyle,
              ),
            ),
          ),
        ],
        _CommandTime(message: message, lead: ' · ', style: muted),
      ],
    );

    return Padding(
      key: widget.showError ? const ValueKey('chat-tool-error') : null,
      // Under the run's line, level with its words rather than its caret.
      padding: EdgeInsets.only(left: widget.showError ? Insets.lg : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectionContainer.disabled(
            child: Semantics(
              button: true,
              expanded: _open,
              label: [
                ?verb,
                what,
                state,
                if (result.isNotEmpty && result != state) result,
                if (took != null) 'took ${formatCommandDuration(took)}',
                ?headline,
              ].join(', '),
              excludeSemantics: true,
              child: InkWell(
                onTap: () => setState(() => _open = !_open),
                hoverColor: SurfaceTones.of(context).hover,
                borderRadius: BorderRadius.circular(Radii.sm),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: _lineHeight(context)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                    child: headline == null
                        ? line
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              line,
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: Chrome.dot + Insets.sm,
                                  bottom: Insets.xs,
                                ),
                                child: Text(
                                  headline,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: muted?.copyWith(
                                    color: semantic.failure,
                                  ),
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
          else if (tool.edits.isNotEmpty && !widget.showError)
            // The opened card draws the same diff, so it is drawn once.
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: ToolEditDiffCard(activity: tool),
            ),
        ],
      ),
    );
  }
}

/// Reads and searches in a row as one line — `Read 4 files · ran 2
/// searches` — opening into a line each.
class _ToolLookupLine extends StatefulWidget {
  const _ToolLookupLine({
    required this.messages,
    required this.from,
    required this.to,
    required this.rowAt,
  });

  final List<ChatMessage> messages;
  final int from;
  final int to;
  final Widget Function(int offset) rowAt;

  @override
  State<_ToolLookupLine> createState() => _ToolLookupLineState();
}

class _ToolLookupLineState extends State<_ToolLookupLine> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final label = describeToolRun(
      widget.messages.sublist(widget.from, widget.to),
    ).replaceAll(', ', ' · ');
    return Column(
      key: const ValueKey('chat-tool-lookups'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectionContainer.disabled(
          child: Semantics(
            button: true,
            expanded: _open,
            label: label,
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
                      StatusDot(
                        color: SemanticColors.of(context).idle,
                        label: 'done',
                      ),
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted?.copyWith(color: scheme.onSurface),
                        ),
                      ),
                      const SizedBox(width: Insets.xs),
                      Icon(
                        _open ? AppIcons.caretDown : AppIcons.caretRight,
                        size: Chrome.iconSmall,
                        color: muted?.color,
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
            padding: const EdgeInsets.only(left: Insets.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = widget.from; i < widget.to; i++)
                  _ToolCallLine(
                    message: widget.messages[i],
                    card: () => widget.rowAt(i),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A fold or call line's height: the board's row, or the touch floor.
double _lineHeight(BuildContext context) =>
    UiDensity.of(context).isTouch ? Touch.target : Chrome.row;

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
    ToolKind.read => ('', null),
    ToolKind.edit => ('', null),
    ToolKind.patch => ('', null),
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
