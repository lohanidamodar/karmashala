import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_runtime.dart';
import 'package:karmashala_remote/remote.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';
import 'companion_states.dart';
import 'link_banner.dart';
import 'project_sessions_screen.dart';

/// Adds an already-existing project on the desktop. The path is intentionally
/// typed or pasted: a phone cannot open a native picker on its paired host.
class AddProjectScreen extends ConsumerStatefulWidget {
  const AddProjectScreen({super.key});

  @override
  ConsumerState<AddProjectScreen> createState() => _AddProjectScreenState();
}

class _AddProjectScreenState extends ConsumerState<AddProjectScreen> {
  final _name = TextEditingController();
  final _path = TextEditingController();
  late String _requestId = _newRequestId();
  bool _busy = false;
  String? _error;

  String _newRequestId() => ref.read(companionIdGeneratorProvider).newId();

  @override
  void initState() {
    super.initState();
    _name.addListener(_intentChanged);
    _path.addListener(_intentChanged);
  }

  @override
  void dispose() {
    _name..removeListener(_intentChanged)..dispose();
    _path..removeListener(_intentChanged)..dispose();
    super.dispose();
  }

  void _intentChanged() {
    _requestId = _newRequestId();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final gateway = ref.read(companionGatewayProvider);
    if (gateway.link != CompanionLinkState.connected) {
      setState(() => _error = 'Connect to your desktop before adding a project.');
      return;
    }
    final name = _name.text.trim();
    final path = _path.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a project name.');
      return;
    }
    if (path.isEmpty) {
      setState(() => _error = 'Enter the project path on your desktop.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final hostId = gateway.pairing?.hostId;
      final project = await gateway.addProject(
        requestId: _requestId,
        name: name,
        path: path,
      );
      if (!mounted) return;
      if (gateway.pairing?.hostId != hostId) {
        setState(() => _error = 'The active desktop changed. Review and submit again.');
        return;
      }
      ref.invalidate(companionProjectsProvider);
      ref.invalidate(companionWorkspaceProvider);
      Navigator.of(context).pushReplacement(
        companionRoute<void>(
          context,
          (_) => ProjectSessionsScreen(projectKey: project.projectId),
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = companionErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final granted = ref.watch(companionGatewayProvider).capabilities.has(
      Capability.addProject,
    );
    return Scaffold(
      appBar: companionAppBar(context, title: const Text('Add project')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinkBanner(),
            Expanded(
              child: !granted
                  ? const CompanionNotice(
                      icon: AppIcons.warningCircle,
                      title: 'Not granted',
                      tone: NoticeTone.attention,
                      body: 'This desktop did not grant this phone permission '
                          'to add projects.',
                    )
                  : _form(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form() => ListView(
    padding: companionListInsets(
      context,
      const EdgeInsets.fromLTRB(Insets.lg, Insets.lg, Insets.lg, Insets.xl),
    ),
    children: [
      Text(
        'Add a project that already exists on your desktop.',
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: Insets.lg),
      TextField(
        controller: _name,
        enabled: !_busy,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'Project name',
          prefixIcon: Icon(AppIcons.folder),
        ),
      ),
      const SizedBox(height: Insets.md),
      TextField(
        controller: _path,
        enabled: !_busy,
        maxLines: 2,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'Desktop path',
          hintText: r'C:\Users\you\projects\app',
          prefixIcon: Icon(AppIcons.folderOpen),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: Insets.md),
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      const SizedBox(height: Insets.lg),
      FilledButton.icon(
        onPressed: _busy ? null : _submit,
        icon: _busy
            ? const SizedBox(
                width: Touch.iconSmall,
                height: Touch.iconSmall,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(AppIcons.folderPlus),
        label: Text(_busy ? 'Adding…' : 'Add project'),
      ),
    ],
  );
}
