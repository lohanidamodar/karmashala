import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_more_page.dart' show phoneUsagePageOpener;
import '../../../app/shell/workbench_tabs.dart' show openUsageTab;
import '../../../core/util/clock_provider.dart';
import '../../agents/application/acp_agent_providers.dart'
    show userAcpAgentIdsProvider;
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_latest_versions_controller.dart';
import '../../agents/application/agent_model_catalog_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_redetect_controller.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/application/claude_accounts_controller.dart';
import '../../agents/application/codex_accounts_controller.dart';
import '../../agents/application/usage_accounts.dart';
import '../../agents/presentation/model_picker.dart';
import '../../agents/presentation/usage_tab/usage_tab_state.dart'
    show usageAccountId;
import '../../environments/application/environments_controller.dart';
import '../application/settings_controller.dart';
import 'acp_agents_section.dart';
import 'acp_builtin_agent_row.dart';
import 'agent_detection_section.dart';
import 'agent_health.dart' show newestAgentVersion;
import 'agent_label.dart';
import 'agent_mcp_entry_section.dart';
import 'agent_path_section.dart' show AgentExecutableRows;
import 'agents_group_section.dart';
import 'agents_header_strip.dart';
import 'agents_pages.dart' show AgentUpdatesSection, ChildReportSection;
import 'permissions_page.dart' show PermissionAxisDropdown;
import 'settings_catalog.dart';
import 'settings_notice.dart';
import 'settings_page_body.dart' show SettingsAnchorTarget;
import 'settings_row.dart';
import 'settings_theme.dart' show SettingsStyles;
import 'settings_section.dart';
import 'terminal_agent_card.dart';
import 'usage_and_limits_section.dart';

part 'agents_and_accounts_page/machines.dart';
part 'agents_and_accounts_page/accounts.dart';
part 'agents_and_accounts_page/account_stores.dart';
part 'agents_and_accounts_page/terminal_agent_details.dart';

/// **Settings → Agents and accounts**: a header strip — how many agents, how
/// many installed on how many machines, Discover, the default agent — then
/// three groups of agents and a fourth of what spans them.
///
/// Grouped by capability, never by id, and one entry per agent
/// (`AgentRegistry.folded`): an agent with a terminal form is a card that
/// opens to its machines, executables, accounts, its chat form when it has
/// one, and behaviour; a shipped agent with only a chat form is one line,
/// because none of those apply to it; a row's agent is in
/// `userAcpAgentIdsProvider`.
///
/// Lays out its own anchors: the account and default-model anchors wrap the
/// card they belong to, and open it when a link lands there.
class AgentsAndAccountsBody extends ConsumerWidget {
  const AgentsAndAccountsBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(agentRegistryProvider);
    final installations = ref.watch(agentInstallationsControllerProvider);
    final userAcp = ref.watch(userAcpAgentIdsProvider);
    final terminal = <AgentDescriptor>[];
    final builtInAcp = <AgentDescriptor>[];
    for (final forms in registry.folded) {
      final terminalId = forms.terminalId;
      if (terminalId != null) {
        terminal.add(registry.byId(terminalId)!);
      } else if (!userAcp.contains(forms.agentId)) {
        builtInAcp.add(registry.byId(forms.agentId)!);
      }
    }
    List<AgentInstallation> installsOf(String id) => [
      for (final install in installations)
        if (install.agentId == id) install,
    ];
    String? firstWith(bool Function(AgentAccounts? accounts) test) => terminal
        .map((d) => d.id)
        .where((id) => test(registry.adapterFor(id)?.accounts))
        .firstOrNull;
    final claude = firstWith((a) => a is AnthropicOAuthAccounts);
    final codex = firstWith((a) => a is OpenAiAuthFileAccounts);
    // The default model anchor lands on the first agent's card, where
    // "Default model" is the first behaviour row.
    final behaviourAnchorOn = claude ?? terminal.firstOrNull?.id;
    Set<SettingsAnchor> anchorsFor(String id) => {
      if (id == claude) SettingsAnchor.claudeAccounts,
      if (id == codex) SettingsAnchor.codexAccounts,
      if (id == behaviourAnchorOn) SettingsAnchor.defaultModel,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsAnchorTarget(
          anchor: SettingsAnchor.defaultAgent,
          child: AgentsHeaderStrip(),
        ),
        // The executables anchor lands on this group: each card holds its own
        // agent's paths, and the row's glyph says which one needs looking at.
        SettingsAnchorTarget(
          anchor: SettingsAnchor.executables,
          child: AgentsGroupSection(
            title: 'Agents',
            count: terminal.length,
            anchors: const {
              SettingsAnchor.executables,
              SettingsAnchor.claudeAccounts,
              SettingsAnchor.codexAccounts,
              SettingsAnchor.defaultModel,
            },
            children: [
              for (final descriptor in terminal)
                _anchored(
                  anchorsFor(descriptor.id),
                  TerminalAgentCard(
                    descriptor: descriptor,
                    installs: installsOf(descriptor.id),
                    chatInstalls: [
                      if (registry.formsOf(descriptor.id).chatId case final id?)
                        ...installsOf(id),
                    ],
                    anchors: anchorsFor(descriptor.id),
                    body: TerminalAgentDetails(agentId: descriptor.id),
                  ),
                ),
            ],
          ),
        ),
        // Every anchor is somewhere, even on a registry without the agent it
        // was named for: a deep link must land on the page, not throw.
        if (claude == null)
          const SettingsAnchorTarget(
            anchor: SettingsAnchor.claudeAccounts,
            child: SizedBox.shrink(),
          ),
        if (codex == null)
          const SettingsAnchorTarget(
            anchor: SettingsAnchor.codexAccounts,
            child: SizedBox.shrink(),
          ),
        if (behaviourAnchorOn == null)
          const SettingsAnchorTarget(
            anchor: SettingsAnchor.defaultModel,
            child: SizedBox.shrink(),
          ),
        if (builtInAcp.isNotEmpty)
          AgentsGroupSection(
            title: 'ACP agents (built-in)',
            count: builtInAcp.length,
            children: [
              const SettingsNote(acpAgentsNote),
              for (final descriptor in builtInAcp)
                AcpBuiltInAgentRow(
                  descriptor: descriptor,
                  installs: installsOf(descriptor.id),
                ),
            ],
          ),
        const AcpAgentsSection(),
        const AgentsGroupSection(
          title: 'Usage and maintenance',
          anchors: {
            SettingsAnchor.usage,
            SettingsAnchor.agentUpdates,
            SettingsAnchor.detection,
          },
          children: [
            SettingsAnchorTarget(
              anchor: SettingsAnchor.usage,
              child: UsageAndLimitsSection(),
            ),
            SettingsAnchorTarget(
              anchor: SettingsAnchor.agentUpdates,
              child: AgentUpdatesSection(),
            ),
            AgentMcpEntrySection(),
            ChildReportSection(),
            SettingsAnchorTarget(
              anchor: SettingsAnchor.detection,
              child: AgentDetectionSection(),
            ),
          ],
        ),
      ],
    );
  }

  /// [child] under each of [anchors], so a link to any of them lands on it.
  static Widget _anchored(Set<SettingsAnchor> anchors, Widget child) {
    var result = child;
    for (final anchor in anchors) {
      result = SettingsAnchorTarget(anchor: anchor, child: result);
    }
    return result;
  }
}

/// "A, B and C".
String _list(List<String> items) => switch (items.length) {
  0 => '',
  1 => items.single,
  _ => '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}',
};
