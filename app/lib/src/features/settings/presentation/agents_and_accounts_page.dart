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

/// **A machine per row** (board "· machines"): where the agent is installed,
/// its version with a flag when it is behind the agent's latest release (or
/// another machine's version), and the account that install is signed in to —
/// a pill that switches it, or **Capture** when the sign-in is an account not
/// saved yet. Then the latest release itself, when the agent declares where
/// to read it.
class _Machines extends ConsumerWidget {
  const _Machines({
    required this.agentId,
    required this.installs,
    required this.store,
    required this.usageAccounts,
    required this.busy,
    required this.run,
  });

  final String agentId;
  final List<AgentInstallation> installs;
  final _AccountStore? store;
  final List<UsageAccount> usageAccounts;
  final bool busy;
  final _Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = this.store;
    final saved = store?.saved(ref) ?? const <_Saved>[];
    // Read now, in build: the Apply menu's callback runs after it and may not
    // watch anything.
    final savedIdOf = {
      if (store != null)
        for (final install in installs)
          install.id: store.signIn(ref, install).asData?.value.savedId,
    };
    final newest = _newestVersion(installs);
    final latest = ref.watch(agentLatestVersionsProvider).latestOf(agentId);
    final latestSource = ref
        .watch(agentRegistryProvider)
        .byId(agentId)
        ?.launch
        .selfUpdate
        .latestVersion;
    final environments = ref.watch(environmentsControllerProvider);
    final missing = [
      for (final environment in environments)
        if (!installs.any((i) => i.environmentId == environment.id))
          ref.watch(environmentLabelForIdProvider(environment.id)),
    ];
    final redetect = ref.watch(agentRedetectControllerProvider);
    final rescan = OutlinedButton(
      onPressed: redetect.busy
          ? null
          : () => ref.read(agentRedetectControllerProvider.notifier).redetect(),
      child: Text(redetect.busy ? 'Scanning…' : 'Rescan'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final install in installs)
          _MachineRow(
            install: install,
            store: store,
            saved: saved,
            updateTo: agentUpdateTarget(
              install,
              latest: latest,
              newestOnMachines: newest,
            ),
            usage: usageAccounts
                .where((a) => a.environmentIds.contains(install.environmentId))
                .firstOrNull,
            busy: busy,
            run: run,
          ),
        if (installs.isNotEmpty && (latestSource?.isKnown ?? false))
          _LatestRelease(
            agentId: agentId,
            source: latestSource!,
            anyBehind: installs.any(
              (install) =>
                  agentUpdateTarget(
                    install,
                    latest: latest,
                    newestOnMachines: newest,
                  ) !=
                  null,
            ),
          ),
        if (installs.isEmpty)
          SettingsRow(
            label: 'Not installed on any machine',
            help: 'Install it, then rescan to find it.',
            control: rescan,
          )
        else if (missing.isNotEmpty)
          SettingsRow(
            label: 'Not installed on ${_list(missing)}',
            help: 'Rescan after installing it there.',
            control: rescan,
          ),
        if (store != null && installs.length > 1 && saved.isNotEmpty)
          Builder(
            builder: (anchor) => SettingsRow(
              label: 'Use one account on every machine',
              help: 'Signs each machine in to the account you pick.',
              control: OutlinedButton(
                onPressed: busy
                    ? null
                    : () async {
                        final picked =
                            await showDesktopMenuUnder<_Saved>(anchor, [
                              for (final account in saved)
                                DesktopMenuItem(
                                  value: account,
                                  label: account.describe,
                                  icon: AppIcons.userCircle,
                                ),
                            ]);
                        if (picked == null) return;
                        await run(() async {
                          for (final install in installs) {
                            if (savedIdOf[install.id] == picked.id) continue;
                            await store.switchTo(ref, install, picked);
                          }
                        }, 'Every machine is on ${picked.title}.');
                      },
                child: const Text('Apply…'),
              ),
            ),
          ),
      ],
    );
  }
}

class _MachineRow extends ConsumerWidget {
  const _MachineRow({
    required this.install,
    required this.store,
    required this.saved,
    required this.updateTo,
    required this.usage,
    required this.busy,
    required this.run,
  });

  final AgentInstallation install;
  final _AccountStore? store;
  final List<_Saved> saved;

  /// The version this install is behind — the agent's latest release or
  /// another machine's, whichever is newer — or null when it is current.
  final String? updateTo;

  /// The usage account this machine's reading belongs to, for an agent whose
  /// accounts this app does not save.
  final UsageAccount? usage;
  final bool busy;
  final _Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final environment = ref.watch(
      environmentLabelForIdProvider(install.environmentId),
    );
    // These CLIs self-update, so the number never appears without its age.
    final version = describeVersionReading(
      install,
      now: ref.watch(clockProvider).nowUtc(),
    );
    final updateTo = this.updateTo;
    final store = this.store;
    final signIn = store?.signIn(ref, install);
    final current = signIn?.asData?.value;
    final unsaved =
        current != null && current.signedIn && current.savedId == null
        ? current
        : null;
    final help = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: version ?? 'version not read'),
          if (updateTo != null)
            // Words as well as the colour: the flag must read without it.
            TextSpan(
              text: ' · update to $updateTo',
              style: TextStyle(color: semantic.attention),
            ),
          if (unsaved != null)
            TextSpan(
              text:
                  ' · signed in as ${unsaved.email ?? 'an account'}, not saved '
                  'yet',
            ),
        ],
      ),
    );
    final Widget control;
    if (store == null) {
      // No account store for this agent: the account is whatever its usage
      // reading says, and there is nothing to switch it to.
      control = SettingsValue(
        label: usage?.email ?? 'Account not read yet',
        tooltip: 'Who this install is signed in as, from its usage reading',
      );
    } else {
      control = Builder(
        builder: (anchor) => switch (signIn!) {
          AsyncValue(:final error?) => SettingsValue(
            label: 'Could not read',
            tooltip: '$error',
            onTap: () => store.reread(ref, install),
          ),
          AsyncValue(value: final s?) when s.signedIn && s.savedId == null =>
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => run(
                      () => store.capture(ref, install),
                      'Captured the account signed in on $environment.',
                    ),
              child: const Text('Capture'),
            ),
          AsyncValue(value: final s?) => SettingsValue(
            label: s.signedIn ? s.describe : 'Not signed in',
            tooltip: s.signedIn
                ? 'Switch $environment to another saved account'
                : 'Sign in by running the agent on this machine, or switch it '
                      'to a saved account',
            onTap: busy
                ? null
                : () => _pickAccount(anchor, ref, store, s, environment),
          ),
          _ => const SettingsValue(label: 'Reading…'),
        },
      );
    }
    return SettingsRow(
      label: environment,
      helpWidget: help,
      controlMaxWidth: 260,
      stackedFit: SettingsControlFit.start,
      leading: Icon(
        AppIcons.terminalWindow,
        size: Chrome.iconSmall,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      control: control,
    );
  }

  /// The account dropdown of a machine row: every saved account (the one in
  /// force checked), and re-reading the sign-in, which is how a login done in
  /// a terminal shows up here.
  Future<void> _pickAccount(
    BuildContext anchor,
    WidgetRef ref,
    _AccountStore store,
    _SignIn current,
    String environment,
  ) async {
    const reread = _Saved.reread;
    final picked = await showDesktopMenuUnder<_Saved>(anchor, [
      for (final account in saved)
        DesktopMenuItem(
          value: account,
          label: account.describe,
          icon: AppIcons.userCircle,
          selected: account.id == current.savedId,
          enabled: account.id != current.savedId,
        ),
      if (saved.isNotEmpty) const DesktopMenuDivider(),
      DesktopMenuItem(
        value: reread,
        label: 'Re-read the sign-in',
        icon: AppIcons.arrowsClockwise,
      ),
    ]);
    if (picked == null) return;
    if (identical(picked, reread)) {
      store.reread(ref, install);
      return;
    }
    await run(
      () => store.switchTo(ref, install, picked),
      'Switched $environment to ${picked.title}.',
    );
  }
}

/// **The agent's accounts** (board "· accounts"): each with its plan and the
/// machines signed in to it, then a bar per usage window. Capture saves the
/// sign-in on a machine as an account any machine can switch to.
class _Accounts extends ConsumerWidget {
  const _Accounts({
    required this.agentId,
    required this.installs,
    required this.store,
    required this.usageAccounts,
    required this.busy,
    required this.run,
  });

  final String agentId;
  final List<AgentInstallation> installs;
  final _AccountStore? store;
  final List<UsageAccount> usageAccounts;
  final bool busy;
  final _Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = this.store;
    final saved = store?.saved(ref) ?? const <_Saved>[];
    final now = ref.watch(clockProvider).nowUtc();
    // Every label watched here, in build: the Capture menu's callback reads
    // them after build is over, where watching is not allowed.
    final labels = <String, String>{
      for (final id in {
        for (final install in installs) install.environmentId,
        for (final usage in usageAccounts) ...usage.environmentIds,
      })
        id: ref.watch(environmentLabelForIdProvider(id)),
    };
    String label(String environmentId) =>
        labels[environmentId] ?? environmentId;
    UsageAccount? usageFor(String? email) => email == null
        ? null
        : usageAccounts
              .where((a) => a.email?.toLowerCase() == email.toLowerCase())
              .firstOrNull;
    final entries = <Widget>[];
    for (final account in saved) {
      final on = [
        for (final install in installs)
          if (store!.signIn(ref, install).asData?.value.savedId == account.id)
            label(install.environmentId),
      ];
      entries.add(
        _AccountEntry(
          title: account.describe,
          where: on.isEmpty
              ? 'Saved · not signed in on any machine'
              : 'On ${_list(on)}',
          usage: usageFor(account.email),
          now: now,
          onForget: () => run(
            () => store!.forget(ref, account),
            'Forgot ${account.title}.',
          ),
          busy: busy,
          run: run,
        ),
      );
    }
    // Readings for an account nobody saved: signed in somewhere, so it has
    // limits worth seeing, but it is not in the pool yet.
    for (final usage in usageAccounts) {
      if (saved.any((s) => s.email != null && usageFor(s.email) == usage)) {
        continue;
      }
      final where =
          'On ${_list([for (final id in usage.environmentIds) label(id)])}';
      entries.add(
        _AccountEntry(
          title: usage.email ?? 'Signed-in account',
          where: store == null ? where : '$where · not saved yet',
          usage: usage,
          now: now,
          busy: busy,
          run: run,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (entries.isEmpty)
          SettingsNote(
            store == null
                ? 'No account read yet. The server reads it once a session '
                      'on this agent runs.'
                : 'No account saved yet. Capture the sign-in on a machine to '
                      'save it.',
          ),
        ...entries,
        if (store != null) ...[
          Builder(
            builder: (anchor) => SettingsRow(
              label: 'Capture the sign-in on a machine',
              help:
                  'Saves who is signed in there as an account, so any machine '
                  'can switch to it later.',
              control: OutlinedButton(
                onPressed: busy || installs.isEmpty
                    ? null
                    : () async {
                        final install = installs.length == 1
                            ? installs.single
                            : await showDesktopMenuUnder<AgentInstallation>(
                                anchor,
                                [
                                  for (final install in installs)
                                    DesktopMenuItem(
                                      value: install,
                                      label: label(install.environmentId),
                                      icon: AppIcons.terminalWindow,
                                    ),
                                ],
                              );
                        if (install == null) return;
                        await run(
                          () => store.capture(ref, install),
                          'Captured the account signed in on '
                          '${label(install.environmentId)}.',
                        );
                      },
                child: const Text('Capture…'),
              ),
            ),
          ),
          // No sign-in flow of its own yet: the agent's login is the way in,
          // and the capture above is how it lands here.
          SettingsRow(
            label: 'Add an account',
            help:
                'Sign in once through the agent on a machine, then capture it '
                'above.',
            control: const SizedBox.shrink(),
          ),
        ],
      ],
    );
  }
}

/// One account (board: "personal · Max plan", "On Windows and WSL", Manage),
/// then its windows as usage rows, and why there is no fresh number when there
/// is not.
class _AccountEntry extends ConsumerWidget {
  const _AccountEntry({
    required this.title,
    required this.where,
    required this.usage,
    required this.now,
    required this.busy,
    required this.run,
    this.onForget,
  });

  final String title;
  final String where;
  final UsageAccount? usage;
  final DateTime now;
  final bool busy;
  final _Run run;

  /// Null for an account that is not saved: there is nothing to forget.
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = this.usage;
    final reading = usage?.latest.usage;
    final failure = usage?.latest.failure?.toException(now);
    // The age, always: a reading that is not live must not look live.
    final checked = reading == null
        ? null
        : 'checked ${describeAge(now.difference(reading.fetchedAt))}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Builder(
          builder: (anchor) => SettingsRow(
            label: title,
            help: [where, ?checked].join(' · '),
            leading: Icon(
              AppIcons.userCircle,
              size: Chrome.iconSmall,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            control: SettingsValue(
              label: 'Manage',
              onTap: busy ? null : () => _manage(anchor, ref),
            ),
          ),
        ),
        if (reading != null)
          for (final window in reading.windows)
            SettingsUsageRow(label: window.label, percent: window.percent),
        if (failure != null)
          SettingsNote(
            usageFailureHeadline(failure.kind),
            child: SettingsNotice(
              tone: switch (failure.kind) {
                UsageFailureKind.auth ||
                UsageFailureKind.unusable => SettingsNoticeTone.danger,
                UsageFailureKind.rateLimited ||
                UsageFailureKind.serverBusy => SettingsNoticeTone.attention,
                _ => SettingsNoticeTone.neutral,
              },
              // The server's own sentence: it is the half that says what to do.
              message: failure.message,
            ),
          ),
      ],
    );
  }

  Future<void> _manage(BuildContext anchor, WidgetRef ref) async {
    final usage = this.usage;
    final onForget = this.onForget;
    final picked = await showDesktopMenuUnder<String>(anchor, [
      if (usage != null) ...[
        DesktopMenuItem(
          value: 'refresh',
          label: 'Read usage now',
          icon: AppIcons.arrowsClockwise,
        ),
        DesktopMenuItem(
          value: 'open',
          label: 'Open in the Usage tab',
          icon: AppIcons.chartBar,
        ),
      ],
      if (onForget != null) ...[
        if (usage != null) const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'forget',
          label: 'Forget this account',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ],
    ]);
    switch (picked) {
      case 'refresh' when usage != null:
        await run(
          () =>
              ref.read(usageReadingsProvider).refresh(usage.latest.accountKey),
          'Read $title’s usage.',
        );
      case 'open' when usage != null:
        openUsageTab(ref, accountId: usageAccountId(usage));
      case 'forget':
        onForget?.call();
    }
  }
}

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
              onPressed: () => openUsageTab(ref),
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

/// The newest of [installs]' versions, or null when fewer than two machines
/// have one — a flag needs something to be behind.
String? _newestVersion(List<AgentInstallation> installs) {
  final versions = [for (final install in installs) ?install.version];
  if (versions.length < 2) return null;
  return versions.reduce((a, b) => compareAgentVersions(a, b) >= 0 ? a : b);
}

/// **The agent's latest release** (board: "Latest X · checked 3h ago", Check
/// now): what its declared source last said, how long ago, and why the last
/// check failed when it did. Offers the agent's own update command to copy
/// when a machine is behind — never runs it: updating is the user's act, on
/// the machine that needs it.
class _LatestRelease extends ConsumerWidget {
  const _LatestRelease({
    required this.agentId,
    required this.source,
    required this.anyBehind,
  });

  final String agentId;
  final AgentLatestVersionSource source;
  final bool anyBehind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentLatestVersionsProvider);
    final checking = state.isChecking(agentId);
    final last = state.of(agentId);
    final now = ref.watch(clockProvider).nowUtc();
    final version = last?.version;
    final readAt = last?.readAt;
    final failure = last?.failure;
    final help = Text.rich(
      TextSpan(
        children: [
          if (version != null)
            TextSpan(
              text:
                  'Latest $version'
                  '${readAt == null ? '' : ' · checked ${describeAge(now.difference(readAt))}'}',
            )
          else if (checking)
            const TextSpan(text: 'Checking…')
          else if (failure == null)
            TextSpan(text: 'Not checked yet · from ${source.label}'),
          // In the help's own colour: a failed check is quiet, and the last
          // known version above it still stands.
          if (failure != null)
            TextSpan(
              text: '${version == null ? '' : ' · '}couldn’t check: $failure',
            ),
        ],
      ),
    );
    final command = ref
        .watch(agentRegistryProvider)
        .byId(agentId)
        ?.launch
        .selfUpdate
        .updateCommand;
    return SettingsRow(
      label: 'Latest release',
      helpWidget: help,
      stackedFit: SettingsControlFit.start,
      control: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        children: [
          if (anyBehind && command != null && command.isNotEmpty)
            TextButton(
              onPressed: () => _copy(context, command.join(' ')),
              child: const Text('Copy update command'),
            ),
          OutlinedButton(
            onPressed: checking
                ? null
                : () => ref
                      .read(agentLatestVersionsProvider.notifier)
                      .checkNow(agentId: agentId),
            child: Text(checking ? 'Checking…' : 'Check now'),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context, String command) async {
    await Clipboard.setData(ClipboardData(text: command));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Copied “$command”. Run it on each machine that is behind.',
        ),
      ),
    );
  }
}

/// A saved account, whichever vendor's store it came from.
@immutable
class _Saved {
  const _Saved({
    required this.id,
    required this.title,
    required this.raw,
    this.email,
    this.plan,
  });

  final String id;
  final String title;
  final String? email;
  final String? plan;
  final Object raw;

  /// "me@example.com · max", as the board writes an account.
  String get describe => plan == null ? title : '$title · $plan';

  /// The menu's "Re-read the sign-in" row, told apart by identity.
  static const reread = _Saved(id: '\u0000reread', title: '', raw: '');

  @override
  bool operator ==(Object other) => other is _Saved && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Who one install is signed in as, and which saved account that is.
class _SignIn {
  const _SignIn({required this.signedIn, this.email, this.plan, this.savedId});

  final bool signedIn;
  final String? email;
  final String? plan;

  /// The saved account it matches, or null when it is signed in to one not
  /// saved yet (which earns the row a Capture).
  final String? savedId;

  String get describe {
    final who = email ?? 'Signed in';
    return plan == null ? who : '$who · $plan';
  }
}

/// **What one agent's account store can do**, so the machines and accounts
/// sections are written once for Claude's OAuth store and Codex's `auth.json`
/// store alike. Null for an agent whose accounts this app does not save.
sealed class _AccountStore {
  const _AccountStore();

  static _AccountStore? of(AgentAdapter? adapter) =>
      switch (adapter?.accounts) {
        AnthropicOAuthAccounts() => const _ClaudeStore(),
        OpenAiAuthFileAccounts() => const _CodexStore(),
        _ => null,
      };

  List<_Saved> saved(WidgetRef ref);
  AsyncValue<_SignIn> signIn(WidgetRef ref, AgentInstallation install);
  void reread(WidgetRef ref, AgentInstallation install);
  Future<void> capture(WidgetRef ref, AgentInstallation install);
  Future<void> switchTo(WidgetRef ref, AgentInstallation install, _Saved to);
  Future<void> forget(WidgetRef ref, _Saved account);
}

final class _ClaudeStore extends _AccountStore {
  const _ClaudeStore();

  @override
  List<_Saved> saved(WidgetRef ref) => [
    for (final account in ref.watch(claudeAccountsControllerProvider))
      _Saved(
        id: account.id,
        title: account.email,
        email: account.email,
        plan: account.subscriptionType,
        raw: account,
      ),
  ];

  @override
  AsyncValue<_SignIn> signIn(WidgetRef ref, AgentInstallation install) {
    final accounts = ref.watch(claudeAccountsControllerProvider);
    return ref
        .watch(claudeAuthSnapshotProvider(install))
        .whenData(
          (s) => _SignIn(
            signedIn: s.isSignedIn,
            email: s.email,
            plan: s.subscriptionType,
            savedId: s.isSignedIn
                ? accounts.where(s.matches).firstOrNull?.id
                : null,
          ),
        );
  }

  @override
  void reread(WidgetRef ref, AgentInstallation install) =>
      ref.invalidate(claudeAuthSnapshotProvider(install));

  @override
  Future<void> capture(WidgetRef ref, AgentInstallation install) => ref
      .read(claudeAccountsControllerProvider.notifier)
      .captureCurrent(install);

  @override
  Future<void> switchTo(WidgetRef ref, AgentInstallation install, _Saved to) =>
      ref
          .read(claudeAccountsControllerProvider.notifier)
          .switchTo(install, to.raw as ClaudeAccount);

  @override
  Future<void> forget(WidgetRef ref, _Saved account) => ref
      .read(claudeAccountsControllerProvider.notifier)
      .forget(account.raw as ClaudeAccount);
}

final class _CodexStore extends _AccountStore {
  const _CodexStore();

  @override
  List<_Saved> saved(WidgetRef ref) => [
    for (final account in ref.watch(codexAccountsControllerProvider))
      _Saved(
        id: account.id,
        title: account.email ?? account.accountId,
        email: account.email,
        plan: account.planType,
        raw: account,
      ),
  ];

  @override
  AsyncValue<_SignIn> signIn(WidgetRef ref, AgentInstallation install) {
    final accounts = ref.watch(codexAccountsControllerProvider);
    return ref
        .watch(codexAuthSnapshotProvider(install))
        .whenData(
          (s) => _SignIn(
            signedIn: s.isSignedIn,
            email: s.email ?? s.accountId,
            plan: s.planType,
            savedId: s.isSignedIn
                ? accounts
                      .where((a) => a.accountId == s.accountId)
                      .firstOrNull
                      ?.id
                : null,
          ),
        );
  }

  @override
  void reread(WidgetRef ref, AgentInstallation install) =>
      ref.invalidate(codexAuthSnapshotProvider(install));

  @override
  Future<void> capture(WidgetRef ref, AgentInstallation install) => ref
      .read(codexAccountsControllerProvider.notifier)
      .captureCurrent(install);

  @override
  Future<void> switchTo(WidgetRef ref, AgentInstallation install, _Saved to) =>
      ref
          .read(codexAccountsControllerProvider.notifier)
          .switchTo(install, to.raw as CodexAccount);

  @override
  Future<void> forget(WidgetRef ref, _Saved account) => ref
      .read(codexAccountsControllerProvider.notifier)
      .forget(account.raw as CodexAccount);
}
