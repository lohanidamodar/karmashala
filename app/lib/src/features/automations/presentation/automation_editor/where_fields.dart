// Where it runs: the machine, then one of its projects or any folder on it.

part of '../automation_editor.dart';

extension _AutomationWhereFields on _AutomationEditorState {
  Widget _where(
    BuildContext context, {
    required List<Repository> repositories,
    required Repository? repository,
    required List<ExecutionEnvironment> environments,
    required String machineId,
  }) {
    final draft = _draft;
    final machineName = _machineName(environments, machineId);
    final folders = ref.watch(commandsOfferedProvider) && !draft.watchesProject;
    // A saved automation keeps its checkout; a folder may move.
    final keepsCheckout = !draft.isNew && !draft.inFolder;
    return EditorNode(
      key: const ValueKey('automation-where'),
      title: 'Where',
      icon: AppIcons.folder,
      hint: 'The machine, then a project or any folder on it.',
      children: [
        if (keepsCheckout)
          EditorNote(
            'Runs in ${repository?.name ?? 'a checkout that is gone'}'
            '${repository == null ? '' : ', on $machineName'}.',
          )
        else ...[
          DropdownButtonFormField<String>(
            key: const ValueKey('automation-machine'),
            initialValue: environments.any((e) => e.id == machineId)
                ? machineId
                : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Machine'),
            items: [
              for (final env in environments)
                DropdownMenuItem(
                  value: env.id,
                  child: Text(
                    environmentLabel(env) ?? env.id,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (id) => id == null ? null : _onMachine(id, repositories),
          ),
          if (draft.isNew && folders)
            CompactSegmented<DraftPlace>(
              key: const ValueKey('automation-place'),
              segments: [
                for (final place in DraftPlace.values)
                  ButtonSegment(value: place, label: Text(place.label)),
              ],
              selected: draft.place,
              onChanged: (place) => _update(
                place == DraftPlace.folder
                    ? _asCommand(_draft.copyWith(place: place))
                    : _draft.copyWith(place: place),
              ),
            ),
          if (!draft.inFolder)
            _checkoutField(repositories, machineId, repository)
          else ...[
            PathFieldRow(
              key: const ValueKey('automation-folder'),
              controller: _folder,
              label: 'Folder',
              hint: kHomeFolder,
              onChanged: (value) =>
                  _update(_draft.copyWith(folderPath: value.trim())),
              actions: [
                OutlinedButton(
                  key: const ValueKey('automation-folder-browse'),
                  onPressed: () => _browseFolder(machineId),
                  child: const Text('Browse…'),
                ),
              ],
            ),
            EditorNote(
              '$kHomeFolder is your home folder on $machineName. Only a '
              'command runs here: an agent needs a project.',
            ),
          ],
        ],
        if (draft.placeProblem case final problem?
            when draft.inFolder || draft.isNew)
          _Problem(problem),
      ],
    );
  }

  Widget _checkoutField(
    List<Repository> repositories,
    String machineId,
    Repository? repository,
  ) {
    final here = [
      for (final r in repositories)
        if (r.path.environmentId == machineId) r,
    ];
    if (here.isEmpty) {
      return const EditorNote(
        'No project on this machine yet. Add one, or pick another machine.',
      );
    }
    return DropdownButtonFormField<String>(
      key: const ValueKey('automation-checkout'),
      initialValue: here.any((r) => r.id == repository?.id)
          ? repository?.id
          : null,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Project'),
      hint: const Text('Pick a project'),
      items: [
        for (final r in here)
          DropdownMenuItem(
            value: r.id,
            child: Text(r.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (id) =>
          _update(_withGithubRepository(_draft.withCheckout(id))),
    );
  }

  /// [draft] running a command, with the time limit a command needs.
  AutomationDraft _asCommand(AutomationDraft draft) {
    if (draft.maxRuntimeMinutes != null) {
      return draft.copyWith(runsCommand: true);
    }
    _longest.text = '${kCommandTimeLimit.inMinutes}';
    return draft.copyWith(
      runsCommand: true,
      maxRuntimeMinutes: kCommandTimeLimit.inMinutes,
    );
  }

  /// Another machine: a project not on it is unpicked.
  void _onMachine(String id, List<Repository> repositories) {
    final repository = _repository(repositories);
    final kept = repository != null && repository.path.environmentId == id;
    _update(
      (kept ? _draft : _draft.withCheckout(null)).copyWith(environmentId: id),
    );
  }

  Future<void> _browseFolder(String machineId) async {
    final picked = await pickOneDirectory(
      context: context,
      environmentId: machineId,
      what: 'the folder it runs in',
      startNear: _folder.text.trim() == kHomeFolder ? null : _folder.text,
    );
    if (picked == null || !mounted) return;
    _folder.text = picked;
    _update(_draft.copyWith(folderPath: picked));
  }

  String _machineName(List<ExecutionEnvironment> environments, String id) {
    for (final env in environments) {
      if (env.id == id) return environmentLabel(env) ?? env.id;
    }
    return id;
  }
}
