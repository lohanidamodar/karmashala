import 'package:karmashala_git/repositories.dart';
import 'package:riverpod/riverpod.dart';

import '../explorer/application/checkout_picker.dart';
import '../workspaces/data/workspace_data.dart';

/// `select_checkout`: moves this app's own screen, so it is always the app's.
/// `list_checkouts`, `project_rescan` and `delivery_status` are the server's
/// (and so is an SSH checkout's, since slice 3a).
class WorkspaceControlTools {
  WorkspaceControlTools(this._container);

  final ProviderContainer _container;

  static bool handles(String name) => name == 'select_checkout';

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'select_checkout' => _select(args['repositoryId'] as String?),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// Points Explorer, the diff view and the side panel at one checkout, through
  /// the same `CheckoutPicker` the side panel's own picker calls.
  Object? _select(String? repositoryId) {
    if (repositoryId == null || repositoryId.isEmpty) {
      throw ArgumentError(
        'repositoryId is required. list_checkouts has the ids.',
      );
    }
    final Repository? repository = _container
        .read(workspaceDataProvider)
        .repository(repositoryId);
    if (repository == null) {
      throw StateError('No checkout with id $repositoryId.');
    }
    _container.read(checkoutPickerProvider).select(repository);
    return <String, Object?>{
      'repositoryId': repository.id,
      'name': repository.name,
      'path': repository.path.path,
      'projectId': repository.projectId,
      'selected': true,
    };
  }
}

/// The schemas for [WorkspaceControlTools].
const List<Map<String, dynamic>> workspaceControlToolSchemas = [
  {
    'name': 'select_checkout',
    'description':
        'Point Karmashala\'s Explorer, diff view and side panel at a '
        'checkout. This is what the user sees change on screen, so use it to '
        'show someone where you are working rather than to navigate for '
        'yourself.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {
          'type': 'string',
          'description': 'Which checkout, from list_checkouts.',
        },
      },
      'required': ['repositoryId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {'type': 'string'},
        'name': {'type': 'string'},
        'path': {'type': 'string'},
        'projectId': {'type': 'string'},
        'selected': {'type': 'boolean'},
      },
      'required': ['repositoryId', 'selected'],
    },
  },
];
