import '../adapter/agent_adapter.dart';
import '../adapter/built_in_agent_adapters.dart';
import './agent_descriptor.dart';
import './agent_forms.dart';
import './agent_installation.dart';

/// The set of agents the app knows about, in probe/display order.
///
/// A registry of **adapters**: everything agent-specific is reached through
/// one, so a new agent is a new `AgentAdapter` registered here rather than a
/// code change in each place that used to ask who the agent was.
class AgentRegistry {
  const AgentRegistry(this.adapters);

  /// The agents shipped with the app.
  static const AgentRegistry builtIn = AgentRegistry(builtInAgentAdapters);

  /// The shipped agents plus [extra] — the person-added ACP agents a server
  /// keeps as rows. On a repeated id the later adapter wins, in the earlier
  /// one's place; [builtIn] itself is untouched.
  static AgentRegistry withExtra(Iterable<AgentAdapter> extra) {
    final byId = <String, AgentAdapter>{};
    for (final adapter in builtInAgentAdapters.followedBy(extra)) {
      byId[adapter.id] = adapter;
    }
    return AgentRegistry(List.unmodifiable(byId.values));
  }

  final List<AgentAdapter> adapters;

  /// Each adapter's descriptor, in registry order.
  List<AgentDescriptor> get descriptors => [
    for (final adapter in adapters) adapter.descriptor,
  ];

  AgentAdapter? adapterFor(String id) {
    for (final adapter in adapters) {
      if (adapter.id == id) return adapter;
    }
    return null;
  }

  AgentDescriptor? byId(String id) => adapterFor(id)?.descriptor;

  /// A human-readable name for [id], falling back to the raw id for an agent
  /// this registry has never heard of (e.g. a stored installation whose
  /// descriptor was removed).
  String displayNameFor(String id) => byId(id)?.displayName ?? id;

  /// Whether [id] runs as a chat (spoken to over a protocol) or in a terminal.
  AgentRunForm formOf(String id) =>
      byId(id)?.acp != null ? AgentRunForm.chat : AgentRunForm.terminal;

  /// The terminal agent [id] is the chat form of, when this registry has it;
  /// else [id] itself.
  String foldedIdOf(String id) {
    final terminal = byId(id)?.chatFormOf;
    return terminal != null && byId(terminal) != null ? terminal : id;
  }

  /// The forms of the agent [id] belongs to, whichever form [id] names. An
  /// id this registry does not know has none.
  AgentForms formsOf(String id) {
    final agentId = foldedIdOf(id);
    final own = byId(agentId);
    if (own == null) return AgentForms(agentId: agentId, displayName: id);
    String? chat;
    if (own.acp != null) {
      chat = agentId;
    } else {
      for (final d in descriptors) {
        if (d.chatFormOf == agentId && d.acp != null) {
          chat = d.id;
          break;
        }
      }
    }
    return AgentForms(
      agentId: agentId,
      displayName: own.displayName,
      terminalId: own.acp == null ? agentId : null,
      chatId: chat,
    );
  }

  /// The display name of the agent [id] is a form of.
  String foldedNameOf(String id) => formsOf(id).displayName;

  /// What a session on [id] is called: a paired agent's chat form is the
  /// agent marked as chat ("Claude Code · Chat"); anything else, its own name,
  /// so the terminal form reads as it always has.
  String formLabelOf(String id) {
    final forms = formsOf(id);
    if (!forms.hasBoth || id != forms.chatId) return displayNameFor(id);
    return '${forms.displayName} · ${AgentRunForm.chat.label}';
  }

  /// The other forms of [id]'s agent that run the same binary as [id] — one
  /// program spoken to two ways — so a path pinned for one is the other's.
  List<String> sameProgramFormsOf(String id) {
    final own = byId(id);
    if (own == null) return const [];
    final agentId = foldedIdOf(id);
    bool same(List<String> a, List<String> b) =>
        a.join('\u0000') == b.join('\u0000');
    return [
      for (final d in descriptors)
        if (d.id != id &&
            (d.id == agentId || d.chatFormOf == agentId) &&
            foldedIdOf(d.id) == agentId &&
            same(d.binaries.windows, own.binaries.windows) &&
            same(d.binaries.posix, own.binaries.posix))
          d.id,
    ];
  }

  /// [installation]'s agent installed as [form] on the same machine, among
  /// [installations]; null when that form is not installed there.
  AgentInstallation? inForm(
    AgentInstallation installation,
    Iterable<AgentInstallation> installations,
    AgentRunForm form,
  ) {
    final id = formsOf(installation.agentId).idFor(form);
    if (id == null) return null;
    if (id == installation.agentId) return installation;
    return installations
        .where(
          (i) =>
              i.agentId == id && i.environmentId == installation.environmentId,
        )
        .firstOrNull;
  }

  /// Every agent once, its forms folded together, in registry order.
  List<AgentForms> get folded => [
    for (final adapter in adapters)
      if (foldedIdOf(adapter.id) == adapter.id) formsOf(adapter.id),
  ];
}
