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

/// What this device's Overview shows. Kept per device, like the session
/// lists' switches: one window's picture should not rearrange another's.
class OverviewPrefs {
  const OverviewPrefs({
    this.filter = const OverviewFilter(),
    this.groupBy = OverviewGroupBy.project,
    this.density = OverviewDensity.cards,
    this.view = OverviewView.board,
    this.newSessionKeepsHere = true,
    this.resumeKeepsHere = true,
  });

  final OverviewFilter filter;
  final OverviewGroupBy groupBy;
  final OverviewDensity density;
  final OverviewView view;

  /// Whether New session from here starts ticked to keep working here.
  final bool newSessionKeepsHere;

  /// Whether Resume… from here starts ticked to keep working here.
  final bool resumeKeepsHere;

  OverviewPrefs copyWith({
    OverviewFilter? filter,
    OverviewGroupBy? groupBy,
    OverviewDensity? density,
    OverviewView? view,
    bool? newSessionKeepsHere,
    bool? resumeKeepsHere,
  }) => OverviewPrefs(
    filter: filter ?? this.filter,
    groupBy: groupBy ?? this.groupBy,
    density: density ?? this.density,
    view: view ?? this.view,
    newSessionKeepsHere: newSessionKeepsHere ?? this.newSessionKeepsHere,
    resumeKeepsHere: resumeKeepsHere ?? this.resumeKeepsHere,
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
    'newSessionKeepsHere': newSessionKeepsHere,
    'resumeKeepsHere': resumeKeepsHere,
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
      newSessionKeepsHere: json['newSessionKeepsHere'] != false,
      resumeKeepsHere: json['resumeKeepsHere'] != false,
    );
  }
}

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

  void setNewSessionKeepsHere(bool keeps) {
    if (state.newSessionKeepsHere != keeps) {
      _set(state.copyWith(newSessionKeepsHere: keeps));
    }
  }

  void setResumeKeepsHere(bool keeps) {
    if (state.resumeKeepsHere != keeps) {
      _set(state.copyWith(resumeKeepsHere: keeps));
    }
  }

  void setView(OverviewView view) {
    if (state.view != view) _set(state.copyWith(view: view));
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

/// [shown] with [value] flipped, where null is "every one of [all]": picking
/// the last one back returns null, so one added later shows too.
Set<T>? toggledIn<T>(Set<T>? shown, T value, Iterable<T> all) {
  final next = {...shown ?? all};
  if (!next.remove(value)) next.add(value);
  return all.every(next.contains) ? null : next;
}
