import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_devices/devices.dart' show describeDriveAge;
import '../application/browser_pane_controller.dart';
import '../data/browser_data.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show BrowserStatus, DataRefused;
import 'browser_viewport_shot.dart';

/// What the console last asked, and what came back.
class BrowserConsoleAnswer {
  const BrowserConsoleAnswer({
    required this.query,
    required this.text,
    required this.at,
    this.failed = false,
  });

  /// The expression or the search, as the user typed it.
  final String query;

  /// What the page said, rendered — or the failure, in the words the service
  /// refused with.
  final String text;

  final DateTime at;
  final bool failed;
}

/// Which question the console is asking. `browser_find`'s two ways of naming
/// an element are two modes, not one box that guesses which you meant.
enum BrowserConsoleMode {
  /// `browser_evaluate` — an expression, in the attached page.
  evaluate('Evaluate', 'document.title'),

  /// `browser_find`'s `selector:`.
  selector('Selector', '#submit'),

  /// `browser_find`'s `text:` — the words a person can see on the element.
  text('Text', 'Sign in');

  const BrowserConsoleMode(this.label, this.hint);

  final String label;
  final String hint;
}

/// A console for the attached page, through the server's browser the tools
/// call. Not behind the evaluate gate: the person is typing it themselves.
class BrowserConsole extends ConsumerStatefulWidget {
  const BrowserConsole({required this.state, super.key});

  final BrowserPaneState state;

  /// Whether there is a page to ask. False disables the field rather than
  /// hiding it: a control that vanishes reads as a fault.
  bool get enabled => state.status == BrowserStatus.connected;

  @override
  ConsumerState<BrowserConsole> createState() => _BrowserConsoleState();
}

class _BrowserConsoleState extends ConsumerState<BrowserConsole> {
  /// How many matches the pane lists. The same order as `browser_find`'s own
  /// listing, and the count of what is not listed is printed beside it.
  static const int shownMatches = 10;

  /// The longest answer drawn. A page can return a megabyte of JSON from one
  /// expression, and a scroll view is not the place to find that out.
  static const int maxAnswerChars = 4000;

  final _query = TextEditingController();
  BrowserConsoleMode _mode = BrowserConsoleMode.evaluate;
  BrowserConsoleAnswer? _answer;
  bool _busy = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final query = _query.text.trim();
    if (query.isEmpty || _busy) return;
    setState(() => _busy = true);
    final browser = ref.read(browserDataProvider);
    String text;
    var failed = false;
    try {
      text = switch (_mode) {
        BrowserConsoleMode.evaluate => await browser.evaluate(query),
        BrowserConsoleMode.selector => await browser.find(
          selector: query,
          limit: shownMatches,
        ),
        BrowserConsoleMode.text => await browser.find(
          text: query,
          limit: shownMatches,
        ),
      };
    } on DataRefused catch (refusal) {
      // The server's refusal in the browser taxonomy's own sentence.
      text = refusal.message;
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _answer = BrowserConsoleAnswer(
        query: query,
        text: text.length > maxAnswerChars
            ? '${text.substring(0, maxAnswerChars)}\n… '
                  '${text.length - maxAnswerChars} more characters not shown'
            : text,
        at: ref.read(clockProvider).nowUtc(),
        failed: failed,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final answer = _answer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.sm,
            Insets.xs,
            Insets.sm,
            Insets.xs,
          ),
          child: Row(
            children: [
              DropdownButton<BrowserConsoleMode>(
                value: _mode,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final mode in BrowserConsoleMode.values)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(
                        mode.label,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                ],
                onChanged: widget.enabled
                    ? (mode) => setState(
                        () => _mode = mode ?? BrowserConsoleMode.evaluate,
                      )
                    : null,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: TextField(
                  controller: _query,
                  enabled: widget.enabled && !_busy,
                  style: theme.textTheme.bodySmall,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: _mode.hint,
                  ),
                  onSubmitted: (_) => _ask(),
                ),
              ),
              IconButton(
                tooltip: 'Ask the page',
                icon: const Icon(
                  AppIcons.paperPlaneRight,
                  size: Chrome.iconAction,
                ),
                onPressed: widget.enabled && !_busy ? _ask : null,
              ),
              // The viewport, not a crop: what the page looks like right now is
              // the question a person is usually holding.
              BrowserViewportShotButton(state: widget.state),
            ],
          ),
        ),
        if (answer != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                0,
                Insets.md,
                Insets.sm,
              ),
              child: SelectableText(
                // §19: a page's answer is true of the instant it was given.
                // The query is repeated because the page has probably moved on.
                '${answer.query}\n${answer.text}\n'
                '— ${describeDriveAge(ref.watch(clockProvider).nowUtc().difference(answer.at))}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                  color: answer.failed
                      ? semantic.attention
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
