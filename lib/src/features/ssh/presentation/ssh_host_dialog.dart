import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_ui/picking.dart';
import '../../environments/application/environments_controller.dart';
import '../../settings/presentation/path_field_row.dart';
import 'package:agent_cli/process.dart';
import '../application/ssh_connection_providers.dart';
import '../application/ssh_failure.dart';
import '../application/ssh_hosts_controller.dart';
import '../application/ssh_providers.dart';
import '../data/environment_key_reader.dart';
import 'package:karmashala_ssh/connection.dart';
import 'host_key_changed_alert.dart';
import '../../settings/presentation/settings_notice.dart';

/// Adds or edits one remote host. The form stores *where* a key is, never a key
/// or a password: `ssh_hosts` has no column for one, and a test asserts it.
class SshHostDialog extends ConsumerStatefulWidget {
  const SshHostDialog({this.existing, super.key});

  /// The host being edited, or null when adding a new one.
  final SshHost? existing;

  static Future<SshHost?> show(BuildContext context, {SshHost? existing}) =>
      showDialog<SshHost>(
        context: context,
        builder: (_) => SshHostDialog(existing: existing),
      );

  @override
  ConsumerState<SshHostDialog> createState() => _SshHostDialogState();
}

class _SshHostDialogState extends ConsumerState<SshHostDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _keyPath;
  late final TextEditingController _directory;

  late SshAuthMethod _auth;
  late String _keyEnvironmentId;

  String? _error;
  SshHostProbe? _probe;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _host = TextEditingController(text: existing?.host ?? '');
    _port = TextEditingController(text: '${existing?.port ?? 22}');
    _username = TextEditingController(text: existing?.username ?? '');
    _keyPath = TextEditingController(text: existing?.privateKey?.path ?? '');
    _directory = TextEditingController(
      text: existing?.defaultDirectory?.path ?? '',
    );
    _auth = existing?.authMethod ?? SshAuthMethod.privateKey;
    _keyEnvironmentId =
        existing?.privateKey?.environmentId ?? localHostEnvironmentId;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _keyPath.dispose();
    _directory.dispose();
    super.dispose();
  }

  Future<void> _browseForKey() async {
    final file = await pickOneFile(
      context: context,
      what: 'an SSH private key',
      startNear: _keyPath.text,
    );
    if (file == null || !mounted) return;
    setState(() {
      _keyPath.text = file.path;
      // The picker runs on the Windows host, so what it returns is a Windows
      // path — recording it under any other environment would be a lie.
      _keyEnvironmentId = localHostEnvironmentId;
    });
  }

  /// The host as the form currently describes it, or null with [_error] set.
  SshHost? _draft() {
    final name = _name.text.trim();
    final address = _host.text.trim();
    final username = _username.text.trim();
    final port = int.tryParse(_port.text.trim());
    final keyPath = _keyPath.text.trim();
    final directory = _directory.text.trim();

    if (name.isEmpty || address.isEmpty || username.isEmpty) {
      setState(() => _error = 'Name, host and username are all required.');
      return null;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Port must be a number between 1 and 65535.');
      return null;
    }
    if (_auth == SshAuthMethod.privateKey && keyPath.isEmpty) {
      setState(
        () =>
            _error = 'Key authentication needs the path to a private key file.',
      );
      return null;
    }

    final id = widget.existing?.id ?? 'draft';
    return SshHost(
      id: id,
      name: name,
      host: address,
      port: port,
      username: username,
      authMethod: _auth,
      privateKey: _auth == SshAuthMethod.privateKey
          ? EnvironmentPath(environmentId: _keyEnvironmentId, path: keyPath)
          : null,
      defaultDirectory: directory.isEmpty
          ? null
          : EnvironmentPath(
              environmentId: sshEnvironmentId(id),
              path: directory,
            ),
      createdAt: widget.existing?.createdAt ?? ref.read(clockProvider).nowUtc(),
    );
  }

  Future<void> _test() async {
    setState(() {
      _error = null;
      _probe = null;
      _busy = true;
    });
    final draft = _draft();
    if (draft == null) {
      setState(() => _busy = false);
      return;
    }
    // Through the pool's `create`, which does not register the connection: the
    // settings tested are not saved, and nothing inherits a draft session.
    final probe = await probeSshHost(
      ref.read(sshConnectionPoolProvider),
      draft,
    );
    if (!mounted) return;
    setState(() {
      _probe = probe;
      _busy = false;
    });
  }

  Future<void> _save() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    final draft = _draft();
    if (draft == null) {
      setState(() => _busy = false);
      return;
    }
    final controller = ref.read(sshHostsControllerProvider.notifier);
    final SshHost saved;
    if (widget.existing == null) {
      saved = await controller.add(
        name: draft.name,
        host: draft.host,
        port: draft.port,
        username: draft.username,
        authMethod: draft.authMethod,
        privateKey: draft.privateKey,
        defaultDirectory: draft.defaultDirectory?.path,
      );
    } else {
      saved = await controller.save(draft);
    }
    if (!mounted) return;
    Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final environments = keyHostingEnvironments(
      ref.watch(environmentsControllerProvider),
    );

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.globe,
        title: widget.existing == null ? 'Add SSH host' : 'Edit SSH host',
        subtitle:
            'A remote POSIX machine to run agents on. No password or '
            'passphrase is stored.',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'build-box',
                ),
              ),
              const SizedBox(height: Insets.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _host,
                      decoration: const InputDecoration(
                        labelText: 'Host',
                        hintText: 'build.example.com',
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: TextField(
                      controller: _port,
                      decoration: const InputDecoration(labelText: 'Port'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.md),
              TextField(
                controller: _username,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  hintText: 'The remote account to log in as',
                ),
              ),
              const SizedBox(height: Insets.lg),
              _AuthFields(
                method: _auth,
                onMethodChanged: (method) => setState(() => _auth = method),
                environments: environments,
                keyEnvironmentId: _keyEnvironmentId,
                onKeyEnvironmentChanged: (id) =>
                    setState(() => _keyEnvironmentId = id),
                keyPath: _keyPath,
                onBrowseForKey: _browseForKey,
              ),
              const SizedBox(height: Insets.lg),
              TextField(
                controller: _directory,
                decoration: const InputDecoration(
                  labelText: 'Default directory on the host (optional)',
                  hintText: '/home/you/src',
                ),
              ),
              const SizedBox(height: Insets.lg),
              _ConnectionTest(
                busy: _busy,
                onTest: _test,
                error: _error,
                probe: _probe,
                onKeyForgotten: () => setState(() => _probe = null),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(widget.existing == null ? 'Add host' : 'Save'),
        ),
      ],
    );
  }
}

/// How the host is logged in to: a key file on one of this desktop's
/// environments, or a password asked for on each connection.
class _AuthFields extends StatelessWidget {
  const _AuthFields({
    required this.method,
    required this.onMethodChanged,
    required this.environments,
    required this.keyEnvironmentId,
    required this.onKeyEnvironmentChanged,
    required this.keyPath,
    required this.onBrowseForKey,
  });

  final SshAuthMethod method;
  final ValueChanged<SshAuthMethod> onMethodChanged;

  /// The environments a key file can live in.
  final List<ExecutionEnvironment> environments;
  final String keyEnvironmentId;
  final ValueChanged<String> onKeyEnvironmentChanged;
  final TextEditingController keyPath;
  final VoidCallback onBrowseForKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyEnvironment = environments
        .where((e) => e.id == keyEnvironmentId)
        .firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('AUTHENTICATION', style: theme.textTheme.labelSmall),
        const SizedBox(height: Insets.sm),
        SegmentedButton<SshAuthMethod>(
          segments: const [
            ButtonSegment(
              value: SshAuthMethod.privateKey,
              label: Text('Private key'),
            ),
            ButtonSegment(
              value: SshAuthMethod.password,
              label: Text('Password'),
            ),
          ],
          selected: {method},
          onSelectionChanged: (s) => onMethodChanged(s.first),
        ),
        if (method == SshAuthMethod.privateKey) ...[
          const SizedBox(height: Insets.md),
          DropdownButtonFormField<String>(
            initialValue: keyEnvironment?.id,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'The key file lives in',
              helperText:
                  'A Windows path and a WSL path are different files, '
                  'even when they read the same.',
            ),
            items: [
              for (final environment in environments)
                DropdownMenuItem(
                  value: environment.id,
                  child: Text(
                    '${environment.name} · ${environment.id}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (id) {
              if (id != null) onKeyEnvironmentChanged(id);
            },
          ),
          const SizedBox(height: Insets.md),
          PathFieldRow.inDialog(
            controller: keyPath,
            label: 'Private key path',
            hint: keyEnvironment?.kind == EnvironmentKind.wsl
                ? '/home/you/.ssh/id_ed25519'
                : r'C:\Users\you\.ssh\id_ed25519',
            actions: [
              OutlinedButton.icon(
                onPressed: onBrowseForKey,
                icon: const Icon(AppIcons.folderOpen),
                label: const Text('Browse'),
              ),
            ],
          ),
        ] else ...[
          const SizedBox(height: Insets.sm),
          Text(
            'The password is asked for each time you connect and is '
            'never written to disk.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// The Test connection button and what the last test said: an error, a
/// changed host key with the way to forget it, or the probe's result.
class _ConnectionTest extends StatelessWidget {
  const _ConnectionTest({
    required this.busy,
    required this.onTest,
    required this.error,
    required this.probe,
    required this.onKeyForgotten,
  });

  final bool busy;
  final VoidCallback onTest;
  final String? error;
  final SshHostProbe? probe;
  final VoidCallback onKeyForgotten;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    final probe = this.probe;
    final rejection = probe == null ? null : hostKeyRejectionIn(probe.error);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: busy ? null : onTest,
            icon: busy ? const InlineSpinner() : const Icon(AppIcons.play),
            label: const Text('Test connection'),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: Insets.md),
          DesktopErrorBanner(error),
        ],
        if (rejection != null) ...[
          const SizedBox(height: Insets.md),
          HostKeyChangedAlert(
            presentation: rejection.presentation,
            onForgotten: onKeyForgotten,
          ),
        ] else if (probe != null) ...[
          const SizedBox(height: Insets.md),
          _ProbeResult(probe: probe),
        ],
      ],
    );
  }
}

class _ProbeResult extends StatelessWidget {
  const _ProbeResult({required this.probe});

  final SshHostProbe probe;

  @override
  Widget build(BuildContext context) {
    if (!probe.connected) return DesktopErrorBanner(probe.message);
    final elapsed = probe.elapsed;
    return SettingsNotice(
      tone: SettingsNoticeTone.positive,
      message:
          'Connected'
          '${elapsed == null ? '' : ' in ${elapsed.inMilliseconds} ms'}'
          ' — ${probe.message}',
    );
  }
}
