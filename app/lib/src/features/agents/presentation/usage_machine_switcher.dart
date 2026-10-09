import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/agent_installations_controller.dart';
import '../application/agent_providers.dart';
import '../application/agent_account_switch.dart';
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
    required this.id,
    required this.label,
    required this.current,
  });

  final String id;
  final String label;

  /// The account this machine is signed in with now — checked, not offered.
  final bool current;
}

/// **A machine's account switcher**, on the usage card's machine row (spec
/// §5): the agent's saved accounts, the one in force checked, the others a
/// click away. It asks [AccountSwitchController], the switch Settings asks
/// too; the server captures and switches on its own machine.
///
/// Only agents whose adapter declares a switchable sign-in have one (Claude's
/// OAuth, Codex's `auth.json`); for any other agent, or a machine whose
/// installation is not known, or no saved account yet, it draws nothing and
/// the row stays a plain statement of where the account is used.
///
/// A nested [MenuAnchor] whose items do not close on activation: closing
/// would close the card around it too, and the pick would land on a disposed
/// row and never be asked.
class UsageMachineSwitcher extends ConsumerWidget {
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

  bool _isCurrent(String? email) {
    final current = currentEmail;
    return current != null &&
        email != null &&
        email.toLowerCase() == current.toLowerCase();
  }

  AgentInstallation? _installation(WidgetRef ref) {
    for (final candidate in ref.watch(agentInstallationsControllerProvider)) {
      if (candidate.agentId == agentId &&
          candidate.environmentId == environmentId) {
        return candidate;
      }
    }
    return null;
  }

  /// The saved accounts this machine could switch to, or null when its agent
  /// offers no switch.
  List<_SwitchOption>? _options(WidgetRef ref) {
    final kind = ref.watch(agentRegistryProvider).adapterFor(agentId)?.accounts;
    if (kind is AnthropicOAuthAccounts) {
      return [
        for (final account in ref.watch(claudeAccountsControllerProvider))
          _SwitchOption(
            id: account.id,
            label: account.email,
            current: _isCurrent(account.email),
          ),
      ];
    }
    if (kind is OpenAiAuthFileAccounts) {
      return [
        for (final account in ref.watch(codexAccountsControllerProvider))
          _SwitchOption(
            id: account.id,
            label: account.email ?? account.accountId,
            current: _isCurrent(account.email),
          ),
      ];
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final install = _installation(ref);
    final options = install == null ? null : _options(ref);
    if (install == null || options == null || options.isEmpty) {
      return const SizedBox.shrink();
    }
    final switching = ref.watch(accountSwitchControllerProvider);
    if (switching.busy.contains(install.id)) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: Insets.sm),
        child: InlineSpinner(semanticsLabel: 'Switching account'),
      );
    }
    final last = switching.last;
    final failed =
        last != null && last.installationId == install.id && !last.succeeded;
    final theme = Theme.of(context);
    final ink = failed
        ? SemanticColors.of(context).failure
        : theme.colorScheme.onSurfaceVariant;
    final label = theme.textTheme.bodySmall?.copyWith(color: ink);
    final menu = MenuAnchor(
      menuChildren: [
        for (final option in options)
          Builder(
            builder: (item) => MenuItemButton(
              key: ValueKey('usage-switch-$environmentId-${option.id}'),
              closeOnActivate: false,
              // The account in force is checked and not offered again.
              onPressed: option.current
                  ? null
                  : () {
                      MenuController.maybeOf(item)?.close();
                      ref
                          .read(accountSwitchControllerProvider.notifier)
                          .switchTo(install, option.id);
                    },
              leadingIcon: Icon(
                option.current ? AppIcons.check : AppIcons.userCircle,
                size: Chrome.iconAction,
              ),
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
      builder: (context, controller, _) => InkWell(
        key: ValueKey('usage-switch-$environmentId'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.xs + Insets.xxs,
            vertical: Insets.xxs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failed) ...[
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
    return Semantics(
      button: true,
      label: 'Switch the account on this machine',
      child: Tooltip(
        message: 'Switch the account on this machine',
        child: menu,
      ),
    );
  }
}
