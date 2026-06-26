import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../repositories/data/repository_discovery_service.dart';
import '../application/projects_controller.dart';

/// Dialog to create a project by pointing at a folder. Runs repository discovery
/// and reports how many repositories were found.
///
/// A native folder picker is deferred to a later quality-of-life loop; for now
/// the folder is entered as a path. The field is validated and discovery errors
/// are surfaced inline.
class NewProjectDialog extends ConsumerStatefulWidget {
  const NewProjectDialog({super.key});

  /// Shows the dialog. Returns `true` if a project was created.
  static Future<bool?> show(BuildContext context) => showDialog<bool>(
    context: context,
    builder: (_) => const NewProjectDialog(),
  );

  @override
  ConsumerState<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends ConsumerState<NewProjectDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _pathController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(projectsControllerProvider.notifier)
          .createByDiscovery(
            name: _nameController.text.trim(),
            path: _pathController.text.trim(),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Created "${result.project.name}" — '
            '${result.repositories.length} repository(ies) found.',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } on RepositoryDiscoveryException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not create project: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New project'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Project name',
                  hintText: 'My workspace',
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Enter a project name'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pathController,
                decoration: const InputDecoration(
                  labelText: 'Folder path',
                  hintText: r'C:\src\my-workspace',
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Enter a folder path'
                    : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create & scan'),
        ),
      ],
    );
  }
}
