import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_icons.dart';
import '../code/code_spans.dart';
import '../code/code_theme.dart';
import '../design_tokens.dart';

/// Lines a code block shows before it folds behind "Show all".
const int kCodeBlockFoldLines = 30;

/// Lines a folded code block keeps in sight.
const int kCodeBlockHeadLines = 20;

/// The names agents write after a fence, as the highlighter knows them.
const Map<String, String> _languageAliases = {
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'console': 'bash',
  'ps1': 'powershell',
  'pwsh': 'powershell',
  'yml': 'yaml',
  'rs': 'rust',
  'kt': 'kotlin',
  'rb': 'ruby',
  'md': 'markdown',
  'html': 'xml',
  'svg': 'xml',
  'c++': 'cpp',
  'cs': 'csharp',
  'golang': 'go',
  'jsonc': 'json',
  'dockerfile': 'dockerfile',
  'patch': 'diff',
};

/// [language] as the highlighter spells it, or null when none was given.
String? highlightLanguage(String? language) {
  final lower = language?.trim().toLowerCase();
  if (lower == null || lower.isEmpty) return null;
  return _languageAliases[lower] ?? lower;
}

/// A fenced block of code: its language and a Copy above, highlighted, folded
/// past [kCodeBlockFoldLines], and scrolled sideways inside its own box — or
/// wrapped, under a thumb, where a sideways scroll reads as a clipped line.
class CodeBlock extends StatefulWidget {
  const CodeBlock({
    required this.source,
    this.language,
    this.wrap = false,
    this.highlight,
    super.key,
  });

  final String source;
  final String? language;
  final bool wrap;

  /// The highlight theme; null takes the one for the current brightness.
  final Map<String, TextStyle>? highlight;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final lines = widget.source.split('\n');
    final folds = lines.length > kCodeBlockFoldLines;
    final shown = folds && !_all
        ? lines.take(kCodeBlockHeadLines).join('\n')
        : widget.source;
    final highlight =
        widget.highlight ??
        codeHighlightTheme(dark ? Brightness.dark : Brightness.light);
    final code = Text.rich(
      highlightedCode(
        shown,
        language: highlightLanguage(widget.language),
        theme: highlight,
        base: MonoStyles.label.copyWith(color: scheme.onSurface),
      ),
      softWrap: widget.wrap,
    );
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.only(left: Insets.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.language?.trim() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                  CopyTextButton(text: widget.source, tooltip: 'Copy code'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.sm,
              0,
              Insets.sm,
              Insets.sm,
            ),
            child: widget.wrap
                ? code
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: code,
                  ),
          ),
          if (folds)
            SelectionContainer.disabled(
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('code-block-fold'),
                  onPressed: () => setState(() => _all = !_all),
                  icon: Icon(
                    _all ? AppIcons.caretUp : AppIcons.caretDown,
                    size: Chrome.iconSmall,
                  ),
                  label: Text(
                    _all ? 'Show less' : 'Show all (${lines.length} lines)',
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: theme.textTheme.labelSmall,
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small Copy that says "Copied" for a moment after it is pressed.
class CopyTextButton extends StatefulWidget {
  const CopyTextButton({required this.text, this.tooltip = 'Copy', super.key});

  final String text;
  final String tooltip;

  @override
  State<CopyTextButton> createState() => _CopyTextButtonState();
}

class _CopyTextButtonState extends State<CopyTextButton> {
  Timer? _settle;

  bool get _copied => _settle?.isActive ?? false;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    _settle?.cancel();
    setState(() {
      _settle = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final touch = UiDensity.of(context).isTouch;
    return IconButton(
      tooltip: _copied ? 'Copied' : widget.tooltip,
      iconSize: touch ? Touch.icon : Chrome.iconSmall,
      visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
      color: _copied
          ? SemanticColors.of(context).idle
          : Theme.of(context).colorScheme.onSurfaceVariant,
      onPressed: _copy,
      icon: Icon(_copied ? AppIcons.check : AppIcons.copySimple),
    );
  }
}
