import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/github_access_controller.dart';

/// Settings → Source control → GitHub: a token pasted here (kept by the
/// server, write-only), and per host which gh account Karmashala uses or
/// whether it uses GitHub there at all.
class GithubAccessPage extends ConsumerWidget {
  const GithubAccessPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(githubAccessProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'GITHUB',
          child: _TokenForm(status: status),
        ),
        SettingsSection(
          title: 'ACCESS BY HOST',
          trailing: TextButton.icon(
            onPressed: () => ref.read(githubAccessProvider.notifier).refresh(),
            icon: const Icon(AppIcons.arrowClockwise),
            label: const Text('Check again'),
          ),
          child: status == null
              ? const SettingsNote(
                  'Waiting for the Karmashala server to say where its GitHub '
                  'access comes from.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final host in status.hosts) _HostRow(access: host),
                    if (status.ghProblem case final problem?)
                      SettingsNote(problem),
                    const SettingsNote(
                      'Order: a token saved here, then GH_TOKEN or GITHUB_TOKEN '
                      'in the server\'s environment (GH_ENTERPRISE_TOKEN for '
                      'the host GH_HOST names), then gh\'s login.',
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Paste, Save, Clear and Test. The token is never shown again once saved:
/// the page says that one is saved, when, and who it last tested as.
class _TokenForm extends ConsumerStatefulWidget {
  const _TokenForm({required this.status});

  final GithubAccessStatus? status;

  @override
  ConsumerState<_TokenForm> createState() => _TokenFormState();
}

class _TokenFormState extends ConsumerState<_TokenForm> {
  final _host = TextEditingController(text: 'github.com');
  final _token = TextEditingController();
  bool _visible = false;
  bool _busy = false;
  String? _error;
  GithubTokenCheck? _check;

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    super.dispose();
  }

  String get _hostName {
    final host = _host.text.trim().toLowerCase();
    return host.isEmpty ? 'github.com' : host;
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on DataRefused catch (refused) {
      if (mounted) setState(() => _error = refused.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
    final token = _token.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Paste a token to save.');
      return;
    }
    await ref.read(githubAccessProvider.notifier).save(_hostName, token);
    _token.clear();
    _check = null;
  });

  Future<void> _clear() => _run(() async {
    await ref.read(githubAccessProvider.notifier).clear(_hostName);
    _check = null;
  });

  Future<void> _test() => _run(() async {
    final check = await ref.read(githubAccessProvider.notifier).test(_hostName);
    if (mounted) setState(() => _check = check);
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final saved = widget.status?.savedFor(_hostName);
    final check = _check;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          label: 'Host',
          help: 'github.com, a *.ghe.com tenant, or an Enterprise Server.',
          control: TextField(
            key: const ValueKey('github-token-host'),
            controller: _host,
            onChanged: (_) => setState(() => _check = null),
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        SettingsRow(
          label: saved == null ? 'Token' : 'Replace token',
          help:
              'Kept by the Karmashala server in a file only its account can '
              'open, and never shown again.',
          control: TextField(
            key: const ValueKey('github-token-value'),
            controller: _token,
            obscureText: !_visible,
            enableSuggestions: false,
            autocorrect: false,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Paste a token',
              errorText: _error,
              errorMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: _visible ? 'Hide' : 'Show',
                icon: Icon(_visible ? AppIcons.eyeSlash : AppIcons.eye),
                onPressed: () => setState(() => _visible = !_visible),
              ),
            ),
          ),
        ),
        SettingsRuled(
          child: Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Save'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _test,
                child: const Text('Test'),
              ),
              if (saved != null)
                TextButton(
                  onPressed: _busy ? null : _clear,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  child: const Text('Clear'),
                ),
            ],
          ),
        ),
        if (saved != null)
          SettingsRuled(
            child: Row(
              children: [
                Icon(
                  AppIcons.lockSimple,
                  size: Chrome.icon,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                Text('••••••••', style: MonoStyles.label),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    saved.login == null
                        ? 'Saved · not tested yet'
                        : 'Saved · last checked as @${saved.login}',
                    key: const ValueKey('github-token-saved'),
                    style: quiet,
                  ),
                ),
              ],
            ),
          ),
        if (check != null)
          SettingsRuled(
            child: Text(
              check.ok
                  ? 'GitHub says this is @${check.login}.'
                  : check.message ?? 'The test failed.',
              key: const ValueKey('github-token-check'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: check.ok
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// One host: where its access comes from, and the gh account or Off.
class _HostRow extends ConsumerWidget {
  const _HostRow({required this.access});

  final GithubHostAccess access;

  static const _followGh = '';
  static const _off = '\u0000off';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final active = access.ghActiveAccount;
    final current = access.off ? _off : access.account ?? _followGh;
    final accounts = {...access.ghAccounts, ?access.account}.toList();
    return SettingsRow(
      label: access.host,
      helpWidget: Text(
        access.status,
        key: ValueKey('github-status-${access.host}'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: access.source == null
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      control: DropdownButtonFormField<String>(
        key: ValueKey('github-account-${access.host}'),
        initialValue: current,
        isExpanded: true,
        items: [
          DropdownMenuItem(
            value: _followGh,
            child: Text(
              active == null
                  ? 'gh\'s active account'
                  : 'gh\'s active (@$active)',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (final login in accounts)
            DropdownMenuItem(
              value: login,
              child: Text('@$login', overflow: TextOverflow.ellipsis),
            ),
          const DropdownMenuItem(
            value: _off,
            child: Text('Off — no GitHub on this host'),
          ),
        ],
        onChanged: (value) {
          if (value == null) return;
          ref
              .read(githubAccessProvider.notifier)
              .choose(
                access.host,
                account: value == _off || value == _followGh ? null : value,
                off: value == _off,
              );
        },
      ),
    );
  }
}
