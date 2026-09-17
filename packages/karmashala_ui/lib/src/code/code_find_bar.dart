import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import '../desktop_menu.dart';
import '../log_filter_controls.dart';
import 'code_find_controller.dart';
import 'code_shortcut_labels.dart';

/// The editor's find and replace strip, drawn in `re_editor`'s find slot.
///
/// Stateless over [AppCodeFindController]: the editor rebuilds this whenever
/// the find value changes, and the query outlives the strip being closed.
class CodeFindBar extends StatelessWidget implements PreferredSizeWidget {
  const CodeFindBar({
    required this.controller,
    required this.readOnly,
    required this.rowHeight,
    super.key,
  });

  final AppCodeFindController controller;
  final bool readOnly;

  /// One row's height at the ambient text scale; see [rowHeightOf].
  final double rowHeight;

  static double rowHeightOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(Chrome.control) + Insets.xs;

  /// Below this width (at 1x text) the three toggles fold into one menu, so
  /// Previous, Next and Close stay on the strip in a narrow pane.
  static const double foldTogglesBelow = 400;

  bool get _replaceShown => controller.replaceShown && !readOnly;

  @override
  Size get preferredSize => Size(
    double.infinity,
    !controller.isOpen
        ? 0
        : (_replaceShown ? rowHeight * 2 : rowHeight) + Insets.xs,
  );

  @override
  Widget build(BuildContext context) {
    if (!controller.isOpen) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: preferredSize.height,
      child: Material(
        color: theme.colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.only(
            left: Insets.xs,
            right: Insets.xs,
            bottom: Insets.xs,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow =
                  constraints.maxWidth <
                  WidthClass.scaleBreakpoint(foldTogglesBelow, scaler);
              return Column(
                children: [
                  SizedBox(height: rowHeight, child: _findRow(context, narrow)),
                  if (_replaceShown)
                    SizedBox(height: rowHeight, child: _replaceRow(context)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _findRow(BuildContext context, bool narrow) {
    final c = controller;
    final query = c.findInputController.text;
    final hasMatches = c.matchCount > 0;
    return Row(
      children: [
        if (!readOnly)
          _button(
            tooltip: c.replaceShown ? 'Hide replace' : 'Show replace',
            icon: c.replaceShown ? AppIcons.caretDown : AppIcons.caretRight,
            onPressed: c.toggleMode,
          ),
        Expanded(
          child: LogSearchField(
            controller: c.findInputController,
            focusNode: c.findInputFocusNode,
            hintText: 'Find',
            onChanged: _ignore,
            onNext: c.nextMatch,
            onPrevious: c.previousMatch,
            onEscape: c.close,
          ),
        ),
        Flexible(
          child: LogMatchCount(
            hasQuery:
                query.isNotEmpty && (!c.isSearching || c.patternError != null),
            total: c.matchCount,
            current: c.currentIndex,
            error: c.patternError,
          ),
        ),
        const SizedBox(width: Insets.xs),
        if (narrow)
          _OptionsButton(controller: c)
        else ...[
          _toggle(
            context,
            label: 'Aa',
            tooltip: 'Match case (${CodeShortcutLabels.matchCase})',
            on: c.caseSensitive,
            onPressed: c.toggleCaseSensitive,
          ),
          _toggle(
            context,
            label: 'ab',
            underline: true,
            tooltip: 'Match whole word (${CodeShortcutLabels.wholeWord})',
            on: c.wholeWord,
            onPressed: c.toggleWholeWord,
          ),
          _toggle(
            context,
            label: '.*',
            tooltip: 'Use regular expression (${CodeShortcutLabels.regex})',
            on: c.regex,
            onPressed: c.toggleRegex,
          ),
        ],
        _button(
          tooltip: 'Previous match (${CodeShortcutLabels.findPrevious})',
          icon: AppIcons.arrowUp,
          onPressed: hasMatches ? c.previousMatch : null,
        ),
        _button(
          tooltip: 'Next match (${CodeShortcutLabels.findNext})',
          icon: AppIcons.arrowDown,
          onPressed: hasMatches ? c.nextMatch : null,
        ),
        _button(tooltip: 'Close (Esc)', icon: AppIcons.x, onPressed: c.close),
      ],
    );
  }

  Widget _replaceRow(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    final hasMatches = c.matchCount > 0;
    return Row(
      children: [
        // Lines the replace field up under the find field.
        const SizedBox(width: Chrome.control),
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter): c.replaceMatch,
              const SingleActivator(LogicalKeyboardKey.numpadEnter):
                  c.replaceMatch,
              const SingleActivator(
                LogicalKeyboardKey.enter,
                control: true,
                alt: true,
              ): c.replaceAllMatches,
              const SingleActivator(
                LogicalKeyboardKey.enter,
                meta: true,
                alt: true,
              ): c.replaceAllMatches,
              const SingleActivator(LogicalKeyboardKey.escape): c.close,
            },
            child: TextField(
              controller: c.replaceInputController,
              focusNode: c.replaceInputFocusNode,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Replace',
                prefixIcon: Icon(
                  AppIcons.arrowBendDownRight,
                  size: Chrome.iconAction,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: Chrome.icon + Insets.sm,
                ),
              ),
            ),
          ),
        ),
        _button(
          tooltip: 'Replace (Enter)',
          icon: AppIcons.check,
          onPressed: hasMatches ? c.replaceMatch : null,
        ),
        _button(
          tooltip: 'Replace all (${CodeShortcutLabels.replaceAll})',
          icon: AppIcons.listChecks,
          onPressed: hasMatches ? c.replaceAllMatches : null,
        ),
      ],
    );
  }

  static void _ignore(String _) {}

  Widget _button({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => IconButton(
    tooltip: tooltip,
    iconSize: Chrome.iconAction,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(
      width: Chrome.control,
      height: Chrome.control,
    ),
    icon: Icon(icon),
    onPressed: onPressed,
  );

  Widget _toggle(
    BuildContext context, {
    required String label,
    required String tooltip,
    required bool on,
    required VoidCallback onPressed,
    bool underline = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: on,
        label: tooltip,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Container(
            width: Chrome.control,
            height: Chrome.control,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? StateLayers.selected(scheme) : null,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: on ? scheme.primary : scheme.onSurfaceVariant,
                decoration: underline ? TextDecoration.underline : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _FindOption { matchCase, wholeWord, regex }

/// The three toggles as one menu, for a strip too narrow to show them. The
/// glyph takes the accent while any is on, so a folded option is not hidden.
class _OptionsButton extends StatelessWidget {
  const _OptionsButton({required this.controller});

  final AppCodeFindController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final anyOn = c.caseSensitive || c.wholeWord || c.regex;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: 'Find options',
      iconSize: Chrome.iconAction,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(
        width: Chrome.control,
        height: Chrome.control,
      ),
      icon: Icon(
        AppIcons.funnel,
        color: anyOn ? scheme.primary : scheme.onSurfaceVariant,
      ),
      onPressed: () async {
        final picked = await showDesktopMenuUnder<_FindOption>(context, [
          DesktopMenuItem(
            value: _FindOption.matchCase,
            label: 'Match case',
            icon: AppIcons.circle,
            selected: c.caseSensitive,
            shortcut: CodeShortcutLabels.matchCase,
          ),
          DesktopMenuItem(
            value: _FindOption.wholeWord,
            label: 'Match whole word',
            icon: AppIcons.circle,
            selected: c.wholeWord,
            shortcut: CodeShortcutLabels.wholeWord,
          ),
          DesktopMenuItem(
            value: _FindOption.regex,
            label: 'Use regular expression',
            icon: AppIcons.circle,
            selected: c.regex,
            shortcut: CodeShortcutLabels.regex,
          ),
        ]);
        switch (picked) {
          case _FindOption.matchCase:
            c.toggleCaseSensitive();
          case _FindOption.wholeWord:
            c.toggleWholeWord();
          case _FindOption.regex:
            c.toggleRegex();
          case null:
            break;
        }
      },
    );
  }
}
