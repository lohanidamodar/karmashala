part of '../agents_and_accounts_page.dart';

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
