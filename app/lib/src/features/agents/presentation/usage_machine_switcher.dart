import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/agent_installations_controller.dart';
import '../application/agent_providers.dart';
import '../application/agent_usage_providers.dart';
import '../application/claude_accounts_controller.dart';
import '../application/codex_accounts_controller.dart';

/// The plan of the saved account signed in as [email] — Claude's
/// subscription, Codex's plan type — or null when no saved account says. The
/// usage reading itself does not carry a plan, and asking the server who is
/// signed in on each machine just to name one would cost a request per card.
String? usageSavedPlanOf(WidgetRef ref, String agentId, String? email) {
  if (email == null) return null;
  final lower = email.toLowerCase();
  final kind = ref.watch(agentRegistryProvider).adapterFor(agentId)?.accounts;
  if (kind is AnthropicOAuthAccounts) {
    for (final account in ref.watch(claudeAccountsControllerProvider)) {
      if (account.email.toLowerCase() == lower) return account.subscriptionType;
    }
  } else if (kind is OpenAiAuthFileAccounts) {
    for (final account in ref.watch(codexAccountsControllerProvider)) {
      if (account.email?.toLowerCase() == lower) return account.planType;
    }
  }
  return null;
}

/// One saved account a machine can be switched to, whichever agent's it is.
@immutable
class _SwitchOption {
  const _SwitchOption({
    required this.label,
    required this.current,
    required this.switchTo,
  });

  final String label;

  /// The account this machine is signed in with now — checked, not offered.
  final bool current;

  /// Asks the server to switch the machine; throws with the server's words.
  final Future<void> Function() switchTo;
}

/// **A machine's account switcher**, on the usage card's machine row (spec
/// §5): the agent's saved accounts, the one in force checked, the others a
/// click away. It asks the same controllers Settings' account sections do —
/// the server captures and switches on its own machine, so no credential and
/// no new store is involved here.
///
/// Only agents whose adapter declares a switchable sign-in have one (Claude's
/// OAuth, Codex's `auth.json`); for any other agent, or a machine whose
/// installation is not known, or no saved account yet, it draws nothing and
/// the row stays a plain statement of where the account is used.
///
/// A nested [MenuAnchor] on purpose: inside the usage card's own menu it
/// becomes a submenu, sharing the card's tap region, so picking an account
/// does not count as a tap outside the card and close it mid-switch — a
/// pushed popup route would.
class UsageMachineSwitcher extends ConsumerStatefulWidget {
  const UsageMachineSwitcher({
    required this.agentId,
    required this.environmentId,
    required this.currentEmail,
    super.key,
  });

  final String agentId;
  final String environmentId;

  /// Who the usage reading says is signed in on this machine; null when it
  /// did not say, and then nothing is checked.
  final String? currentEmail;

  @override
  ConsumerState<UsageMachineSwitcher> createState() =>
      _UsageMachineSwitcherState();
}

class _UsageMachineSwitcherState extends ConsumerState<UsageMachineSwitcher> {
  bool _busy = false;
  String? _failure;

  bool _isCurrent(String? email) {
    final current = widget.currentEmail;
    return current != null &&
        email != null &&
        email.toLowerCase() == current.toLowerCase();
  }

  /// The saved accounts this machine could switch to, or null when its agent
  /// or installation offers no switch.
  List<_SwitchOption>? _options() {
    final adapter = ref.watch(agentRegistryProvider).adapterFor(widget.agentId);
    final kind = adapter?.accounts;
    if (kind is! AnthropicOAuthAccounts && kind is! OpenAiAuthFileAccounts) {
      return null;
    }
    AgentInstallation? installation;
    for (final candidate in ref.watch(agentInstallationsControllerProvider)) {
      if (candidate.agentId == widget.agentId &&
          candidate.environmentId == widget.environmentId) {
        installation = candidate;
        break;
      }
    }
    if (installation == null) return null;
    final install = installation;
    if (kind is AnthropicOAuthAccounts) {
      final controller = ref.read(claudeAccountsControllerProvider.notifier);
      return [
        for (final account in ref.watch(claudeAccountsControllerProvider))
          _SwitchOption(
            label: account.email,
            current: _isCurrent(account.email),
            switchTo: () => controller.switchTo(install, account),
          ),
      ];
    }
    final controller = ref.read(codexAccountsControllerProvider.notifier);
    return [
      for (final account in ref.watch(codexAccountsControllerProvider))
        _SwitchOption(
          label: account.email ?? account.accountId,
          current: _isCurrent(account.email),
          switchTo: () => controller.switchTo(install, account),
        ),
    ];
  }

  Future<void> _switch(_SwitchOption option) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    String? failure;
    try {
      await option.switchTo();
      // A new sign-in is a new quota: ask for this machine's reading now so
      // the card (and the chip) move with it rather than at the next poll.
      // Its own failure is the Refresh button's to report, not the switch's.
      await ref
          .read(usageReadingsProvider)
          .refresh(usageAccountKeyOf(widget.agentId, widget.environmentId))
          .catchError((Object _) {});
    } on ClaudeAuthException catch (e) {
      failure = e.message;
    } on CodexAuthException catch (e) {
      failure = e.message;
    } catch (e) {
      failure = '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = _options();
    if (options == null || options.isEmpty) return const SizedBox.shrink();
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: Insets.sm),
        child: InlineSpinner(semanticsLabel: 'Switching account'),
      );
    }
    final theme = Theme.of(context);
    final failure = _failure;
    final ink = failure == null
        ? theme.colorScheme.onSurfaceVariant
        : SemanticColors.of(context).failure;
    final label = theme.textTheme.bodySmall?.copyWith(color: ink);
    final menu = MenuAnchor(
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            // The account in force is checked and not offered again.
            onPressed: option.current ? null : () => _switch(option),
            leadingIcon: Icon(
              option.current ? AppIcons.check : AppIcons.userCircle,
              size: Chrome.iconAction,
            ),
            child: Text(option.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      builder: (context, controller, _) => InkWell(
        key: ValueKey('usage-switch-${widget.environmentId}'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.xs + 2,
            vertical: 2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failure != null) ...[
                Icon(AppIcons.warning, size: Chrome.iconAction, color: ink),
                const SizedBox(width: Insets.xs),
              ],
              Text('Switch', style: label),
              Icon(AppIcons.caretDown, size: Chrome.iconAction, color: ink),
            ],
          ),
        ),
      ),
    );
    // The server's words, where the switch was asked: a snackbar would land
    // under the card, behind the thing that failed.
    return Semantics(
      button: true,
      label: failure == null
          ? 'Switch the account on this machine'
          : 'Switch failed: $failure',
      child: Tooltip(
        message: failure ?? 'Switch the account on this machine',
        child: menu,
      ),
    );
  }
}
