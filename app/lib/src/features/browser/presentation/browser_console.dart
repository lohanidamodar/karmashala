import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_devices/devices.dart' show describeDriveAge;
import '../application/browser_pane_controller.dart';
import '../application/browser_providers.dart';
import 'package:karmashala_browser/browser.dart' show FindResult;
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

/// A console for the attached page, over the same [BrowserService] the tools
/// call. Not behind the evaluate gate: the person is typing it themselves.
class BrowserConsole extends ConsumerStatefulWidget {
  const BrowserConsole({required this.state, super.key});

  final BrowserPaneState state;

  /// Whether there is a page to ask. False disables the field rather than
  /// hiding it: a control that vanishes reads as a fault.
  bool get enabled => state.status == BrowserPaneStatus.connected;

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
    final service = ref.read(browserServiceProvider);
    String text;
    var failed = false;
    try {
      text = switch (_mode) {
        BrowserConsoleMode.evaluate => _renderValue(
          await service.evaluate(query),
        ),
        BrowserConsoleMode.selector => _renderMatches(
          await service.findElements(selector: query, limit: shownMatches),
        ),
        BrowserConsoleMode.text => _renderMatches(
          await service.findElements(text: query, limit: shownMatches),
        ),
      };
    } on Object catch (error) {
      // The service's own refusal, unwrapped: `BrowserException` carries the
      // sentence the taxonomy wrote, which is better than anything here.
      text = '$error';
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

  static String _renderValue(Object? value) =>
      value == null ? 'null' : '$value';

  static String _renderMatches(FindResult found) {
    if (found.elements.isEmpty) {
      // Never an empty list: "nothing matched" and "everything that matched is
      // hidden" are different answers about the page.
      return found.hidden > 0
          ? 'No visible match for ${found.query} — ${found.hidden} matched and '
                'were hidden.'
          : 'No match for ${found.query}.';
    }
    final listing = found.indexedListing(max: shownMatches);
    final notShown = found.total - found.elements.length;
    return [
      '${found.total} match${found.total == 1 ? '' : 'es'} for ${found.query}',
      listing,
      if (notShown > 0) '… $notShown more not listed',
      if (found.hidden > 0) '${found.hidden} hidden match(es) not counted here',
    ].join('\n');
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
