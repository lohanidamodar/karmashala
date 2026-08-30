import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/application/environments_controller.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';
import '../application/ssh_connection_providers.dart';
import '../application/ssh_failure.dart';
import '../application/ssh_hosts_controller.dart';
import '../application/ssh_providers.dart';
import '../data/environment_key_reader.dart';
import '../domain/ssh_host.dart';
import 'host_key_changed_alert.dart';

/// Adds or edits one remote host.
///
/// The form stores *where* a key is, never a key, a password or a passphrase:
/// `ssh_hosts` has no column that could hold one, and a test asserts it. The
/// secrets for a connection are asked for when the connection is made and kept
/// in memory only.
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
        existing?.privateKey?.environmentId ?? localWindowsEnvironmentId;
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
    final file = await openFile();
    if (file == null) return;
    setState(() {
      _keyPath.text = file.path;
      // The picker runs on the Windows host, so what it returns is a Windows
      // path — recording it under any other environment would be a lie.
      _keyEnvironmentId = localWindowsEnvironmentId;
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
    // settings being tested are not saved yet, and nothing else should inherit
    // a session opened from a draft.
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
    final theme = Theme.of(context);
    final environments = keyHostingEnvironments(
      ref.watch(environmentsControllerProvider),
    );
    final keyEnvironment = environments
        .where((e) => e.id == _keyEnvironmentId)
        .firstOrNull;
    final probe = _probe;
    final rejection = probe == null ? null : hostKeyRejectionIn(probe.error);

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
                selected: {_auth},
                onSelectionChanged: (s) => setState(() => _auth = s.first),
              ),
              if (_auth == SshAuthMethod.privateKey) ...[
                const SizedBox(height: Insets.md),
                DropdownButtonFormField<String>(
                  initialValue:
                      environments.any((e) => e.id == _keyEnvironmentId)
                      ? _keyEnvironmentId
                      : null,
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
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null) setState(() => _keyEnvironmentId = id);
                  },
                ),
                const SizedBox(height: Insets.md),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _keyPath,
                        decoration: InputDecoration(
                          labelText: 'Private key path',
                          hintText: keyEnvironment?.kind == EnvironmentKind.wsl
                              ? '/home/you/.ssh/id_ed25519'
                              : r'C:\Users\you\.ssh\id_ed25519',
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    OutlinedButton.icon(
                      onPressed: _browseForKey,
                      icon: const Icon(AppIcons.folderOpen, size: 16),
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
              const SizedBox(height: Insets.lg),
              TextField(
                controller: _directory,
                decoration: const InputDecoration(
                  labelText: 'Default directory on the host (optional)',
                  hintText: '/home/you/src',
                ),
              ),
              const SizedBox(height: Insets.lg),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _test,
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(AppIcons.play, size: 16),
                  label: const Text('Test connection'),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: Insets.md),
                DesktopErrorBanner(_error!),
              ],
              if (rejection != null) ...[
                const SizedBox(height: Insets.md),
                HostKeyChangedAlert(
                  presentation: rejection.presentation,
                  onForgotten: () => setState(() => _probe = null),
                ),
              ] else if (probe != null) ...[
                const SizedBox(height: Insets.md),
                _ProbeResult(probe: probe),
              ],
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

class _ProbeResult extends StatelessWidget {
  const _ProbeResult({required this.probe});

  final SshHostProbe probe;

  @override
  Widget build(BuildContext context) {
    if (!probe.connected) return DesktopErrorBanner(probe.message);
    final theme = Theme.of(context);
    final elapsed = probe.elapsed;
    return Row(
      children: [
        Icon(AppIcons.checkCircle, size: 16, color: theme.colorScheme.primary),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(
            'Connected${elapsed == null ? '' : ' in ${elapsed.inMilliseconds} ms'}'
            ' — ${probe.message}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
