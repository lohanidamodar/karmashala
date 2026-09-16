import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/logs.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/flutter_console_view.dart';

/// Below this width (at 1x text) the chips and toggles fold into one menu and
/// the match count moves to the status row.
const double kConsoleToolbarFoldBelow = 420;

bool consoleToolbarIsWide(BuildContext context, double width) =>
    width >=
    WidthClass.scaleBreakpoint(
      kConsoleToolbarFoldBelow,
      MediaQuery.textScalerOf(context),
    );

String describeChannel(AppLogChannel channel) => switch (channel) {
  AppLogChannel.output => 'Output',
  AppLogChannel.errors => 'Errors',
  AppLogChannel.logs => 'Logs',
  AppLogChannel.lifecycle => 'Lifecycle',
};

String _channelTooltip(AppLogChannel channel) => switch (channel) {
  AppLogChannel.output => 'print and stdout',
  AppLogChannel.errors => 'stderr and framework errors',
  AppLogChannel.logs => 'dart:developer log() records',
  AppLogChannel.lifecycle => 'Attach and detach notes from Karmashala',
};

String describeLogger(String name) => name.isEmpty ? '(unnamed)' : name;

void _updateQuery(
  WidgetRef ref,
  String appId,
  AppLogQuery Function(AppLogQuery query) change,
) {
  final views = ref.read(flutterConsoleViewsProvider.notifier);
  views.setQuery(appId, change(views.of(appId).query));
}

Set<T> _toggled<T>(Set<T> set, T value) =>
    set.contains(value) ? ({...set}..remove(value)) : {...set, value};

/// Search and filters for one app's console. Watches the query only, so a new
/// console line never rebuilds it; the counts inside watch for themselves.
class FlutterConsoleToolbar extends ConsumerWidget {
  const FlutterConsoleToolbar({
    required this.appId,
    required this.controller,
    required this.focusNode,
    required this.onNext,
    required this.onPrevious,
    required this.onEscape,
    super.key,
  });

  final String appId;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onEscape;

  @visibleForTesting
  static int debugBuilds = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kDebugMode) debugBuilds++;
    final query = ref.watch(
      flutterConsoleViewProvider(appId).select((view) => view.query),
    );
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = consoleToolbarIsWide(context, box.maxWidth);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: LogSearchField(
                      controller: controller,
                      focusNode: focusNode,
                      hintText: query.regex ? 'Search by pattern' : 'Search',
                      onChanged: (text) => _updateQuery(
                        ref,
                        appId,
                        (q) => q.copyWith(text: text),
                      ),
                      onNext: onNext,
                      onPrevious: onPrevious,
                      onEscape: onEscape,
                    ),
                  ),
                  if (wide) ...[
                    Flexible(child: FlutterConsoleMatchCount(appId: appId)),
                    _Toggle(
                      tooltip: 'Match case',
                      selected: query.caseSensitive,
                      icon: Text('Aa', style: theme.textTheme.labelSmall),
                      onPressed: () => _updateQuery(
                        ref,
                        appId,
                        (q) => q.copyWith(caseSensitive: !q.caseSensitive),
                      ),
                    ),
                    _Toggle(
                      tooltip: 'Use regular expression',
                      selected: query.regex,
                      icon: Text('.*', style: theme.textTheme.labelSmall),
                      onPressed: () => _updateQuery(
                        ref,
                        appId,
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
                        appId,
                        (q) => q.copyWith(onlyMatching: !q.onlyMatching),
                      ),
                    ),
                  ],
                  _StepButtons(
                    appId: appId,
                    onNext: onNext,
                    onPrevious: onPrevious,
                  ),
                  if (!wide) _FilterMenu(appId: appId, query: query),
                ],
              ),
              if (wide)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xs),
                  child: Wrap(
                    spacing: Insets.xs,
                    runSpacing: Insets.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final channel in AppLogChannel.values)
                        _ChannelChip(
                          appId: appId,
                          channel: channel,
                          selected: query.channels.contains(channel),
                        ),
                      _LoggerMenu(appId: appId, query: query),
                    ],
                  ),
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

/// "3 of 12" for the selected app's search.
class FlutterConsoleMatchCount extends ConsumerWidget {
  const FlutterConsoleMatchCount({required this.appId, super.key});

  final String appId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(
      flutterConsoleViewProvider(appId).select((view) => view.currentMatch),
    );
    final (hasQuery, total, current, error) = ref.watch(
      flutterConsoleFilterProvider(appId).select((result) {
        if (result == null) return (false, 0, null, null);
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
    required this.appId,
    required this.onNext,
    required this.onPrevious,
  });

  final String appId;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final any = ref.watch(
      flutterConsoleFilterProvider(
        appId,
      ).select((result) => result != null && result.matches.isNotEmpty),
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

class _ChannelChip extends ConsumerWidget {
  const _ChannelChip({
    required this.appId,
    required this.channel,
    required this.selected,
  });

  final String appId;
  final AppLogChannel channel;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      flutterConsoleFilterProvider(
        appId,
      ).select((result) => result?.countOf(channel) ?? 0),
    );
    return LogFilterChip(
      label: describeChannel(channel),
      count: count,
      selected: selected,
      tooltip: _channelTooltip(channel),
      onSelected: (_) => _updateQuery(
        ref,
        appId,
        (q) => q.copyWith(channels: _toggled(q.channels, channel)),
      ),
    );
  }
}

/// Developer-log logger names seen so far, multi-select.
class _LoggerMenu extends ConsumerWidget {
  const _LoggerMenu({required this.appId, required this.query});

  final String appId;
  final AppLogQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final any = ref.watch(
      flutterConsoleFilterProvider(
        appId,
      ).select((result) => result?.loggerCounts.isNotEmpty ?? false),
    );
    if (!any && query.loggerNames.isEmpty) return const SizedBox.shrink();
    final chosen = query.loggerNames.length;
    return PopupMenuButton<String?>(
      tooltip: 'Filter developer logs by logger',
      itemBuilder: (context) => _loggerItems(ref, appId, query),
      onSelected: (name) => _pickLogger(ref, appId, name),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              chosen == 0 ? 'All loggers' : 'Loggers: $chosen',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const Icon(AppIcons.caretDown, size: Chrome.iconSmall),
          ],
        ),
      ),
    );
  }
}

/// Seen names plus chosen ones that have since scrolled out of the buffer.
List<String> _loggerNames(AppLogFilterResult result, AppLogQuery query) =>
    {...result.loggerCounts.keys, ...query.loggerNames}.toList()..sort();

/// `null` is "all loggers".
List<PopupMenuEntry<String?>> _loggerItems(
  WidgetRef ref,
  String appId,
  AppLogQuery query,
) {
  final result = ref.read(flutterConsoleFilterProvider(appId));
  final counts = result?.loggerCounts ?? const <String, int>{};
  final names = result == null
      ? (query.loggerNames.toList()..sort())
      : _loggerNames(result, query);
  return [
    DesktopMenuItem<String?>(
      value: null,
      label: 'All loggers',
      icon: AppIcons.circle,
      selected: query.loggerNames.isEmpty,
    ),
    for (final name in names)
      DesktopMenuItem<String?>(
        value: name,
        label: '${describeLogger(name)} ${counts[name] ?? 0}',
        icon: AppIcons.circle,
        selected: query.loggerNames.contains(name),
      ),
  ];
}

void _pickLogger(WidgetRef ref, String appId, String? name) => _updateQuery(
  ref,
  appId,
  (q) => q.copyWith(
    loggerNames: name == null ? const {} : _toggled(q.loggerNames, name),
  ),
);

sealed class _MenuChoice {
  const _MenuChoice();
}

class _ChannelChoice extends _MenuChoice {
  const _ChannelChoice(this.channel);
  final AppLogChannel channel;
}

class _LoggerChoice extends _MenuChoice {
  const _LoggerChoice(this.name);
  final String? name;
}

enum _Option { matchCase, regex, onlyMatching }

class _OptionChoice extends _MenuChoice {
  const _OptionChoice(this.option);
  final _Option option;
}

/// Everything the wide toolbar spreads out, in one menu for a narrow panel.
/// The glyph fills while anything is on, so a folded filter is not a hidden one.
class _FilterMenu extends ConsumerWidget {
  const _FilterMenu({required this.appId, required this.query});

  final String appId;
  final AppLogQuery query;

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
        final result = ref.read(flutterConsoleFilterProvider(appId));
        return [
          for (final channel in AppLogChannel.values)
            DesktopMenuItem<_MenuChoice>(
              value: _ChannelChoice(channel),
              label:
                  '${describeChannel(channel)} ${result?.countOf(channel) ?? 0}',
              icon: AppIcons.circle,
              selected: query.channels.contains(channel),
            ),
          if (result?.loggerCounts.isNotEmpty ?? false) ...[
            const PopupMenuDivider(),
            DesktopMenuItem<_MenuChoice>(
              value: const _LoggerChoice(null),
              label: 'All loggers',
              icon: AppIcons.circle,
              selected: query.loggerNames.isEmpty,
            ),
            for (final name in _loggerNames(result!, query))
              DesktopMenuItem<_MenuChoice>(
                value: _LoggerChoice(name),
                label:
                    '${describeLogger(name)} ${result.loggerCounts[name] ?? 0}',
                icon: AppIcons.circle,
                selected: query.loggerNames.contains(name),
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
        _ChannelChoice(:final channel) => _updateQuery(
          ref,
          appId,
          (q) => q.copyWith(channels: _toggled(q.channels, channel)),
        ),
        _LoggerChoice(:final name) => _pickLogger(ref, appId, name),
        _OptionChoice(:final option) => _updateQuery(
          ref,
          appId,
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
