import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';

import 'server_tool_context.dart';

/// What an agent running over ACP last announced for a session: its modes
/// and its config options, either null until it has said.
typedef AcpAnnounced = ({
  SessionModesChanged? modes,
  SessionConfigOptionsChanged? options,
});

/// **`session_settings` and `session_configure`**: a session's model,
/// thinking level, mode and other agent settings, read and changed through
/// the same changers the session bar's requests land on
/// (`DataService.sessionModes`, `DataService.sessionModels`). What the agent
/// has not announced is "not recorded", never guessed.
class SessionSettingsTools {
  SessionSettingsTools(
    this._context, {
    required this.rowOf,
    required this.agentOf,
    required this.acpOf,
    required this.runsHere,
  });

  /// Whether this server itself runs the session's agent now.
  final bool Function(String sessionId) runsHere;

  final ServerToolContext _context;
  final Session? Function(String sessionId) rowOf;

  /// The agent the session runs, or null when nothing names it.
  final AgentDescriptor? Function(String sessionId) agentOf;

  /// What its ACP agent announced, or null when no ACP agent runs it here.
  final AcpAnnounced? Function(String sessionId) acpOf;

  static const _notRecorded = 'not recorded';

  Session _row(String id) =>
      rowOf(id) ?? (throw StateError('No session with id $id.'));

  /// The session's settings as they stand.
  Map<String, Object?> settings(String sessionId) {
    final row = _row(sessionId);
    final agent = agentOf(sessionId);
    final acp = acpOf(sessionId);
    final options = acp?.options?.options ?? const <SessionConfigOption>[];
    final modelOption = _modelOption(options);
    final thinking = _thinkingOption(options);
    final modes = acp?.modes;
    final support = agent?.launch.model;
    return <String, Object?>{
      'sessionId': sessionId,
      'title': row.title,
      'agent': agent == null
          ? _notRecorded
          : <String, Object?>{'id': agent.id, 'name': agent.displayName},
      'runsOver': acp != null
          ? 'acp'
          : runsHere(sessionId)
          ? 'terminal'
          : 'not running here',
      'model': <String, Object?>{
        'chosen': row.modelId ?? "none chosen: the agent's default",
        'running': _context.modelOf(sessionId),
        if (modelOption != null) ...{
          'optionId': modelOption.id,
          'current': modelOption.currentValue ?? _notRecorded,
          'choices': _choices(modelOption),
        } else if (support != null && support.isSupported) ...{
          'choices': [
            for (final model in support.models)
              <String, Object?>{'value': model.id, 'name': model.label},
          ],
          'switchesLive': support.switchesLive,
        } else
          'settable': false,
      },
      'thinking': thinking == null
          ? acp == null
                ? _notAcp
                : 'not settable: the agent announces no thinking level'
          : <String, Object?>{
              'optionId': thinking.id,
              'current': thinking.currentValue ?? _notRecorded,
              'choices': _choices(thinking),
            },
      'mode': _modeSettings(acp, modes, _modeOption(options)),
      'options': acp == null
          ? _notAcp
          : acp.options == null
          ? _notRecorded
          : [
              for (final option in options)
                <String, Object?>{
                  'id': option.id,
                  'name': option.name,
                  'kind': _kindOf(option),
                  'type': option.type,
                  'current': option.currentValue ?? _notRecorded,
                  if (option.isSelect) 'choices': _choices(option),
                },
            ],
    };
  }

  static Object _modeSettings(
    AcpAnnounced? acp,
    SessionModesChanged? modes,
    SessionConfigOption? option,
  ) {
    if (modes != null && modes.availableModes.isNotEmpty) {
      return <String, Object?>{
        'current': modes.currentModeId ?? _notRecorded,
        'choices': [
          for (final mode in modes.availableModes)
            <String, Object?>{'value': mode.id, 'name': mode.name},
        ],
      };
    }
    if (option != null) {
      return <String, Object?>{
        'optionId': option.id,
        'current': option.currentValue ?? _notRecorded,
        'choices': _choices(option),
      };
    }
    return acp == null ? _notAcp : 'not settable: the agent announces no modes';
  }

  static const _notAcp =
      'not settable: only an agent running over ACP announces a thinking '
      'level, modes and options, and none runs this session here now';

  /// Applies what [arguments] asks of [sessionId], each through its changer.
  /// Every requested change is checked first: one that cannot be made
  /// refuses the call with nothing changed.
  Future<Map<String, Object?>> configure(
    String sessionId,
    Map<String, dynamic> arguments,
  ) async {
    final row = _row(sessionId);
    final model = _string(arguments, 'model');
    final thinking = _string(arguments, 'thinking');
    final mode = _string(arguments, 'mode');
    final rawOptions = arguments['options'];
    if (rawOptions != null && rawOptions is! Map) {
      throw ArgumentError(
        'options must be an object of option id to value, not $rawOptions.',
      );
    }
    final asked = <String, Object?>{
      for (final entry in ((rawOptions as Map?) ?? const {}).entries)
        '${entry.key}': entry.value,
    };
    if (model == null && thinking == null && mode == null && asked.isEmpty) {
      throw ArgumentError(
        'Nothing to change: give model, thinking, mode or options. '
        'session_settings lists what this session offers.',
      );
    }
    final acp = acpOf(sessionId);
    final options = acp?.options?.options ?? const <SessionConfigOption>[];
    final problems = <String>[];
    final changes = <_Change>[];

    if (model != null) {
      final option = acp == null ? null : _modelOption(options);
      if (option != null) {
        final value = _choose(option, model, problems, 'model');
        if (value != null) {
          changes.add(_option(sessionId, 'model', option.id, value));
        }
      } else {
        final support = agentOf(sessionId)?.launch.model;
        final models = _context.data.sessionModels;
        if (models == null) {
          problems.add(
            'model: this server moves no session onto another model.',
          );
        } else if (acp == null && (support == null || !support.isSupported)) {
          problems.add('model: this agent offers no way to choose its model.');
        } else if (acp == null &&
            support!.models.isNotEmpty &&
            support.modelFor(model) == null) {
          problems.add(
            'model: "$model" is not one this agent offers; choose one of '
            '${support.models.map((m) => '"${m.id}"').join(', ')}.',
          );
        } else {
          final id = support?.modelFor(model)?.id ?? model;
          changes.add(
            _Change('model', id, () async {
              final set = await models.setModel(sessionId, id);
              return switch (set.outcome) {
                SessionModelOutcome.now => _applied(
                  set.line == null ? null : 'typed "${set.line}"',
                ),
                SessionModelOutcome.afterTurn => <String, Object?>{
                  'result': 'held',
                  'note':
                      'It is mid-turn; the switch is sent the moment that '
                      'turn ends.',
                },
                SessionModelOutcome.pickerOpened => <String, Object?>{
                  'result': 'pickerOpened',
                  'note':
                      "This agent's own model picker was opened in its "
                      'terminal; the person chooses there.',
                },
                SessionModelOutcome.recorded => <String, Object?>{
                  'result': 'recorded',
                  'note':
                      'Recorded on the session; it takes effect at its next '
                      'launch. The running agent, if any, is unchanged.',
                },
              };
            }),
          );
        }
      }
    }

    if (thinking != null) {
      final option = _thinkingOption(options);
      if (acp == null) {
        problems.add('thinking: $_notAcp.');
      } else if (option == null) {
        problems.add('thinking: the agent announces no thinking level.');
      } else {
        final value = _choose(option, thinking, problems, 'thinking');
        if (value != null) {
          changes.add(_option(sessionId, 'thinking', option.id, value));
        }
      }
    }

    if (mode != null) {
      final modes = acp?.modes?.availableModes ?? const <SessionModeOption>[];
      final option = _modeOption(options);
      if (acp == null) {
        problems.add('mode: $_notAcp.');
      } else if (modes.isNotEmpty) {
        final chosen =
            modes.where((m) => m.id == mode).firstOrNull ??
            _unique(
              modes.where((m) => _same(m.id, mode) || _same(m.name, mode)),
            );
        if (chosen == null) {
          problems.add(
            'mode: "$mode" is not one this agent offers; choose one of '
            '${modes.map((m) => '"${m.id}" (${m.name})').join(', ')}.',
          );
        } else {
          changes.add(
            _Change('mode', chosen.id, () async {
              await _context.data.sessionModes.setMode(sessionId, chosen.id);
              return _applied(null);
            }),
          );
        }
      } else if (option != null) {
        final value = _choose(option, mode, problems, 'mode');
        if (value != null) {
          changes.add(_option(sessionId, 'mode', option.id, value));
        }
      } else {
        problems.add('mode: the agent announces no modes.');
      }
    }

    for (final MapEntry(key: id, :value) in asked.entries) {
      final option = options.where((o) => o.id == id).firstOrNull;
      if (acp == null) {
        problems.add('options.$id: $_notAcp.');
      } else if (option == null) {
        problems.add(
          'options.$id: the agent exposes no option "$id"; it exposes '
          '${options.isEmpty ? 'none' : options.map((o) => '"${o.id}"').join(', ')}.',
        );
      } else if (option.isBoolean) {
        if (value is bool) {
          changes.add(_option(sessionId, 'options.$id', id, value));
        } else {
          problems.add('options.$id: "${option.name}" takes true or false.');
        }
      } else if (option.isSelect) {
        if (value is String) {
          final chosen = _choose(option, value, problems, 'options.$id');
          if (chosen != null) {
            changes.add(_option(sessionId, 'options.$id', id, chosen));
          }
        } else {
          problems.add('options.$id: "${option.name}" takes a choice value.');
        }
      } else {
        problems.add(
          'options.$id: "${option.name}" is a ${option.type} option, which '
          'Karmashala does not set.',
        );
      }
    }

    if (problems.isNotEmpty) {
      throw ArgumentError(
        'Nothing was changed. ${problems.join(' ')} session_settings lists '
        'what this session offers.',
      );
    }

    final results = <Object?>[];
    for (final change in changes) {
      Map<String, Object?> outcome;
      try {
        outcome = await change.apply();
      } on DataRefused catch (refusal) {
        outcome = {'result': 'refused', 'reason': refusal.message};
      } on StateError catch (error) {
        outcome = {'result': 'refused', 'reason': error.message};
      }
      results.add(<String, Object?>{
        'setting': change.setting,
        'value': change.value,
        ...outcome,
      });
    }
    return <String, Object?>{
      'sessionId': sessionId,
      'title': row.title,
      'changes': results,
    };
  }

  /// Sets config option [optionId] of [sessionId] to [value].
  _Change _option(
    String sessionId,
    String setting,
    String optionId,
    Object value,
  ) => _Change(setting, value, () async {
    await _context.data.sessionModes.setConfigOption(
      sessionId,
      optionId,
      value,
    );
    return _applied(null);
  });

  static Map<String, Object?> _applied(String? note) => <String, Object?>{
    'result': 'applied',
    'note': ?note,
  };

  /// The choice of [option] that [asked] names — its value, else one value
  /// or name matching it regardless of case — or null with the reason added
  /// to [problems].
  static String? _choose(
    SessionConfigOption option,
    String asked,
    List<String> problems,
    String setting,
  ) {
    final exact = option.choices.where((c) => c.value == asked).firstOrNull;
    final chosen =
        exact ??
        _unique(
          option.choices.where(
            (c) => _same(c.value, asked) || _same(c.name, asked),
          ),
        );
    if (chosen != null) return chosen.value;
    problems.add(
      '$setting: "$asked" is not a choice of "${option.name}"; choose one of '
      '${option.choices.map((c) => '"${c.value}" (${c.name})').join(', ')}.',
    );
    return null;
  }

  static T? _unique<T>(Iterable<T> found) =>
      found.length == 1 ? found.single : null;

  static bool _same(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  static String? _string(Map<String, dynamic> arguments, String name) {
    final value = arguments[name];
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError('$name must be a non-blank string.');
    }
    return value.trim();
  }

  static SessionConfigOption? _modelOption(List<SessionConfigOption> options) =>
      options.where((o) => o.isModel && o.isSelect).firstOrNull;

  static SessionConfigOption? _thinkingOption(
    List<SessionConfigOption> options,
  ) => options.where((o) => o.isThinkingLevel && o.isSelect).firstOrNull;

  static SessionConfigOption? _modeOption(List<SessionConfigOption> options) =>
      options.where((o) => o.isMode && o.isSelect).firstOrNull;

  static String _kindOf(SessionConfigOption option) => option.isModel
      ? 'model'
      : option.isThinkingLevel
      ? 'thinking_level'
      : option.isMode
      ? 'mode'
      : 'other';

  static List<Object?> _choices(SessionConfigOption option) => [
    for (final choice in option.choices)
      <String, Object?>{'value': choice.value, 'name': choice.name},
  ];
}

class _Change {
  _Change(this.setting, this.value, this.apply);

  final String setting;
  final Object value;
  final Future<Map<String, Object?>> Function() apply;
}
