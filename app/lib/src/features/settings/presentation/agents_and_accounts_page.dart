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
import 'agent_detection_section.dart';
import 'agent_label.dart';
import 'agent_path_section.dart';
import 'agents_pages.dart';
import 'permissions_page.dart' show PermissionAxisDropdown;
import 'settings_catalog.dart';
import 'settings_notice.dart';
import 'settings_page_body.dart' show SettingsAnchorTarget;
import 'settings_row.dart';
import 'settings_section.dart';
import 'usage_tokens_card.dart';

part 'agents_and_accounts_page/machines.dart';
part 'agents_and_accounts_page/accounts.dart';
part 'agents_and_accounts_page/account_stores.dart';

/// **Settings → Agents and accounts, as the approved board draws it** (N5,
/// spec §6). The page models the truth: an agent is installed *per machine*,
/// each install is signed in to *one account*, and usage belongs to the
/// account — so two machines on one account share its limits.
///
/// It opens with *Defaults*, then one block per agent — its *machines* (a row
/// per install: version, update flag, the account it is on), its *accounts*
/// (plan, the machines on it, a bar per usage window) and its *behaviour*
/// (default model, permission mode, sandbox where the agent has one) — and
/// ends with usage, updates, executables and detection.
///
/// Lays out its own anchors, since an agent's block holds what the catalogue
/// files as separate sections: Claude's accounts, Codex's accounts and the
/// default model all live inside the blocks.
class AgentsAndAccountsBody extends ConsumerWidget {
  const AgentsAndAccountsBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(agentRegistryProvider);
    final installations = ref.watch(agentInstallationsControllerProvider);
    // An agent gets a block when it is installed somewhere, has accounts this
    // app can save, or has models to default to — the three things a block
    // says. Registry order, so the page does not reshuffle as installs come
    // and go.
    final agents = [
      for (final descriptor in registry.descriptors)
        if (installations.any((i) => i.agentId == descriptor.id) ||
            _AccountStore.of(registry.adapterFor(descriptor.id)) != null ||
            descriptor.launch.model.isKnown)
          descriptor.id,
    ];
    String? firstWith(bool Function(AgentAccounts? accounts) test) => agents
        .where((id) => test(registry.adapterFor(id)?.accounts))
        .firstOrNull;
    final claude = firstWith((a) => a is AnthropicOAuthAccounts);
    final codex = firstWith((a) => a is OpenAiAuthFileAccounts);
    // The default model anchor lands on the first agent's behaviour, which is
    // where "Default model" is now the first row.
    final behaviourAnchorOn = claude ?? agents.firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsAnchorTarget(
          anchor: SettingsAnchor.defaultAgent,
          child: DefaultAgentSection(),
        ),
        for (final agentId in agents)
          _anchored(
            agentId == claude
                ? SettingsAnchor.claudeAccounts
                : agentId == codex
                ? SettingsAnchor.codexAccounts
                : null,
            AgentBlock(
              agentId: agentId,
              behaviourAnchor: agentId == behaviourAnchorOn
                  ? SettingsAnchor.defaultModel
                  : null,
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
        const SettingsAnchorTarget(
          anchor: SettingsAnchor.usage,
          child: UsageAndLimitsSection(),
        ),
        const SettingsAnchorTarget(
          anchor: SettingsAnchor.agentUpdates,
          child: AgentUpdatesSection(),
        ),
        const SettingsAnchorTarget(
          anchor: SettingsAnchor.executables,
          child: AgentPathSection(),
        ),
        const SettingsAnchorTarget(
          anchor: SettingsAnchor.detection,
          child: AgentDetectionSection(),
        ),
      ],
    );
  }

  static Widget _anchored(SettingsAnchor? anchor, Widget child) =>
      anchor == null
      ? child
      : SettingsAnchorTarget(anchor: anchor, child: child);
}

/// **One agent's block**: its machines, its accounts, its behaviour — three
/// sections headed "Claude Code · machines" and so on, as the board heads
/// them. Holds the busy flag its account actions share, so a capture on one
/// row disables the switch on another instead of racing it.
class AgentBlock extends ConsumerStatefulWidget {
  const AgentBlock({required this.agentId, this.behaviourAnchor, super.key});

  final String agentId;

  /// The anchor the behaviour section answers to, when a deep link lands
  /// there (the default model's).
  final SettingsAnchor? behaviourAnchor;

  @override
  ConsumerState<AgentBlock> createState() => _AgentBlockState();
}

class _AgentBlockState extends ConsumerState<AgentBlock> {
  bool _busy = false;

  /// Runs one account action with the block marked busy, and says how it went
  /// in a snackbar — the vendor's own words when it refused.
  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    var message = done;
    var failed = false;
    try {
      await action();
    } on ClaudeAuthException catch (e) {
      (message, failed) = (e.message, true);
    } on CodexAuthException catch (e) {
      (message, failed) = (e.message, true);
    } on UsageException catch (e) {
      (message, failed) = (e.message, true);
    } catch (e) {
      (message, failed) = ('Unexpected error: $e', true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final theme = Theme.of(context);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: failed ? theme.colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final agentId = widget.agentId;
    final registry = ref.watch(agentRegistryProvider);
    final adapter = registry.adapterFor(agentId);
    final store = _AccountStore.of(adapter);
    final name = agentLabel(agentId);
    final installs = [
      for (final install in ref.watch(agentInstallationsControllerProvider))
        if (install.agentId == agentId) install,
    ];
    final usageAccounts = [
      for (final account in ref.watch(usageAccountsProvider))
        if (account.agentId == agentId) account,
    ];
    final descriptor = adapter?.descriptor;
    final behaviour = descriptor == null
        ? null
        : SettingsSection(
            title: '$name · behaviour'.toUpperCase(),
            child: _AgentBehaviour(descriptor: descriptor),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: '$name · machines'.toUpperCase(),
          child: _Machines(
            agentId: agentId,
            installs: installs,
            store: store,
            usageAccounts: usageAccounts,
            busy: _busy,
            run: _run,
          ),
        ),
        if (store != null || usageAccounts.isNotEmpty)
          SettingsSection(
            title: '$name · accounts'.toUpperCase(),
            child: _Accounts(
              agentId: agentId,
              installs: installs,
              store: store,
              usageAccounts: usageAccounts,
              busy: _busy,
              run: _run,
            ),
          ),
        if (behaviour != null)
          if (widget.behaviourAnchor case final anchor?)
            SettingsAnchorTarget(anchor: anchor, child: behaviour)
          else
            behaviour,
      ],
    );
  }
}

typedef _Run =
    Future<void> Function(Future<void> Function() action, String done);

/// **How the agent behaves** (board "· behaviour"): the model a new session
/// starts on and the permission mode it starts in — each axis the agent has,
/// so Codex's sandbox is its own row. Defaults only: a session that picks its
/// own keeps it. Existing sessions' modes stay on Tools and reach.
class _AgentBehaviour extends ConsumerWidget {
  const _AgentBehaviour({required this.descriptor});

  final AgentDescriptor descriptor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final id = descriptor.id;
    final support = descriptor.launch.permission;
    final selection = support.resolveStored(
      settings.permissionsFor(id).newSessions,
    );
    final modelKnown = descriptor.launch.model.isKnown;
    final blocked = modelKnown ? modelNotSettableReason(descriptor) : null;
    final selected = settings.defaultModelFor(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (modelKnown)
          SettingsRow(
            label: 'Default model',
            help:
                'Where a new session starts; one that picks its own keeps it.',
            stackedFit: SettingsControlFit.start,
            control: ModelPicker(
              options: modelOptionsFor(
                descriptor,
                current: selected,
                support: ref.watch(agentModelSupportProvider(id)),
              ),
              selected: selected,
              onChanged: (choice) =>
                  controller.setDefaultModel(id, choice.modelId),
            ),
          ),
        if (blocked != null)
          SettingsNote(
            'This agent cannot be told a model.',
            child: SettingsNotice(
              tone: SettingsNoticeTone.danger,
              message: blocked,
            ),
          ),
        if (!support.isKnown)
          SettingsNote(unknownAgentReason(descriptor.displayName))
        else
          for (final (index, axis) in permissionAxisOptionsFor(
            descriptor,
            selection: selection,
          ).indexed)
            SettingsRow(
              label: axis.label,
              help: index == 0
                  ? 'For new sessions. Existing ones are set under Tools and '
                        'reach.'
                  : null,
              controlMaxWidth: 240,
              control: PermissionAxisDropdown(
                axis: axis,
                selection: selection,
                support: support,
                labelled: false,
                onChanged: (mode) =>
                    controller.setNewSessionPermission(id, mode),
              ),
            ),
        if (support.isKnown && support.isDangerous(selection))
          SettingsNote(
            'New ${descriptor.displayName} sessions act with nothing in the '
            'way. Use it only in trusted repositories.',
          ),
      ],
    );
  }
}

/// **Usage & limits**, after every agent's accounts: what the numbers mean, the
/// Usage tab for their history, and the token count across recent sessions.
class UsageAndLimitsSection extends ConsumerWidget {
  const UsageAndLimitsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSection(
      title: SettingsAnchor.usage.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'Usage belongs to the account, so machines signed in to one share '
            'its limits. The server reads each account on its own schedule; '
            'every agent’s accounts above show the latest reading.',
          ),
          SettingsRow(
            label: 'Usage over time',
            help:
                'Every account’s windows, their history, and what spent them.',
            control: OutlinedButton(
              onPressed: () {
                final phoneUsage = phoneUsagePageOpener(context, ref);
                if (phoneUsage != null) {
                  phoneUsage();
                } else {
                  openUsageTab(ref);
                }
              },
              child: const Text('Open Usage tab'),
            ),
          ),
          const UsageTokensCard(),
        ],
      ),
    );
  }
}

/// "A, B and C".
String _list(List<String> items) => switch (items.length) {
  0 => '',
  1 => items.single,
  _ => '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}',
};
