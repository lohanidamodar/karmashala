import 'dart:convert';

import 'mcp_tool_catalogue.dart';

/// Where the person turns a tool group on, as a refusal names it.
const String kMcpToolAccessLocation = 'Settings → Permissions → Tool access';

/// The server metadata key the whole [McpToolAccessPolicy] is kept under.
const String kMcpToolAccessKey = 'agents.tool_access.v1';

/// A set of operator tools a session may use without Operate Karmashala, when
/// the person's tool access settings leave the group on.
enum McpToolGroup {
  message(
    'Message sessions',
    'Send to, rename and draft to sessions in its project, its parent and '
        'its children.',
    defaultOn: true,
  ),
  start(
    'Start sessions',
    'Open, fork and hand off sessions, and run sub-sessions.',
    defaultOn: true,
  ),
  configure(
    'Change other sessions',
    'End, rewind and reconfigure other sessions, and write onto them.',
    defaultOn: false,
  ),
  answer(
    'Answer approvals',
    "Approve or deny another agent's permission prompts.",
    defaultOn: false,
  ),
  pipelines(
    'Pipelines and worktrees',
    'Run and approve pipelines, and remove worktrees.',
    defaultOn: false,
  ),
  panes(
    'Type into panes',
    'Insert snippets into panes and kill terminal tabs.',
    defaultOn: false,
  );

  const McpToolGroup(this.label, this.meaning, {required this.defaultOn});

  final String label;

  /// One line on what the group lets an agent do.
  final String meaning;

  /// Whether it is on when nothing is set.
  final bool defaultOn;

  /// The id stored in the policy.
  String get id => name;

  /// Its tools, in catalogue order.
  List<String> get tools => [
    for (final entry in kMcpToolGroups.entries)
      if (entry.value == this) entry.key,
  ];

  static McpToolGroup? byId(String id) {
    for (final group in values) {
      if (group.id == id) return group;
    }
    return null;
  }
}

/// Every tool the operator gate can stop, and its one group. A tool gated only
/// on another session is here for that case alone.
const Map<String, McpToolGroup> kMcpToolGroups = {
  'session_send': McpToolGroup.message,
  'session_rename': McpToolGroup.message,
  'session_draft': McpToolGroup.message,
  'open_new_session': McpToolGroup.start,
  'open_session': McpToolGroup.start,
  'subagent_run': McpToolGroup.start,
  'session_fork': McpToolGroup.start,
  'session_fork_from_checkpoint': McpToolGroup.start,
  'session_handoff': McpToolGroup.start,
  'session_end': McpToolGroup.configure,
  'session_rewind': McpToolGroup.configure,
  'delegation_set_report': McpToolGroup.configure,
  'delegation_detach': McpToolGroup.configure,
  'checkpoint_restore': McpToolGroup.configure,
  'checkpoint_capture': McpToolGroup.configure,
  'checks_run': McpToolGroup.configure,
  'decision_record': McpToolGroup.configure,
  'session_checkout_attach': McpToolGroup.configure,
  'session_checkout_detach': McpToolGroup.configure,
  'session_configure': McpToolGroup.configure,
  'session_answer': McpToolGroup.answer,
  'pipeline_run': McpToolGroup.pipelines,
  'pipeline_approve': McpToolGroup.pipelines,
  'worktree_remove': McpToolGroup.pipelines,
  'snippet_insert': McpToolGroup.panes,
  'terminal_close': McpToolGroup.panes,
};

/// One level's overrides: a group or a tool absent here inherits.
class McpToolAccessOverrides {
  const McpToolAccessOverrides({this.groups = const {}, this.tools = const {}});

  /// By [McpToolGroup.id].
  final Map<String, bool> groups;

  /// By tool name.
  final Map<String, bool> tools;

  static const McpToolAccessOverrides none = McpToolAccessOverrides();

  bool get isEmpty => groups.isEmpty && tools.isEmpty;

  bool? group(McpToolGroup group) => groups[group.id];

  bool? tool(String tool) => tools[tool];

  /// Unknown groups and tools, and values that are not booleans, are dropped.
  factory McpToolAccessOverrides.fromJson(Object? json) {
    if (json is! Map) return none;
    return McpToolAccessOverrides(
      groups: _flags(json['groups'], (id) => McpToolGroup.byId(id) != null),
      tools: _flags(json['tools'], kMcpToolGroups.containsKey),
    );
  }

  Map<String, Object?> toJson() => {
    if (groups.isNotEmpty) 'groups': groups,
    if (tools.isNotEmpty) 'tools': tools,
  };

  McpToolAccessOverrides withGroup(McpToolGroup group, bool? on) =>
      McpToolAccessOverrides(groups: _put(groups, group.id, on), tools: tools);

  McpToolAccessOverrides withTool(String tool, bool? on) =>
      McpToolAccessOverrides(groups: groups, tools: _put(tools, tool, on));

  @override
  bool operator ==(Object other) =>
      other is McpToolAccessOverrides &&
      _sameFlags(other.groups, groups) &&
      _sameFlags(other.tools, tools);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(groups.entries.map((e) => '${e.key}=${e.value}')),
    Object.hashAllUnordered(tools.entries.map((e) => '${e.key}=${e.value}')),
  );
}

/// The person's tool access settings: global overrides, "Any project" for
/// Message sessions, and each project's own overrides. Empty is the defaults.
class McpToolAccessPolicy {
  const McpToolAccessPolicy({
    this.global = McpToolAccessOverrides.none,
    this.messageAnyProject = false,
    this.projects = const {},
  });

  static const McpToolAccessPolicy defaults = McpToolAccessPolicy();

  final McpToolAccessOverrides global;

  /// Message sessions reaches sessions in any project, not just the caller's.
  final bool messageAnyProject;

  /// By project id.
  final Map<String, McpToolAccessOverrides> projects;

  /// Tolerant: anything it cannot read is left at its default.
  factory McpToolAccessPolicy.fromJson(Object? json) {
    if (json is! Map) return defaults;
    final projects = json['projects'];
    return McpToolAccessPolicy(
      global: McpToolAccessOverrides.fromJson(json),
      messageAnyProject: json['messageAnyProject'] == true,
      projects: {
        if (projects is Map)
          for (final entry in projects.entries)
            if (entry.key is String)
              entry.key as String: McpToolAccessOverrides.fromJson(entry.value),
      }..removeWhere((_, overrides) => overrides.isEmpty),
    );
  }

  /// What is stored under [kMcpToolAccessKey]; null or unreadable is the
  /// defaults.
  factory McpToolAccessPolicy.parse(String? stored) {
    if (stored == null || stored.isEmpty) return defaults;
    try {
      return McpToolAccessPolicy.fromJson(jsonDecode(stored));
    } on FormatException {
      return defaults;
    }
  }

  Map<String, Object?> toJson() => {
    ...global.toJson(),
    if (messageAnyProject) 'messageAnyProject': true,
    if (projects.isNotEmpty)
      'projects': {
        for (final entry in projects.entries) entry.key: entry.value.toJson(),
      },
  };

  McpToolAccessOverrides project(String? projectId) => projectId == null
      ? McpToolAccessOverrides.none
      : projects[projectId] ?? McpToolAccessOverrides.none;

  /// Whether [tool] is on for a session in [projectId]: the project's tool
  /// override, its group override, the global tool override, the global group
  /// switch, then the group's default. A tool in no group is never on.
  bool toolOn(String tool, {String? projectId}) {
    final group = kMcpToolGroups[tool];
    if (group == null) return false;
    final here = project(projectId);
    return here.tool(tool) ??
        here.group(group) ??
        global.tool(tool) ??
        global.group(group) ??
        group.defaultOn;
  }

  /// [group]'s switch for [projectId], tool overrides aside; with no project
  /// the global switch.
  bool groupOn(McpToolGroup group, {String? projectId}) =>
      project(projectId).group(group) ?? global.group(group) ?? group.defaultOn;

  /// The groups at least one of whose tools is on for [projectId].
  List<McpToolGroup> groupsOpen({String? projectId}) => [
    for (final group in McpToolGroup.values)
      if (group.tools.any((tool) => toolOn(tool, projectId: projectId))) group,
  ];

  McpToolAccessPolicy withGlobal(McpToolAccessOverrides global) =>
      McpToolAccessPolicy(
        global: global,
        messageAnyProject: messageAnyProject,
        projects: projects,
      );

  McpToolAccessPolicy withMessageAnyProject(bool any) => McpToolAccessPolicy(
    global: global,
    messageAnyProject: any,
    projects: projects,
  );

  /// [projectId]'s overrides replaced; empty ones are dropped.
  McpToolAccessPolicy withProject(
    String projectId,
    McpToolAccessOverrides overrides,
  ) => McpToolAccessPolicy(
    global: global,
    messageAnyProject: messageAnyProject,
    projects: {
      for (final entry in projects.entries)
        if (entry.key != projectId) entry.key: entry.value,
      if (!overrides.isEmpty) projectId: overrides,
    },
  );

  @override
  bool operator ==(Object other) =>
      other is McpToolAccessPolicy &&
      other.global == global &&
      other.messageAnyProject == messageAnyProject &&
      other.projects.length == projects.length &&
      projects.entries.every((e) => other.projects[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
    global,
    messageAnyProject,
    Object.hashAllUnordered(
      projects.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

/// Why [tool], which [mcpToolNeedsOperatorGrant] says needs the grant, may not
/// run for [callerSessionId] without it, or null when [policy] lets it.
/// [projectOf] and [parentOf] answer for any session id, null when unknown.
String? mcpToolAccessRefusal(
  String tool,
  Map<String, dynamic> arguments,
  String callerSessionId, {
  required McpToolAccessPolicy policy,
  required String? Function(String sessionId) projectOf,
  required String? Function(String sessionId) parentOf,
}) {
  final group = kMcpToolGroups[tool];
  if (group == null) return mcpOperatorRefusal(tool);
  final projectId = projectOf(callerSessionId);
  if (!policy.toolOn(tool, projectId: projectId)) {
    return _groupOffRefusal(tool, group, inProject: projectId != null);
  }
  if (group == McpToolGroup.message && !policy.messageAnyProject) {
    final target = _target(arguments, callerSessionId);
    final near =
        target != null &&
        (target == callerSessionId ||
            parentOf(callerSessionId) == target ||
            parentOf(target) == callerSessionId ||
            (projectId != null && projectOf(target) == projectId));
    if (!near) return _scopeRefusal(tool, target);
  }
  return null;
}

/// The session a message tool is aimed at: blank or absent is the caller;
/// null when the id cannot be read.
String? _target(Map<String, dynamic> arguments, String caller) {
  final named = arguments['sessionId'];
  if (named == null) return caller;
  if (named is! String) return null;
  final id = named.trim();
  return id.isEmpty ? caller : id;
}

String _groupOffRefusal(
  String tool,
  McpToolGroup group, {
  required bool inProject,
}) =>
    '$tool is in the tool group "${group.label}", which is off for this '
    'session${inProject ? "'s project" : ''}. NOTHING WAS DONE. Ask the person '
    'to turn "${group.label}" on in $kMcpToolAccessLocation'
    '${inProject ? ' (or for this project, on its Details page)' : ''}, or '
    '$_grantTail';

String _scopeRefusal(String tool, String? target) =>
    '$tool may reach only sessions in this session\'s project, its parent and '
    'its children, and ${target ?? 'the sessionId given'} is '
    'none of those. NOTHING WAS DONE. Ask the person to turn on "Any project" '
    'under Message sessions in $kMcpToolAccessLocation, or $_grantTail';

const String _grantTail =
    'to turn on "Operate Karmashala" for this session (the session bar, or '
    'its Session sheet on a phone), or to start their next message with '
    '/operator. If another session started this one, it cannot grant this; '
    'only the person can. Without it you can still read Karmashala, use '
    'devices, the browser, builds, projects and terminals, act on your own '
    'session, and use the tool groups that are on.';

Map<String, bool> _flags(Object? json, bool Function(String) known) {
  if (json is! Map) return const {};
  return {
    for (final entry in json.entries)
      if (entry.key is String &&
          entry.value is bool &&
          known(entry.key as String))
        entry.key as String: entry.value as bool,
  };
}

Map<String, bool> _put(Map<String, bool> flags, String key, bool? on) => {
  for (final entry in flags.entries)
    if (entry.key != key) entry.key: entry.value,
  key: ?on,
};

bool _sameFlags(Map<String, bool> a, Map<String, bool> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
