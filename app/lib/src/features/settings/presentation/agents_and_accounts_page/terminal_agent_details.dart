part of '../agents_and_accounts_page.dart';

/// **What a terminal agent's card opens to**: its machines, its executables,
/// its accounts and its behaviour — four sections headed "Claude Code ·
/// machines" and so on, as the board heads them. Holds the busy flag its
/// account actions share, so a capture on one row disables the switch on
/// another instead of racing it.
class TerminalAgentDetails extends ConsumerStatefulWidget {
  const TerminalAgentDetails({required this.agentId, super.key});

  final String agentId;

  @override
  ConsumerState<TerminalAgentDetails> createState() =>
      _TerminalAgentDetailsState();
}

class _TerminalAgentDetailsState extends ConsumerState<TerminalAgentDetails> {
  bool _busy = false;

  /// Runs one account action with the card marked busy, and says how it went
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
    } on AccountSwitchFailed catch (e) {
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
    final name = agentLabel(ref, agentId);
    final installs = [
      for (final install in ref.watch(agentInstallationsControllerProvider))
        if (install.agentId == agentId) install,
    ];
    final usageAccounts = [
      for (final account in ref.watch(usageAccountsProvider))
        if (account.agentId == agentId) account,
    ];
    final descriptor = adapter?.descriptor;
    final chat = registry.byId(registry.formsOf(agentId).chatId ?? '');
    final chatInstalls = [
      for (final install in ref.watch(agentInstallationsControllerProvider))
        if (install.agentId == chat?.id) install,
    ];
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
        if (installs.isNotEmpty)
          SettingsSection(
            title: '$name · ${SettingsAnchor.executables.title}'.toUpperCase(),
            child: AgentExecutableRows(installations: installs),
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
        if (chat != null)
          SettingsSection(
            title: '$name · chat'.toUpperCase(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SettingsNote(acpAgentsNote),
                // In the ACP row's own help style, as it reads on that row.
                DefaultTextStyle.merge(
                  style: SettingsStyles.rowHelp(context),
                  child: AcpAgentDetails(
                    descriptor: chat,
                    installs: chatInstalls,
                  ),
                ),
              ],
            ),
          ),
        if (descriptor != null)
          SettingsSection(
            title: '$name · behaviour'.toUpperCase(),
            child: _AgentBehaviour(
              descriptor: descriptor,
              hasChatForm: chat != null,
            ),
          ),
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
  const _AgentBehaviour({required this.descriptor, required this.hasChatForm});

  final AgentDescriptor descriptor;

  /// Whether the agent can also run as a chat, so new sessions get a choice.
  final bool hasChatForm;

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
        if (hasChatForm)
          SettingsRow(
            label: 'New sessions run as',
            help:
                'Also chosen on each New Session card; a session keeps the '
                'form it started in.',
            stackedFit: SettingsControlFit.start,
            control: SegmentedButton<AgentRunForm>(
              key: ValueKey('run-form:$id'),
              showSelectedIcon: false,
              segments: [
                for (final form in AgentRunForm.values)
                  ButtonSegment(value: form, label: Text(form.label)),
              ],
              selected: {settings.runFormFor(id)},
              onSelectionChanged: (picked) =>
                  controller.setAgentRunForm(id, picked.first),
            ),
          ),
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
