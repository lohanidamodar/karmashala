import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' hide Clock;
import 'package:agent_cli/process.dart'
    show EnvironmentPath, localHostEnvironmentId;
import 'package:karmashala_automations/resumes.dart' show ScheduledResume;
import 'package:karmashala_automations/store.dart' show ScheduledResumeDao;
import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_mcp/launch.dart';
import 'package:karmashala_projects/store.dart' show RepositoryDao;
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart' show SessionLink;
import 'package:karmashala_session/session.dart' show Session;

import 'package:karmashala_session_engine/store.dart'
    show
        SessionDao,
        kReportModeEachTurn,
        kReportModeFinal,
        kReportModeNone,
        kReportModes;

import '../../automations/daemon_agents.dart';
import '../../sessions/delegation_results.dart'
    show
        DelegatedChild,
        DelegationView,
        ParentReport,
        ReportDelivery,
        ReportStatus,
        kReportViaChild;
import '../../sessions/launch/server_session_launcher.dart';
import '../../sessions/session_subagents.dart' show boundedText;
import '../../status/child_turn_wait.dart';
import 'agent_names.dart';
import 'checkout_reach.dart';
import 'project_folders.dart';
import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// How long `subagent_run` waits unless told, and the most it may be told.
const Duration kSubagentRunDefaultBound = Duration(minutes: 10);
const Duration kSubagentRunMaxBound = Duration(minutes: 30);

/// The bound a caller's `timeoutSeconds` asks for, within the limits.
Duration subagentRunBoundFor(num? seconds) {
  if (seconds == null || seconds <= 0) return kSubagentRunDefaultBound;
  final asked = Duration(milliseconds: (seconds * 1000).round());
  return asked > kSubagentRunMaxBound ? kSubagentRunMaxBound : asked;
}

/// Closes the opening message of a child whose results go back to the
/// session named on its first line.
const String kReportBackHint =
    '[Karmashala: the session named above started you and is waiting for '
    'your report. When you are done, blocked, or need its answer, tell it '
    'with report_to_parent, then end your turn.]';

/// Added for a child its parent hears every turn of.
const String kEachTurnHint =
    '[The end of each turn you work is sent to it as well.]';

/// What an agent is told when a tool would show something and no Karmashala
/// window is connected to show it in.
const String kNoWindowOpen =
    'no Karmashala window is open, so nothing was shown';

/// How a window shows a session it is asked to: behind the person's tab when
/// a session asked for it, or the session has a parent; in front otherwise.
TabReveal revealFor({String? callerSessionId, String? parentSessionId}) =>
    callerSessionId != null || parentSessionId != null
    ? TabReveal.background
    : TabReveal.front;

/// **Starting a session**, by the server — `open_new_session`, for every
/// session an agent asks for (slice 5b), through [ServerSessionLauncher], the
/// path a person's New session takes. The session runs in the server whether
/// or not a window is open; the window the person last used is asked to show
/// it in a tab ([OpenSessionTab]).
///
/// What the server decides as the app did: the checkout (the project's first,
/// unless named — the project's own folder when none is recorded), the agent
/// (named, or the default Settings names), the spawn-depth cap, and the
/// permission carry — a session an agent starts holds no more than the least
/// of its caller's mode and "autoRun".
class LaunchToolSet extends ServerToolSet {
  LaunchToolSet(
    this._context, {
    required this.launches,
    this.agents = const DaemonAgents(),
    CheckoutReach? reach,
    ProjectFolders? folders,
    this.turns,
    this.tokensOf,
    this.endChild,
    this.callHolds,
    this.delegate,
    this.reportToParent,
    this.delegationOf,
    this.setReport,
    this.defaultReportMode,
  }) : _repositories = RepositoryDao(_context.database),
       _reach = reach,
       _folders = folders {
    _launches = LaunchDedupe(
      clock: _ContextClock(_context),
      onCollapsed: (tool) => _context.log(
        'A repeat $tool was collapsed onto the identical launch already '
        'made; nothing new was started. The caller most likely timed out '
        'and retried.',
      ),
    );
  }

  /// One agent per request, however often it arrives: a caller that timed
  /// out and retried must not start a second agent.
  late final LaunchDedupe _launches;

  final ServerToolContext _context;
  final ServerSessionLauncher launches;
  final DaemonAgents agents;
  final RepositoryDao _repositories;

  /// Where a session without a project gets its folder; null where this
  /// server makes none (a fixture), and such a launch is refused in words.
  final CheckoutReach? _reach;
  final ProjectFolders? _folders;

  /// The wait `subagent_run` blocks on; null where this server keeps no
  /// status (a fixture), and the tool is refused in words.
  final ChildTurnWait? turns;

  /// The tokens a session's record counts, every bucket added up.
  final Future<int?> Function(String sessionId)? tokensOf;

  /// Ends a child that answered; null where this server ends nothing (a
  /// fixture), and the child is left open.
  final Future<void> Function(String sessionId)? endChild;

  /// Row [String] is (true) or no longer is (false) waited on by a
  /// `subagent_run` call: its parent owns its turn, not a boot's continue.
  final void Function(String sessionId, bool held)? callHolds;

  /// Watches an async child, whose result is then pushed to its parent
  /// (`DelegationResults.watch`); null where this server pushes nothing, and
  /// async mode is refused in words.
  final void Function(DelegatedChild child)? delegate;

  /// Delivers a child's own report to its parent
  /// (`DelegationResults.report`); null where this server pushes nothing.
  final ReportDelivery Function(ParentReport report)? reportToParent;

  /// Changes what a parent hears of a child (`DelegationResults.setMode`);
  /// null where this server follows nothing.
  final bool Function(DelegatedChild child, String parentId)? setReport;

  /// What Settings say a session hears of a child it starts; null unset.
  final String? Function()? defaultReportMode;

  /// Where a child stands (`DelegationResults.viewOf`); null where this
  /// server follows nothing, and each child's state is not recorded.
  final DelegationView Function(String childId)? delegationOf;

  @override
  List<Map<String, Object?>> get schemas => launchToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    if (tool == 'delegation_capabilities') {
      return runTool(() async => _capabilities(arguments, callerSessionId));
    }
    if (tool == 'report_to_parent') {
      return runTool(() async => _reportToParent(arguments, callerSessionId));
    }
    if (tool == 'delegations') {
      return runTool(() async => _delegations(callerSessionId));
    }
    if (tool == 'delegation_set_report') {
      return runTool(() async => _setReport(arguments, callerSessionId));
    }
    if (tool != 'open_new_session' && tool != 'subagent_run') return null;
    return _launches.run(
      tool: tool,
      arguments: arguments,
      callerSessionId: callerSessionId,
      start: () => runTool(
        () async => tool == 'subagent_run'
            ? await _run(arguments, callerSessionId)
            : await _openTool(arguments, callerSessionId),
      ),
    );
  }

  /// What [callerSessionId] hears of a session `open_new_session` starts:
  /// `report` as named, else the old `mode` (detached is none, async is
  /// each_turn) a client may still send, else Settings' default, else final.
  /// A call from no session hears nothing.
  String _openReportMode(Map<String, dynamic> args, String? callerSessionId) {
    final named = (args['report'] as String?)?.trim() ?? '';
    final legacy = (args['mode'] as String?)?.trim() ?? '';
    final String mode;
    if (named.isNotEmpty) {
      mode = _checkedReport(named);
    } else if (legacy.isNotEmpty) {
      mode = switch (legacy) {
        'detached' => kReportModeNone,
        'async' => kReportModeEachTurn,
        _ => throw ArgumentError(
          'Unknown mode "$legacy"; pass report: none, final or each_turn.',
        ),
      };
    } else if (callerSessionId == null || delegate == null) {
      return kReportModeNone;
    } else {
      final chosen = defaultReportMode?.call();
      mode = kReportModes.contains(chosen) ? chosen! : kReportModeFinal;
    }
    if (mode != kReportModeNone) _canReportTo(callerSessionId);
    return mode;
  }

  static String _checkedReport(String report) => kReportModes.contains(report)
      ? report
      : throw ArgumentError(
          'Unknown report "$report": none, final or each_turn.',
        );

  void _canReportTo(String? callerSessionId) {
    if (callerSessionId == null) {
      throw ArgumentError(
        'Reporting back goes to the session that called, and this call came '
        'from no session; pass report: none.',
      );
    }
    if (delegate == null) {
      throw StateError('This server cannot push results; pass report: none.');
    }
  }

  /// Whether [args] ask `subagent_run` not to wait, refused in words when it
  /// cannot be.
  bool _async(Map<String, dynamic> args, String? callerSessionId, String tool) {
    final mode = (args['mode'] as String?)?.trim() ?? '';
    const fallback = 'wait';
    if (mode.isEmpty || mode == fallback) return false;
    if (mode != 'async') {
      throw ArgumentError(
        'Unknown mode "$mode": "$fallback" (the default) or "async".',
      );
    }
    if (callerSessionId == null) {
      throw ArgumentError(
        'mode "async" reports back to the session that called it, and this '
        'call came from no session.',
      );
    }
    if (delegate == null) {
      throw StateError('This server cannot push results; omit mode.');
    }
    return true;
  }

  /// `open_new_session`: answers once the child is launched, whatever it is
  /// to report — it never waits on the child.
  Future<Map<String, Object?>> _openTool(
    Map<String, dynamic> args,
    String? callerSessionId,
  ) async {
    final report = _openReportMode(args, callerSessionId);
    final started = _context.now();
    final opened = await _open(args, callerSessionId, report: report);
    // Recorded even when it reports nothing, so the parent can list it and
    // change its mind with delegation_set_report.
    if (callerSessionId != null) {
      delegate?.call(
        DelegatedChild(
          childId: opened.session.id,
          parentId: callerSessionId,
          title: opened.session.title,
          agent: agents.nameOf(opened.agentId),
          model: opened.session.modelId,
          startedAt: started,
          reportMode: report,
        ),
      );
    }
    return {
      ...opened.answer,
      'report': report,
      'reportsBack': report != kReportModeNone,
      'note': _reportNote(report, opened.session.id),
    };
  }

  static String _reportNote(String report, String id) => switch (report) {
    kReportModeNone =>
      'Session $id runs on its own and reports nothing. delegation_set_report '
          'changes that; delegations shows where it stands.',
    kReportModeFinal =>
      'End your turn now rather than polling: when session $id reports with '
          'report_to_parent, stops blocked or failed, finishes a turn without '
          'reporting, or ends, a message from '
          'Karmashala says so — at once if you are idle, after your turn if '
          'you are working.',
    _ =>
      'End your turn now rather than polling: when each turn session $id '
          'works ends, its result (agent, model, how long, its final answer) '
          'arrives as a message from Karmashala — at once if you are idle, '
          'after your turn if you are working.',
  };

  /// `report_to_parent`: the caller's own report, to the session that started
  /// it. Refused in words for a session no session started.
  Map<String, Object?> _reportToParent(
    Map<String, dynamic> args,
    String? callerSessionId,
  ) {
    final text = (args['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) {
      throw ArgumentError(
        'text is required and cannot be blank: say what you did, or what '
        'you need.',
      );
    }
    final raw = (args['status'] as String?)?.trim() ?? '';
    final status = raw.isEmpty
        ? ReportStatus.done
        : ReportStatus.byWire(raw) ??
              (throw ArgumentError(
                'Unknown status "$raw": "done", "blocked" or "needs_input".',
              ));
    final session = callerSessionId == null
        ? null
        : SessionDao(_context.database).getById(callerSessionId);
    final parentId = session?.parentSessionId;
    if (session == null || parentId == null) {
      throw StateError(
        'You have no parent session: report_to_parent goes to the session '
        'that started you, and none started this one. Say it in your reply '
        'instead.',
      );
    }
    final link = session.parentLink;
    if (link != null && link != SessionLink.spawn) {
      throw StateError(
        'This session was ${link.phrase} session $parentId, not started by '
        'it to do a task, so no session is waiting on your report. Say it in '
        'your reply instead.',
      );
    }
    final deliver =
        reportToParent ??
        (throw StateError('This server cannot deliver a report.'));
    final delivery = deliver(
      ParentReport(
        childId: session.id,
        parentId: parentId,
        title: session.title,
        agent: _agentNameOf(session),
        status: status,
        text: text,
      ),
    );
    return {
      'reported': delivery == ReportDelivery.delivered,
      'parentSessionId': parentId,
      'status': status.wire,
      'note': switch (delivery) {
        ReportDelivery.delivered =>
          'Delivered to session $parentId: at once if it is idle, after its '
              'turn if it is working. The end of this turn is not pushed to it '
              'as well, so end your turn when you have nothing more to do.',
        ReportDelivery.parentGone =>
          'Not delivered: your parent session has ended; the report is kept '
              'on your session, where it can read it if it comes back. '
              'Nothing will resume it for you.',
        ReportDelivery.notWanted =>
          'Not delivered: your parent asked to be told nothing of this '
              'session; the report is kept on your session.',
      },
    };
  }

  /// `delegation_set_report`: what the caller hears of a session it started.
  Map<String, Object?> _setReport(
    Map<String, dynamic> args,
    String? callerSessionId,
  ) {
    final report = _checkedReport((args['report'] as String?)?.trim() ?? '');
    final childId = (args['sessionId'] as String?)?.trim() ?? '';
    final child = childId.isEmpty
        ? null
        : SessionDao(_context.database).getById(childId);
    final link = child?.parentLink;
    if (callerSessionId == null ||
        child == null ||
        child.parentSessionId != callerSessionId ||
        (link != null && link != SessionLink.spawn)) {
      throw StateError(
        'Session ${childId.isEmpty ? '(none named)' : childId} is not one '
        'you started; delegations lists the ones you did.',
      );
    }
    final set =
        setReport ?? (throw StateError('This server follows no sessions.'));
    set(
      DelegatedChild(
        childId: child.id,
        parentId: callerSessionId,
        title: child.title,
        agent: _agentNameOf(child),
        model: child.modelId,
        startedAt: child.createdAt,
        reportMode: report,
      ),
      callerSessionId,
    );
    return {
      'sessionId': child.id,
      'report': report,
      'note': _reportNote(report, child.id),
    };
  }

  String _agentNameOf(Session session) {
    final agentId = _context.data.installations
        .where((i) => i.id == session.agentInstallationId)
        .firstOrNull
        ?.agentId;
    return agentId == null ? 'not recorded' : agents.nameOf(agentId);
  }

  /// `delegations`: the sessions the caller started, and where each stands.
  Map<String, Object?> _delegations(String? callerSessionId) {
    if (callerSessionId == null) {
      throw StateError(
        'delegations lists the sessions a session started, and this call '
        'came from no session.',
      );
    }
    final children = [
      for (final child in SessionDao(
        _context.database,
      ).childrenOf(callerSessionId))
        if (child.parentLink == null || child.parentLink == SessionLink.spawn)
          child,
    ];
    return {
      'children': [for (final child in children) _delegationRow(child)],
      'note':
          'state is running, reported done, blocked, needs input, failed or '
          'ended. A followed child pushes the end of each turn it works to '
          'you, and report_to_parent arrives at once: end your turn and wait '
          'for them rather than polling.',
    };
  }

  Map<String, Object?> _delegationRow(Session child) {
    final view = delegationOf?.call(child.id);
    final at = view?.reportedAt;
    return {
      'sessionId': child.id,
      'title': child.title,
      'agent': _agentNameOf(child),
      'state': view?.state ?? 'not recorded',
      'report': view?.reportMode ?? kReportModeNone,
      'followed': view?.followed ?? false,
      'lastReport': at == null
          ? 'not recorded'
          : {
              'status': view!.reportState,
              'by': view.reportVia == kReportViaChild
                  ? 'the child, with report_to_parent'
                  : 'the end of its turn',
              'at': at.toIso8601String(),
              // One you never got — you were gone, or asked for none — is
              // read here instead.
              if (view.reportDelivered == false) ...{
                'delivered': false,
                'text': view.reportText ?? 'not recorded',
              },
            },
    };
  }

  /// `delegation_capabilities`: the agents and models the caller can hand a
  /// child, in the caller's environment unless one is named.
  Map<String, Object?> _capabilities(
    Map<String, dynamic> args,
    String? callerSessionId,
  ) {
    final caller = callerSessionId == null
        ? null
        : SessionDao(_context.database).getById(callerSessionId);
    final environmentId =
        (args['environmentId'] as String?) ??
        (caller == null
            ? null
            : _repositories.getById(caller.repositoryId)?.path.environmentId) ??
        localHostEnvironmentId;
    final installs = launches.installationsIn(environmentId);
    final picked =
        launches.defaultInstallationIn(environmentId) ?? installs.firstOrNull;
    final depth = launches.depthForChildOf(callerSessionId);
    return {
      'environmentId': environmentId,
      'agents': [
        for (final install in installs)
          _agentCapabilities(install, isDefault: install.id == picked?.id),
      ],
      'depth': depth.isAllowed ? depth.depth : null,
      'canDelegate': depth.isAllowed,
      if (!depth.isAllowed) 'refusal': depth.refusal,
      'modes': const ['wait', 'async'],
      'note':
          'Pass agentInstallationId (or cli) and model to subagent_run or '
          'open_new_session. Prefer mode "async" and end your turn: results '
          'are pushed to you. An agent whose models list is empty takes no '
          'model choice from here.',
    };
  }

  Map<String, Object?> _agentCapabilities(
    AgentInstallation install, {
    required bool isDefault,
  }) {
    final descriptor = agents.descriptorOf(install.agentId);
    final models = descriptor == null
        ? const <AgentModelOption>[]
        : modelOptionsFor(descriptor);
    return {
      'agentInstallationId': install.id,
      'cli': install.agentId,
      'name': agents.nameOf(install.agentId),
      'default': isDefault,
      'protocol': descriptor?.acp == null ? 'terminal' : 'acp',
      'models': [
        for (final option in models)
          if (option.isSelectable)
            {
              'id': option.model.id,
              'label': option.model.label,
              if (option.model.summary.isNotEmpty)
                'summary': option.model.summary,
            },
      ],
      if (descriptor?.acp != null)
        'modelsNote':
            'An ACP agent announces its models once it runs; any listed here '
            'are what this build knows.',
    };
  }

  /// `subagent_run`: [_open]'s launch — its depth cap and permission carry —
  /// then a wait for the child's first turn, answered with what it said.
  Future<Object?> _run(
    Map<String, dynamic> args,
    String? callerSessionId,
  ) async {
    final prompt = (args['prompt'] as String?)?.trim() ?? '';
    if (prompt.isEmpty) {
      throw ArgumentError('prompt is required and cannot be blank.');
    }
    final reportsBack = _async(args, callerSessionId, 'subagent_run');
    final namedReport = (args['report'] as String?)?.trim() ?? '';
    // Only an async run reports; one that waits answers in the call.
    final report = !reportsBack
        ? kReportModeNone
        : namedReport.isEmpty
        ? kReportModeFinal
        : _checkedReport(namedReport);
    final turns = this.turns;
    if (turns == null && !reportsBack) {
      throw StateError(
        'This server keeps no session status, so it cannot wait for a '
        'subagent. Use open_new_session and session_wait.',
      );
    }
    final bound = subagentRunBoundFor(args['timeoutSeconds'] as num?);
    final model = (args['model'] as String?)?.trim();
    final title = (args['title'] as String?)?.trim();
    final started = _context.now();
    final opened = await _open(
      {
        ...args,
        'prompt': prompt,
        'title': title == null || title.isEmpty
            ? 'Subagent: ${_firstLine(prompt)}'
            : title,
      },
      callerSessionId,
      modelId: model == null || model.isEmpty ? null : model,
      inCallerTree: true,
      report: report,
    );
    final session = opened.session;
    if (reportsBack) {
      delegate!(
        DelegatedChild(
          childId: session.id,
          parentId: callerSessionId!,
          title: session.title,
          agent: agents.nameOf(opened.agentId),
          model: session.modelId,
          startedAt: started,
          endOnAnswer: args['keepOpen'] != true,
          reportMode: report,
        ),
      );
      return <String, Object?>{
        'state': 'started',
        'mode': 'async',
        'report': report,
        'childSessionId': session.id,
        'title': session.title,
        'agent': agents.nameOf(opened.agentId),
        'model': session.modelId ?? "the agent's default (not recorded)",
        'depth': opened.answer['depth'],
        'permissionMode': opened.answer['permissionMode'],
        'permissionCapped': ?opened.answer['permissionCapped'],
        'note': args['keepOpen'] == true || report == kReportModeNone
            ? _reportNote(report, session.id)
            : 'End your turn now rather than polling: when the child answers, '
                  'its result (agent, model, how long, its final answer) '
                  'arrives as a message from Karmashala, and it is ended. '
                  'Child: session ${session.id}.',
      };
    }
    final ChildTurnOutcome outcome;
    callHolds?.call(session.id, true);
    try {
      outcome = await turns!.firstTurn(
        session.id,
        bound: bound,
        since: started,
      );
    } finally {
      callHolds?.call(session.id, false);
    }
    final answer = switch (outcome.state) {
      ChildTurnState.running || ChildTurnState.blocked => null,
      _ => await _answerOf(turns, session.id, since: started),
    };
    final (text, cut) = answer == null
        ? (null, false)
        : boundedText(answer.text, kFinalAnswerMaxChars);
    final tokens = await tokensOf?.call(session.id);
    final block = outcome.block;
    final keepOpen = args['keepOpen'] == true;
    final ended = outcome.state == ChildTurnState.done && !keepOpen
        ? await _end(session.id)
        : null;
    final resume = outcome.state == ChildTurnState.failed
        ? await _armedResumeOf(session.id, turns.recheck)
        : null;
    return <String, Object?>{
      'state': outcome.state.name,
      'childSessionId': session.id,
      'title': session.title,
      'agent': agents.nameOf(opened.agentId),
      'model': session.modelId ?? "the agent's default (not recorded)",
      'finalAnswer': text,
      if (cut) 'finalAnswerTruncated': true,
      'finalAnswerSource': text == null
          ? 'not recorded — no agent message in its record since it started'
          : "the child's last agent message, from its record",
      'durationMs': _context.now().difference(started).inMilliseconds,
      'tokens': tokens ?? 'not recorded',
      if (block != null)
        'blockedOn': <String, Object?>{'kind': block.kind, 'text': block.text},
      if (outcome.state == ChildTurnState.ended) ...{
        'exitCode': outcome.exitCode,
        'exitCodeKnown': outcome.exitCodeKnown,
      },
      'depth': opened.answer['depth'],
      'permissionMode': opened.answer['permissionMode'],
      'permissionCapped': ?opened.answer['permissionCapped'],
      'childOpen': switch (outcome.state) {
        ChildTurnState.ended => false,
        ChildTurnState.done => ended != true,
        _ => true,
      },
      if (resume != null)
        'resume': <String, Object?>{
          'at': resume.fireAt.toUtc().toIso8601String(),
          'message': resume.message,
          'window': resume.windowLabel ?? 'a time chosen',
        },
      'note': _runNote(
        outcome.state,
        session.id,
        bound,
        keptOpen: keepOpen,
        ended: ended,
        resume: resume,
      ),
    };
  }

  /// Ends [sessionId] once it has answered: true when it ended, false when
  /// ending it failed, null where this server ends nothing.
  Future<bool?> _end(String sessionId) async {
    final end = endChild;
    if (end == null) return null;
    try {
      await end(sessionId);
      return true;
    } on Object catch (error) {
      _context.log('subagent_run could not end child $sessionId: $error');
      return false;
    }
  }

  /// The resume a limit armed for [sessionId]: the setting arms it after a
  /// fresh usage reading, so a failure is looked at again briefly.
  Future<ScheduledResume?> _armedResumeOf(
    String sessionId,
    Duration recheck,
  ) async {
    final resumes = ScheduledResumeDao(_context.database);
    for (var attempt = 0; ; attempt++) {
      final live = resumes.liveFor(sessionId);
      if (live != null || attempt >= 3) return live;
      await Future<void>.delayed(recheck);
    }
  }

  /// The answer once the turn settled; a record written a moment after the
  /// status moved is read again, briefly.
  static Future<({String text, DateTime? at})?> _answerOf(
    ChildTurnWait turns,
    String sessionId, {
    required DateTime since,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final answer = await turns.answerOf(sessionId, since: since);
      if (answer != null || attempt >= 2) return answer;
      await Future<void>.delayed(turns.recheck);
    }
  }

  /// The `form` a caller named, or null for none; anything else is refused.
  static AgentRunForm? _runForm(Object? value) {
    if (value == null) return null;
    for (final form in AgentRunForm.values) {
      if (form.name == value) return form;
    }
    throw ArgumentError.value(value, 'form', 'must be "terminal" or "chat"');
  }

  static String _firstLine(String prompt) {
    final line = prompt.split('\n').first.trim();
    return line.length <= 48 ? line : '${line.substring(0, 47)}…';
  }

  static String _runNote(
    ChildTurnState state,
    String id,
    Duration bound, {
    required bool keptOpen,
    required bool? ended,
    required ScheduledResume? resume,
  }) => switch (state) {
    ChildTurnState.done => switch (ended) {
      true =>
        'The child finished its turn; finalAnswer is what it said last. It '
            'was ended once it answered; pass keepOpen: true to keep a child '
            'open for a follow-up.',
      false =>
        'The child finished its turn; finalAnswer is what it said last. '
            'Ending it failed, so it is still open as session $id: end it '
            'with session_end when you are done with it.',
      null =>
        'The child finished its turn; finalAnswer is what it said last. It '
            'is still open as session $id for a follow-up with session_send'
            '${keptOpen ? '' : '; end it with session_end when you are done'}.',
    },
    ChildTurnState.failed => switch (resume) {
      final resume? =>
        'The child stopped on its usage limit, and Karmashala resumes it at '
            '${resume.fireAt.toUtc().toIso8601String()} '
            '${resume.sendsMessage ? 'with "${resume.message}"' : 'saying nothing'} '
            '(resume). It is still open as session $id: session_wait on it '
            'after then for its answer. Ending it does not cancel that '
            'resume; only the user can, from the session\'s bar.',
      null =>
        'The child stopped on a failure. Read session_transcript '
            '(sessionId: $id) for why. It is still open; end it with '
            'session_end when you are done with it.',
    },
    ChildTurnState.blocked =>
      'BLOCKED ON A PERSON: the child stopped for an approval or a '
          'question (blockedOn). Waiting longer will not clear it; ask the '
          'user, or answer an approval with session_answer, then '
          'session_wait on $id.',
    ChildTurnState.ended =>
      'The child process ended. exitCode is UNKNOWN — not 0 — when '
          'exitCodeKnown is false.',
    ChildTurnState.running =>
      'STILL RUNNING after ${bound.inSeconds}s, which is this call\'s '
          'bound, not a verdict. Continue with session_wait (sessionId: '
          '$id) and read its answer with session_transcript. Calling '
          'subagent_run again starts another agent.',
  };

  Future<({Map<String, Object?> answer, Session session, String agentId})>
  _open(
    Map<String, dynamic> args,
    String? callerSessionId, {
    String? modelId,
    bool inCallerTree = false,
    String report = kReportModeNone,
  }) async {
    final projectId = args['projectId'] as String?;
    final prompt = args['prompt'] as String?;
    final repositoryId = args['repositoryId'] as String?;
    final title = args['title'] as String?;
    final newWorktree = args['useWorktree'] == true;
    // With [inCallerTree] and no place named, the child shares the caller's
    // tree, as an agent's own subagents do.
    final caller = inCallerTree && projectId == null && args['scratch'] != true
        ? (callerSessionId == null
              ? null
              : SessionDao(_context.database).getById(callerSessionId))
        : null;
    final callerWorktree = caller == null || caller.worktreeRemoved
        ? null
        : caller.worktree;
    EnvironmentPath? existingWorktree;
    EnvironmentPath? workingDirectory;
    final Repository repo;
    if (caller != null) {
      repo =
          _repositories.getById(caller.repositoryId) ??
          (throw StateError(
            "Your session's checkout is no longer in the workspace; name a "
            'projectId, or pass scratch.',
          ));
      if (!newWorktree) {
        existingWorktree = callerWorktree;
        workingDirectory = callerWorktree == null
            ? caller.workingDirectory
            : null;
      }
    } else if (projectId == null || args['scratch'] == true) {
      repo = await _scratchCheckout(
        environmentId: args['environmentId'] as String?,
        callerSessionId: callerSessionId,
        hint: title ?? args['prompt'] as String?,
      );
    } else if (repositoryId != null) {
      repo = _repositories
          .getByProject(projectId)
          .firstWhere(
            (r) => r.id == repositoryId,
            orElse: () =>
                throw StateError('Repository not found in this project.'),
          );
    } else {
      repo =
          _repositories.getByProject(projectId).firstOrNull ??
          _runLocationOf(projectId);
    }
    final installs = launches.installationsIn(repo.path.environmentId);
    if (installs.isEmpty) {
      throw StateError('No agent is installed in ${repo.path.environmentId}.');
    }
    final agentInstallationId = args['agentInstallationId'] as String?;
    final cli = args['cli'] as String?;
    final form = _runForm(args['form']);
    final registry = _context.agents;
    AgentInstallation? install;
    if (agentInstallationId != null) {
      install = installs.where((i) => i.id == agentInstallationId).firstOrNull;
      if (install == null) {
        throw StateError(
          'That agent installation is not available in this project.',
        );
      }
      // A named installation is taken as named: one of the other form is a
      // contradiction, not a request to switch.
      if (form != null && registry.formOf(install.agentId) != form) {
        throw StateError(
          'Installation $agentInstallationId runs as '
          '${registry.formOf(install.agentId).name}, not ${form.name}.',
        );
      }
    } else if (cli != null) {
      final agentId = agentIdForName(registry, cli);
      // Either form of the agent named; the form is decided below.
      final agent = agentId == null ? null : registry.foldedIdOf(agentId);
      install =
          installs.where((i) => i.agentId == agentId).firstOrNull ??
          installs
              .where((i) => registry.foldedIdOf(i.agentId) == agent)
              .firstOrNull;
      if (install == null) {
        throw StateError(
          '$cli is not installed in ${repo.path.environmentId}.',
        );
      }
      install = launches.installationFor(install, form: form);
    } else {
      install =
          launches.defaultInstallationIn(repo.path.environmentId) ??
          installs.first;
      if (form != null) install = launches.installationFor(install, form: form);
    }

    final permission = _spawnPermission(
      args['permissionMode'] as String?,
      install.agentId,
      callerSessionId,
    );
    final started = await launches.start(
      SessionStartSpec(
        repositoryId: repo.id,
        installationId: install.id,
        // Untitled stays blank, so the launch names it from the prompt.
        title: title?.trim() ?? '',
        // A title the caller named is chosen, as one typed in the dialog is:
        // the agent's own name for the conversation never replaces it.
        titleTyped: title != null && title.trim().isNotEmpty,
        prompt: switch (report) {
          _ when prompt == null => null,
          kReportModeNone => prompt,
          kReportModeEachTurn => '$prompt\n\n$kReportBackHint $kEachTurnHint',
          _ => '$prompt\n\n$kReportBackHint',
        },
        worktree: newWorktree,
        existingWorktree: existingWorktree,
        workingDirectory: workingDirectory,
        permissionMode: permission.selection?.canonical,
        modelId: modelId,
        parentSessionId: callerSessionId,
      ),
    );
    final session = started.session;
    final shown = _context.data.tellIntent(
      OpenSessionTab(
        sessionId: session.id,
        title: session.title,
        launch: started.launch,
        reveal: revealFor(
          callerSessionId: callerSessionId,
          parentSessionId: session.parentSessionId,
        ),
      ),
    );
    final answer = <String, Object?>{
      'sessionId': session.id,
      'opened': 'new ${install.agentId} session',
      'title': session.title,
      'repository': repo.name,
      'environmentId': repo.path.environmentId,
      'depth': started.depth ?? launches.depthForChildOf(callerSessionId).depth,
      'permissionMode': session.permissionMode ?? 'not recorded',
      if (permission.capped != null) 'permissionCapped': permission.capped,
      if (session.worktree != null) 'worktree': session.worktree!.path,
      'where': shown
          ? 'running in the Karmashala server, shown in a tab of the '
                'Karmashala window'
          : 'running in the Karmashala server; $kNoWindowOpen — a window '
                'shows it when it is opened',
    };
    return (answer: answer, session: session, agentId: install.agentId);
  }

  /// A folder of its own for a session without a project, in
  /// [environmentId] — the caller's own environment when none is named, or
  /// this machine's.
  Future<Repository> _scratchCheckout({
    required String? environmentId,
    required String? callerSessionId,
    required String? hint,
  }) async {
    final reach = _reach, folders = _folders;
    if (reach == null || folders == null) {
      throw StateError(
        'This server cannot make a scratch folder; name a projectId.',
      );
    }
    final caller = callerSessionId == null
        ? null
        : SessionDao(_context.database).getById(callerSessionId);
    final callerEnvironment = caller == null
        ? null
        : _repositories.getById(caller.repositoryId)?.path.environmentId;
    final id = environmentId ?? callerEnvironment ?? localHostEnvironmentId;
    final environment = reach.environment(id);
    if (environment == null) {
      throw StateError(
        'No environment with id $id. list_agents names the ones this '
        'workspace knows.',
      );
    }
    if (!reach.reaches(environment)) {
      throw StateError(
        '${environment.name} is not reachable from this server, so no '
        'scratch folder can be made there.',
      );
    }
    return folders.createScratchCheckout(target: environment, hint: hint);
  }

  /// Where a session started at [projectId] runs when the workspace records
  /// no checkout for it: the project's own folder, recorded now.
  Repository _runLocationOf(String projectId) {
    final added = _context.write(CheckoutsAdd(projectId: projectId));
    final first =
        added.firstOrNull ?? _repositories.getByProject(projectId).firstOrNull;
    if (first == null) {
      throw StateError('This project is no longer in the workspace.');
    }
    return first;
  }

  /// The mode a session an agent asked for launches under: the least of what
  /// it named (or the Settings default), what the calling session holds, and
  /// the spawn ceiling. A named mode above that is refused rather than
  /// quietly lowered; an omitted one is lowered and `capped` says so.
  ({PermissionSelection? selection, String? capped}) _spawnPermission(
    String? raw,
    String agentId,
    String? callerSessionId,
  ) {
    final descriptor = agents.descriptorOf(agentId);
    final support = descriptor?.launch.permission;
    final wanted = raw?.trim() ?? '';
    final risk = PermissionRisk.byName(wanted);
    if (support == null || !support.isKnown) {
      if (wanted.isEmpty || risk != null) {
        return (selection: null, capped: null);
      }
      throw _unknownMode(raw!, support);
    }
    final defaultRisk =
        support.riskOf(
          launches.permissionFor(agentId, SessionPurpose.newSession),
        ) ??
        PermissionRisk.ask;
    final callerRisk = _callerRisk(callerSessionId) ?? defaultRisk;

    SpawnCarry carry(PermissionRisk requested) => carrySpawnPermission(
      requested: requested,
      callerRisk: callerRisk,
      target: descriptor,
    );

    if (wanted.isEmpty) {
      final capped = carry(defaultRisk);
      if (!capped.wasCapped) return (selection: null, capped: null);
      return (
        selection: capped.selection,
        capped:
            'Started at ${capped.carried.label} rather than the Settings '
            'default (${defaultRisk.label.toLowerCase()}): ${capped.reason}.',
      );
    }
    if (risk != null) {
      final capped = carry(risk);
      if (capped.wasCapped) throw ArgumentError(capped.refusal);
      return (selection: capped.selection, capped: null);
    }
    for (final selection in support.selections()) {
      if (selection.canonical != wanted) continue;
      final exact = support.riskOf(selection);
      if (exact != null && carry(exact).wasCapped) {
        throw ArgumentError(carry(exact).refusal);
      }
      return (selection: selection, capped: null);
    }
    throw _unknownMode(raw!, support);
  }

  /// How permissive the calling session is, or null when there is no caller
  /// or its rung cannot be established — which reads as the default, never
  /// as unbounded.
  PermissionRisk? _callerRisk(String? callerSessionId) {
    if (callerSessionId == null) return null;
    final effective = launches.effectivePermissionOf(callerSessionId);
    if (effective == null) return null;
    final caller = _context.data.installations
        .where(
          (i) =>
              i.id ==
              launches.sessions.getById(callerSessionId)?.agentInstallationId,
        )
        .firstOrNull;
    if (caller == null) return null;
    final support = agents.descriptorOf(caller.agentId)?.launch.permission;
    return support?.riskOf(effective.selection);
  }

  static ArgumentError _unknownMode(
    String raw,
    AgentPermissionSupport? support,
  ) => ArgumentError(
    'Unknown permissionMode "$raw". One of: '
    '${PermissionRisk.values.map((m) => m.name).join(', ')}'
    '${support != null && support.isKnown ? ', or one of '
              '${support.selections().map((s) => s.canonical).join(', ')}' : ''}.',
  );
}

final class _ContextClock implements Clock {
  const _ContextClock(this._context);
  final ServerToolContext _context;
  @override
  DateTime nowUtc() => _context.now();
}

/// How the agent runs, for the tools that start one.
const Map<String, Object?> _formSchema = {
  'type': 'string',
  'enum': ['terminal', 'chat'],
  'description':
      'How the agent runs: "terminal" (its CLI in a terminal) or "chat". '
      'Omit for the form the person chose for that agent in Settings. Refused '
      'when the agent is not installed in that form there.',
};

/// The schemas of the launch tools the server runs, moved from the app with
/// their words unchanged.
const List<Map<String, Object?>> launchToolSchemas = [
  {
    'name': 'open_new_session',
    'description':
        'Start a NEW agent session (not a resume), as a terminal tab in '
        'Karmashala. In a project when projectId is given; without one, or '
        'with scratch, in a scratch folder of its own with no project — the '
        'new agent attaches whatever repositories it needs. Choose the agent '
        'with agentInstallationId (from list_agents) or cli ("claude"/'
        '"codex"); omit both to use the configured default. repositoryId is '
        "optional (defaults to the project's first repository). The agent "
        "must be installed in the session's environment. Sessions you start "
        'this way are recorded as your children, and nesting is capped: if '
        'the call is refused for depth, do the work yourself instead of '
        'delegating it further.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {
          'type': 'string',
          'description':
              'Project id from list_projects. Omit for a session without a '
              'project.',
        },
        'scratch': {
          'type': 'boolean',
          'description':
              'Start without a project, in a scratch folder under '
              '~/karmashala/scratch, even when a projectId is given.',
        },
        'environmentId': {
          'type': 'string',
          'description':
              'For a session without a project: where its folder is made. '
              'Defaults to your own environment.',
        },
        'cli': {
          'type': 'string',
          'description': 'Agent CLI to use: "claude" or "codex".',
        },
        'agentInstallationId': {
          'type': 'string',
          'description': 'Specific installation id from list_agents.',
        },
        'form': _formSchema,
        'repositoryId': {'type': 'string'},
        'title': {
          'type': 'string',
          'description': 'Short name for the session, shown in the tab.',
        },
        'prompt': {
          'type': 'string',
          'description':
              'Opening instruction for the new agent. Sent as its first '
              'message, prefixed with a line naming this session.',
        },
        'useWorktree': {
          'type': 'boolean',
          'description':
              'Run in a dedicated Git worktree instead of the repository '
              'itself. Use this when the new session will edit files and you '
              'are still working in the same repository.',
        },
        'permissionMode': {
          'type': 'string',
          'enum': permissionRiskNames,
          'description':
              'How much the new agent may do without asking, on the scale '
              'every agent shares. The chosen agent is given the closest '
              'mode it really has, never one it does not — Codex, for '
              'instance, has nothing at "ask". Omit to use the mode '
              'configured in Settings, which is what the New-session dialog '
              'does. A session you start holds no more than the least of your '
              'own mode and "autoRun"; a mode above that is refused, and only '
              'the user can raise it, from the new session\'s permission chip.',
        },
        'report': {
          'type': 'string',
          'enum': kReportModes,
          'description':
              'What you hear of it. This call never waits for it either way. '
              '"final" (the default unless Settings choose another): one '
              'message when it reports with report_to_parent, stops blocked '
              'or failed, finishes a turn without reporting, or ends. '
              '"each_turn": the end of every turn it '
              'works as well. "none": it runs on its own and nothing comes '
              'back. End your turn rather than polling; change it later '
              'with delegation_set_report. The session is never ended for '
              'you.',
        },
      },
      'required': <String>[],
    },
  },
  {
    'name': 'subagent_run',
    'description':
        'Run a subagent: start a NEW session on any installed agent and '
        'model with prompt as its task, wait for its first turn to finish, '
        'and get its final answer back. Unless you name a projectId (or '
        'scratch) it works in YOUR checkout and directory — your worktree, '
        'if you are in one — so it sees the files you see; useWorktree gives '
        'it a worktree of its own instead. It is launched as open_new_session '
        'launches one — recorded as your child, under the same nesting cap '
        'and permission ceiling. A child that answers (done) is ended then, '
        'unless keepOpen is true; any other child stays open as a session '
        'you can follow up with session_send. state is done, failed, blocked '
        '(it stopped for an approval or a question: blockedOn says which), '
        'ended, or running when timeoutSeconds ran out first — then continue '
        'with session_wait on childSessionId; calling this again starts '
        'another agent. If your own tool calls time out sooner than the '
        'default 600 seconds, pass a smaller timeoutSeconds.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description':
              'The task, sent as the subagent\'s first message under a line '
              'naming this session. Say what to return: its last message is '
              'the answer.',
        },
        'cli': {
          'type': 'string',
          'description':
              'Agent to run, by name ("claude", "codex", …); list_agents has '
              'them. Omit both this and agentInstallationId for the default.',
        },
        'agentInstallationId': {
          'type': 'string',
          'description': 'Specific installation id from list_agents.',
        },
        'form': _formSchema,
        'model': {
          'type': 'string',
          'description':
              'The agent\'s own model id. Omit for the model configured for '
              'that agent.',
        },
        'projectId': {
          'type': 'string',
          'description':
              'Project id from list_projects, to run there instead of in '
              'your own checkout and directory.',
        },
        'repositoryId': {'type': 'string'},
        'scratch': {
          'type': 'boolean',
          'description':
              'Run in a scratch folder of its own, with no project, instead '
              'of your checkout.',
        },
        'environmentId': {
          'type': 'string',
          'description': 'With scratch: where its folder is made.',
        },
        'useWorktree': {
          'type': 'boolean',
          'description':
              'Run in a new Git worktree of its own rather than sharing your '
              'tree — for a subagent whose edits must not land in your files '
              'while you work.',
        },
        'title': {
          'type': 'string',
          'description': 'Name for the child session; defaults to the prompt.',
        },
        'permissionMode': {
          'type': 'string',
          'enum': permissionRiskNames,
          'description':
              'As open_new_session: never above the least of your own mode '
              'and "autoRun".',
        },
        'timeoutSeconds': {
          'type': 'number',
          'description':
              'How long to wait for its answer: default 600, at most 1800.',
        },
        'keepOpen': {
          'type': 'boolean',
          'description':
              'Keep the child open after it answers, for a follow-up with '
              'session_send; end it with session_end when done. Default '
              'false: an answered child is ended.',
        },
        'mode': {
          'type': 'string',
          'enum': ['wait', 'async'],
          'description':
              '"wait" (default): this call blocks until the child answers. '
              '"async": answers at once with childSessionId; when the child\'s '
              'turn ends its result — agent, model, duration and final '
              'answer — is pushed to you as a message, batched with others '
              'that finish together. Start several, then end your turn; do '
              'not poll. Recommended for long or parallel work.',
        },
        'report': {
          'type': 'string',
          'enum': kReportModes,
          'description':
              'With mode "async" and keepOpen, what you hear after its '
              'answer: "final" (default) when it reports, stops blocked or '
              'failed, finishes a turn without reporting, or ends; '
              '"each_turn" every turn; "none" nothing.',
        },
      },
      'required': <String>['prompt'],
    },
  },
  {
    'name': 'delegation_capabilities',
    'description':
        'What you can delegate to: the agents installed where you run (or in '
        'environmentId), each with its installation id, protocol and the '
        'models it can be started on, which one is the default, and whether '
        'your nesting depth still allows starting a child. Read this before '
        'choosing cli/agentInstallationId and model for subagent_run or '
        'open_new_session.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'environmentId': {
          'type': 'string',
          'description': 'Defaults to your own environment.',
        },
      },
      'required': <String>[],
    },
  },
  {
    'name': 'delegations',
    'description':
        'The sessions you started with open_new_session or subagent_run, '
        'each with its state — running, reported done, blocked, needs input, '
        'failed or ended — whether its turn ends are pushed to you '
        '(followed), and its last report: what, by whom, when. Read it '
        'instead of polling transcripts or files; results and reports '
        'arrive by themselves.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
  },
  {
    'name': 'delegation_set_report',
    'description':
        'Change what you hear of a session you started: "final", '
        '"each_turn" or "none" (see open_new_session\'s report). From none '
        'it is followed again from its next turn; to none nothing more '
        'comes back.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'The child, from delegations.',
        },
        'report': {'type': 'string', 'enum': kReportModes},
      },
      'required': <String>['sessionId', 'report'],
    },
  },
  {
    'name': 'report_to_parent',
    'description':
        'Report to the session that started you (open_new_session or '
        'subagent_run): it gets your text at once as a message naming you — '
        'after its turn if it is working. Use it when you are done, blocked, '
        'or need its answer, then end your turn. The end of the turn you '
        'report in is not pushed to it as well. Needs no "Operate '
        'Karmashala". When your parent has ended, or asked to hear nothing, '
        'the report is kept on your session instead, and nothing resumes '
        'it. Refused when no session started yours.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description':
              'What you did and what it needs to know, or what you need '
              'from it. Cut at 4000 characters.',
        },
        'status': {
          'type': 'string',
          'enum': ['done', 'blocked', 'needs_input'],
          'description':
              '"done" (default): finished; it is marked reported in your '
              'parent\'s delegation list. "blocked": you cannot go on. '
              '"needs_input": you are waiting for its answer.',
        },
      },
      'required': <String>['text'],
    },
  },
];
