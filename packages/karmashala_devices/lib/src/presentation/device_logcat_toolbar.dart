import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/logs.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/device_logcat_session.dart';
import '../application/device_logcat_view.dart';
import '../domain/logcat_entry.dart';
import '../domain/logcat_filter.dart';

/// Below this width (at 1x text) the chips and toggles fold into one menu and
/// the match count moves to the status row — the Flutter console's breakpoint.
const double kLogcatToolbarFoldBelow = 420;

bool logcatToolbarIsWide(BuildContext context, double width) =>
    width >=
    WidthClass.scaleBreakpoint(
      kLogcatToolbarFoldBelow,
      MediaQuery.textScalerOf(context),
    );

String describeLogLevel(LogLevel level) => switch (level) {
  LogLevel.verbose => 'Verbose',
  LogLevel.debug => 'Debug',
  LogLevel.info => 'Info',
  LogLevel.warning => 'Warning',
  LogLevel.error => 'Error',
  LogLevel.fatal => 'Fatal',
};

void _updateQuery(
  WidgetRef ref,
  String serial,
  LogcatQuery Function(LogcatQuery query) change,
) {
  final views = ref.read(deviceLogcatViewsProvider.notifier);
  views.setQuery(serial, change(views.of(serial).query));
}

Set<T> _toggled<T>(Set<T> set, T value) =>
    set.contains(value) ? ({...set}..remove(value)) : {...set, value};

/// Search, filters and the stream's own controls for one device's log.
/// Watches the query and the session's streaming state only, so a new line
/// never rebuilds it; the counts inside watch for themselves.
class DeviceLogcatToolbar extends ConsumerWidget {
  const DeviceLogcatToolbar({
    required this.serial,
    required this.session,
    required this.controller,
    required this.focusNode,
    required this.package,
    required this.onNext,
    required this.onPrevious,
    required this.onEscape,
    super.key,
  });

  final String serial;
  final DeviceLogcatSession session;
  final TextEditingController controller;
  final FocusNode focusNode;
  final TextEditingController package;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onEscape;

  static const searchKey = ValueKey<String>('logcat-search');
  static const packageKey = ValueKey<String>('logcat-package');

  /// Wide enough for `com.example.app` beside the chips, which wrap first.
  static const packageFieldWidth = 200.0;

  @visibleForTesting
  static int debugBuilds = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kDebugMode) debugBuilds++;
    final query = ref.watch(
      deviceLogcatViewProvider(serial).select((view) => view.query),
    );
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = logcatToolbarIsWide(context, box.maxWidth);
        final packageField = TextField(
          key: packageKey,
          controller: package,
          style: theme.textTheme.bodySmall,
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'Package, e.g. com.example.app',
          ),
          // Submit rather than keystroke: pinning to a package respawns
          // `logcat --pid`, so per character is a process per keystroke.
          onSubmitted: session.filterByPackage,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(Insets.sm, 0, Insets.xs, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: LogSearchField(
                      key: searchKey,
                      controller: controller,
                      focusNode: focusNode,
                      hintText: query.regex ? 'Search by pattern' : 'Search',
                      onChanged: (text) => _updateQuery(
                        ref,
                        serial,
                        (q) => q.copyWith(text: text),
                      ),
                      onNext: onNext,
                      onPrevious: onPrevious,
                      onEscape: onEscape,
                    ),
                  ),
                  if (wide) ...[
                    Flexible(child: DeviceLogcatMatchCount(serial: serial)),
                    _Toggle(
                      tooltip: 'Match case',
                      selected: query.caseSensitive,
                      icon: Text('Aa', style: theme.textTheme.labelSmall),
                      onPressed: () => _updateQuery(
                        ref,
                        serial,
                        (q) => q.copyWith(caseSensitive: !q.caseSensitive),
                      ),
                    ),
                    _Toggle(
                      tooltip: 'Use regular expression',
                      selected: query.regex,
                      icon: Text('.*', style: theme.textTheme.labelSmall),
                      onPressed: () => _updateQuery(
                        ref,
                        serial,
                        (q) => q.copyWith(regex: !q.regex),
                      ),
                    ),
                    _Toggle(
                      tooltip: 'Show only matching lines',
                      selected: query.onlyMatching,
                      icon: const Icon(
                        AppIcons.listMagnifyingGlass,
                        size: Chrome.iconAction,
                      ),
                      onPressed: () => _updateQuery(
                        ref,
                        serial,
                        (q) => q.copyWith(onlyMatching: !q.onlyMatching),
                      ),
                    ),
                  ],
                  _StepButtons(
                    serial: serial,
                    onNext: onNext,
                    onPrevious: onPrevious,
                  ),
                  if (!wide) _FilterMenu(serial: serial, query: query),
                  _PauseButton(session: session),
                ],
              ),
              if (wide)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: Insets.xs,
                          runSpacing: Insets.xs,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final level in LogLevel.values)
                              _LevelChip(
                                serial: serial,
                                level: level,
                                selected: query.levels.contains(level),
                              ),
                            _TagMenu(serial: serial, query: query),
                          ],
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      SizedBox(width: packageFieldWidth, child: packageField),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xs),
                  child: packageField,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.tooltip,
    required this.selected,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final bool selected;
  final Widget icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    isSelected: selected,
    visualDensity: VisualDensity.compact,
    icon: icon,
    onPressed: onPressed,
  );
}

/// Pause and play: the tail picks up again, and play/stop in circles were
/// already Launch and Force-stop an app a few rows up.
class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.session});

  final DeviceLogcatSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => IconButton(
      tooltip: session.streaming ? 'Pause logcat' : 'Resume logcat',
      visualDensity: VisualDensity.compact,
      icon: Icon(
        session.streaming ? AppIcons.pause : AppIcons.play,
        size: Chrome.iconAction,
      ),
      onPressed: session.streaming ? session.stop : session.start,
    ),
  );
}

/// "3 of 12" for one device's search.
class DeviceLogcatMatchCount extends ConsumerWidget {
  const DeviceLogcatMatchCount({required this.serial, super.key});

  final String serial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(
      deviceLogcatViewProvider(serial).select((view) => view.currentMatch),
    );
    final (hasQuery, total, current, error) = ref.watch(
      deviceLogcatFilterProvider(serial).select((result) {
        final at = selected == null ? -1 : result.indexOfMatch(selected);
        return (
          result.query.text.isNotEmpty,
          result.matches.length,
          at < 0 ? null : at,
          result.patternError,
        );
      }),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      child: LogMatchCount(
        hasQuery: hasQuery,
        total: total,
        current: current,
        error: error,
      ),
    );
  }
}

class _StepButtons extends ConsumerWidget {
  const _StepButtons({
    required this.serial,
    required this.onNext,
    required this.onPrevious,
  });

  final String serial;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final any = ref.watch(
      deviceLogcatFilterProvider(
        serial,
      ).select((result) => result.matches.isNotEmpty),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Previous match (Shift+Enter)',
          visualDensity: VisualDensity.compact,
          icon: const Icon(AppIcons.caretUp, size: Chrome.iconAction),
          onPressed: any ? onPrevious : null,
        ),
        IconButton(
          tooltip: 'Next match (Enter)',
          visualDensity: VisualDensity.compact,
          icon: const Icon(AppIcons.caretDown, size: Chrome.iconAction),
          onPressed: any ? onNext : null,
        ),
      ],
    );
  }
}

class _LevelChip extends ConsumerWidget {
  const _LevelChip({
    required this.serial,
    required this.level,
    required this.selected,
  });

  final String serial;
  final LogLevel level;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      deviceLogcatFilterProvider(
        serial,
      ).select((result) => result.countOf(level)),
    );
    return LogFilterChip(
      label: level.code,
      count: count,
      selected: selected,
      tooltip: describeLogLevel(level),
      onSelected: (_) => _updateQuery(
        ref,
        serial,
        (q) => q.copyWith(levels: _toggled(q.levels, level)),
      ),
    );
  }
}

/// Seen tags, busiest first, plus chosen ones that have since scrolled out of
/// the tail. A device logs under hundreds of tags; the loud ones are the ones
/// a reader is after.
List<String> _tagNames(LogcatFilterResult result, LogcatQuery query) {
  final counts = result.tagCounts;
  return {...counts.keys, ...query.tags}.toList()..sort((a, b) {
    final byCount = (counts[b] ?? 0).compareTo(counts[a] ?? 0);
    return byCount != 0 ? byCount : a.compareTo(b);
  });
}

/// Tags seen so far, multi-select.
class _TagMenu extends ConsumerWidget {
  const _TagMenu({required this.serial, required this.query});

  final String serial;
  final LogcatQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final any = ref.watch(
      deviceLogcatFilterProvider(
        serial,
      ).select((result) => result.tagCounts.isNotEmpty),
    );
    if (!any && query.tags.isEmpty) return const SizedBox.shrink();
    final chosen = query.tags.length;
    return PopupMenuButton<String?>(
      tooltip: 'Filter by tag',
      itemBuilder: (context) {
        final result = ref.read(deviceLogcatFilterProvider(serial));
        return [
          DesktopMenuItem<String?>(
            value: null,
            label: 'All tags',
            icon: AppIcons.circle,
            selected: query.tags.isEmpty,
          ),
          for (final tag in _tagNames(result, query))
            DesktopMenuItem<String?>(
              value: tag,
              label: '$tag ${result.tagCounts[tag] ?? 0}',
              icon: AppIcons.circle,
              selected: query.tags.contains(tag),
            ),
        ];
      },
      onSelected: (tag) => _pickTag(ref, serial, tag),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              chosen == 0 ? 'All tags' : 'Tags: $chosen',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const Icon(AppIcons.caretDown, size: Chrome.iconSmall),
          ],
        ),
      ),
    );
  }
}

void _pickTag(WidgetRef ref, String serial, String? tag) => _updateQuery(
  ref,
  serial,
  (q) => q.copyWith(tags: tag == null ? const {} : _toggled(q.tags, tag)),
);

sealed class _MenuChoice {
  const _MenuChoice();
}

class _LevelChoice extends _MenuChoice {
  const _LevelChoice(this.level);
  final LogLevel level;
}

class _TagChoice extends _MenuChoice {
  const _TagChoice(this.tag);
  final String? tag;
}

enum _Option { matchCase, regex, onlyMatching }

class _OptionChoice extends _MenuChoice {
  const _OptionChoice(this.option);
  final _Option option;
}

/// Everything the wide toolbar spreads out, in one menu for a narrow panel.
/// The glyph fills while anything is on, so a folded filter is not a hidden one.
class _FilterMenu extends ConsumerWidget {
  const _FilterMenu({required this.serial, required this.query});

  final String serial;
  final LogcatQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anyOn =
        query.isFiltered ||
        query.regex ||
        query.caseSensitive ||
        query.onlyMatching;
    return PopupMenuButton<_MenuChoice>(
      tooltip: 'Filters and search options',
      icon: Icon(
        anyOn ? AppIcons.funnelFill : AppIcons.funnel,
        size: Chrome.iconAction,
      ),
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
      itemBuilder: (context) {
        final result = ref.read(deviceLogcatFilterProvider(serial));
        return [
          for (final level in LogLevel.values)
            DesktopMenuItem<_MenuChoice>(
              value: _LevelChoice(level),
              label:
                  '${level.code} ${describeLogLevel(level)} '
                  '${result.countOf(level)}',
              icon: AppIcons.circle,
              selected: query.levels.contains(level),
            ),
          if (result.tagCounts.isNotEmpty || query.tags.isNotEmpty) ...[
            const PopupMenuDivider(),
            DesktopMenuItem<_MenuChoice>(
              value: const _TagChoice(null),
              label: 'All tags',
              icon: AppIcons.circle,
              selected: query.tags.isEmpty,
            ),
            for (final tag in _tagNames(result, query))
              DesktopMenuItem<_MenuChoice>(
                value: _TagChoice(tag),
                label: '$tag ${result.tagCounts[tag] ?? 0}',
                icon: AppIcons.circle,
                selected: query.tags.contains(tag),
              ),
          ],
          const PopupMenuDivider(),
          DesktopMenuItem<_MenuChoice>(
            value: const _OptionChoice(_Option.matchCase),
            label: 'Match case',
            icon: AppIcons.circle,
            selected: query.caseSensitive,
          ),
          DesktopMenuItem<_MenuChoice>(
            value: const _OptionChoice(_Option.regex),
            label: 'Use regular expression',
            icon: AppIcons.circle,
            selected: query.regex,
          ),
          DesktopMenuItem<_MenuChoice>(
            value: const _OptionChoice(_Option.onlyMatching),
            label: 'Show only matching lines',
            icon: AppIcons.circle,
            selected: query.onlyMatching,
          ),
        ];
      },
      onSelected: (choice) => switch (choice) {
        _LevelChoice(:final level) => _updateQuery(
          ref,
          serial,
          (q) => q.copyWith(levels: _toggled(q.levels, level)),
        ),
        _TagChoice(:final tag) => _pickTag(ref, serial, tag),
        _OptionChoice(:final option) => _updateQuery(
          ref,
          serial,
          (q) => switch (option) {
            _Option.matchCase => q.copyWith(caseSensitive: !q.caseSensitive),
            _Option.regex => q.copyWith(regex: !q.regex),
            _Option.onlyMatching => q.copyWith(onlyMatching: !q.onlyMatching),
          },
        ),
      },
    );
  }
}
