import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../../core/paths/app_support_directory.dart';
import '../../explorer/application/agent_states.dart';
import 'overview_board.dart';

/// The Overview tab's two views.
enum OverviewView { board, timeline }

/// Cards with chips, or one line per session.
enum OverviewDensity { cards, lines }

/// A part of a card's "where" line that can be hidden.
enum OverviewCardDetail {
  project('Project'),
  context('Context'),
  machine('Machine');

  const OverviewCardDetail(this.label);

  final String label;
}

/// What this device's Overview shows. Kept per device, like the session
/// lists' switches: one window's picture should not rearrange another's.
class OverviewPrefs {
  const OverviewPrefs({
    this.filter = const OverviewFilter(),
    this.groupBy = OverviewGroupBy.project,
    this.density = OverviewDensity.cards,
    this.view = OverviewView.board,
    this.launchInBackground = true,
    this.subSessions = OverviewSubSessionMode.inside,
    this.pinned = const [],
    this.hiddenDetails = const {},
  });

  /// The parts of a card's "where" line this device hides.
  final Set<OverviewCardDetail> hiddenDetails;

  /// Sessions held at the top of the board, in the order they were pinned;
  /// at most [kOverviewPinLimit].
  final List<String> pinned;

  final OverviewFilter filter;
  final OverviewGroupBy groupBy;
  final OverviewDensity density;
  final OverviewView view;

  /// Whether resuming or starting a session from the command palette, the
  /// dashboard or a session's menu keeps the person where they are: no tab,
  /// focus unmoved, the card peeked or a notice with Open. Settings › General
  /// › Session view. What the New session and Resume… dialogs' "Keep working
  /// here" starts as; a choice made there is for that launch only.
  final bool launchInBackground;

  /// Whether a sub-session is drawn on its parent's card or as a card of its
  /// own after it.
  final OverviewSubSessionMode subSessions;

  OverviewPrefs copyWith({
    OverviewFilter? filter,
    OverviewGroupBy? groupBy,
    OverviewDensity? density,
    OverviewView? view,
    bool? launchInBackground,
    OverviewSubSessionMode? subSessions,
    List<String>? pinned,
    Set<OverviewCardDetail>? hiddenDetails,
  }) => OverviewPrefs(
    filter: filter ?? this.filter,
    groupBy: groupBy ?? this.groupBy,
    density: density ?? this.density,
    view: view ?? this.view,
    launchInBackground: launchInBackground ?? this.launchInBackground,
    subSessions: subSessions ?? this.subSessions,
    pinned: pinned ?? this.pinned,
    hiddenDetails: hiddenDetails ?? this.hiddenDetails,
  );

  Map<String, Object?> toJson() => {
    'projects': ?filter.projects?.toList(),
    'agents': ?filter.agents?.toList(),
    'machines': ?filter.machines?.toList(),
    'columns': ?filter.columns?.map((c) => c.name).toList(),
    'states': ?filter.states?.map((s) => s.name).toList(),
    'groupBy': groupBy.name,
    'density': density.name,
    'view': view.name,
    'launchInBackground': launchInBackground,
    'subSessions': subSessions.name,
    if (pinned.isNotEmpty) 'pinned': pinned,
    if (hiddenDetails.isNotEmpty)
      'hiddenDetails': [for (final detail in hiddenDetails) detail.name],
  };

  static OverviewPrefs fromJson(Object? json) {
    if (json is! Map) return const OverviewPrefs();
    Set<String>? strings(Object? value) =>
        value is List ? {...value.whereType<String>()} : null;
    T named<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    final columns = strings(json['columns']);
    final states = strings(json['states']);
    return OverviewPrefs(
      filter: OverviewFilter(
        projects: strings(json['projects']),
        agents: strings(json['agents']),
        machines: strings(json['machines']),
        columns: columns == null
            ? null
            : {
                for (final column in BoardColumn.values)
                  if (columns.contains(column.name)) column,
              },
        states: states == null
            ? null
            : {
                for (final state in AgentState.values)
                  if (states.contains(state.name)) state,
              },
      ),
      groupBy: named(
        OverviewGroupBy.values,
        json['groupBy'],
        OverviewGroupBy.project,
      ),
      density: named(
        OverviewDensity.values,
        json['density'],
        OverviewDensity.cards,
      ),
      view: named(OverviewView.values, json['view'], OverviewView.board),
      launchInBackground: json['launchInBackground'] != false,
      subSessions: named(
        OverviewSubSessionMode.values,
        json['subSessions'],
        OverviewSubSessionMode.inside,
      ),
      pinned: switch (json['pinned']) {
        final List<Object?> ids => [
          ...ids.whereType<String>().toSet().take(kOverviewPinLimit),
        ],
        _ => const [],
      },
      hiddenDetails: {
        for (final detail in OverviewCardDetail.values)
          if (strings(json['hiddenDetails'])?.contains(detail.name) ?? false)
            detail,
      },
    );
  }
}

/// The most sessions pinned to the top of the board.
const int kOverviewPinLimit = 3;

/// Where [OverviewPrefsController] keeps its file; a test points it at a
/// folder of its own.
final overviewPrefsDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => appSupportDirectory,
);

class OverviewPrefsController extends Notifier<OverviewPrefs> {
  static final _log = AppLogger.named('overview.prefs');
  var _touched = false;

  @override
  OverviewPrefs build() {
    unawaited(_load());
    return const OverviewPrefs();
  }

  Future<File> _file() async => File(
    p.join(
      (await ref.read(overviewPrefsDirectoryProvider)()).path,
      'overview_device.json',
    ),
  );

  Future<void> _load() async {
    try {
      final kept = OverviewPrefs.fromJson(
        jsonDecode(await (await _file()).readAsString()),
      );
      // A choice made while the file was read wins over what it held.
      if (ref.mounted && !_touched) state = kept;
    } on Object {
      // Nothing kept yet, or unreadable: the defaults stand.
    }
  }

  /// Shows or hides [projectId]. [all] is every project there is: picking
  /// the last one back is "all" again, so a project added later shows too.
  void toggleProject(String projectId, {required List<String> all}) =>
      _setFilter(
        projects: toggledIn(state.filter.projects, projectId, all),
        keepProjects: false,
      );

  void showAllProjects() => _setFilter(projects: null, keepProjects: false);

  void setProjects(Set<String>? projects) =>
      _setFilter(projects: projects, keepProjects: false);

  void setAgents(Set<String>? agents) =>
      _setFilter(agents: agents, keepAgents: false);

  void setMachines(Set<String>? machines) =>
      _setFilter(machines: machines, keepMachines: false);

  void setColumns(Set<BoardColumn>? columns) =>
      _setFilter(columns: columns, keepColumns: false, keepStates: false);

  /// Shows only what [counter] counts, or every state for null.
  void setCounter(OverviewCounter? counter) => _setFilter(
    columns: counter == null ? null : {counter.column},
    states: switch (counter?.state) {
      final state? => {state},
      null => null,
    },
    keepColumns: false,
    keepStates: false,
  );

  void setGroupBy(OverviewGroupBy groupBy) {
    if (state.groupBy != groupBy) _set(state.copyWith(groupBy: groupBy));
  }

  void setDensity(OverviewDensity density) {
    if (state.density != density) _set(state.copyWith(density: density));
  }

  void setSubSessions(OverviewSubSessionMode subSessions) {
    if (state.subSessions != subSessions) {
      _set(state.copyWith(subSessions: subSessions));
    }
  }

  void setLaunchInBackground(bool background) {
    if (state.launchInBackground != background) {
      _set(state.copyWith(launchInBackground: background));
    }
  }

  void setView(OverviewView view) {
    if (state.view != view) _set(state.copyWith(view: view));
  }

  /// Shows or hides [detail] on every card.
  void setDetailShown(OverviewCardDetail detail, bool shown) {
    final hidden = {...state.hiddenDetails};
    if (shown ? hidden.remove(detail) : hidden.add(detail)) {
      _set(state.copyWith(hiddenDetails: hidden));
    }
  }

  /// Pins [sessionId], or unpins it; false when the board already holds
  /// [kOverviewPinLimit] and nothing changed.
  bool togglePin(String sessionId) {
    final pinned = [...state.pinned];
    if (!pinned.remove(sessionId)) {
      if (pinned.length >= kOverviewPinLimit) return false;
      pinned.add(sessionId);
    }
    _set(state.copyWith(pinned: pinned));
    return true;
  }

  void _setFilter({
    Set<String>? projects,
    Set<String>? agents,
    Set<String>? machines,
    Set<BoardColumn>? columns,
    Set<AgentState>? states,
    bool keepProjects = true,
    bool keepAgents = true,
    bool keepMachines = true,
    bool keepColumns = true,
    bool keepStates = true,
  }) {
    final now = state.filter;
    _set(
      state.copyWith(
        filter: OverviewFilter(
          projects: keepProjects ? now.projects : projects,
          agents: keepAgents ? now.agents : agents,
          machines: keepMachines ? now.machines : machines,
          columns: keepColumns ? now.columns : columns,
          states: keepStates ? now.states : states,
        ),
      ),
    );
  }

  void _set(OverviewPrefs next) {
    _touched = true;
    state = next;
    unawaited(_write());
  }

  Future<void> _write() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(state.toJson()), flush: true);
    } on Object catch (e) {
      _log.warning('Keeping the Overview choices failed: $e');
    }
  }
}

final overviewPrefsProvider =
    NotifierProvider<OverviewPrefsController, OverviewPrefs>(
      OverviewPrefsController.new,
    );

/// [OverviewPrefs.subSessions], for the boards that only need it.
final overviewSubSessionsProvider = Provider<OverviewSubSessionMode>(
  (ref) => ref.watch(overviewPrefsProvider.select((p) => p.subSessions)),
);

/// [OverviewPrefs.launchInBackground], for the launch paths that only need it.
final launchInBackgroundProvider = Provider<bool>(
  (ref) => ref.watch(overviewPrefsProvider.select((p) => p.launchInBackground)),
);

/// [shown] with [value] flipped, where null is "every one of [all]": picking
/// the last one back returns null, so one added later shows too.
Set<T>? toggledIn<T>(Set<T>? shown, T value, Iterable<T> all) {
  final next = {...shown ?? all};
  if (!next.remove(value)) next.add(value);
  return all.every(next.contains) ? null : next;
}
