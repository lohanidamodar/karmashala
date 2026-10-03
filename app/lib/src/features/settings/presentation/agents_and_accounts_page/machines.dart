part of '../agents_and_accounts_page.dart';

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
    final newest = newestAgentVersion(installs);
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
