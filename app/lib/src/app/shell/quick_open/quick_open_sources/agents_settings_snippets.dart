part of '../quick_open_sources.dart';

// Agent, settings and command snippet rows.

extension _AgentSettingsSnippetSources on QuickOpenSources {
  // --- agents --------------------------------------------------------------

  List<QuickOpenItem> _agents() {
    final registry = ref.read(agentRegistryProvider);
    return [
      for (final installation in ref.read(agentInstallationsControllerProvider))
        // A leftover row of an agent the registry forgot has no name to show.
        if (registry.adapterFor(installation.agentId) != null)
          QuickOpenItem(
            id: 'agent/${installation.id}',
            group: QuickOpenGroup.agents,
            title: registry.displayNameFor(installation.agentId),
            subtitle: installation.executable.path,
            detail: installation.version,
            icon: AppIcons.robot,
            leading: AgentLogo(
              agentId: installation.agentId,
              size: Chrome.icon,
            ),
            keywords: [installation.agentId, installation.environmentId],
            weight: _agentWeight,
            opensTab: true,
            // Lands on the Agents section — the entry is an agent, and a jump
            // to the top of Appearance would be a jump to nowhere.
            onSelect: () => dismiss(
              () => openSettingsTab(ref, section: SettingsSectionId.agents),
            ),
          ),
    ];
  }

  // --- settings ------------------------------------------------------------

  /// Every Settings page, section and option this client shows, read from the
  /// catalogue Settings' own page list and search read, and opened the way
  /// they open them. A row titled like an earlier one on the same page — the
  /// Keyboard page and its Keyboard section, the Skills section and its Skills
  /// option — is folded into the earlier, broader one, its words with it.
  List<QuickOpenItem> _settings() {
    final caps = ref.read(capabilitiesProvider);
    final rows = <String, QuickOpenItem Function(List<String> keywords)>{};
    final words = <String, Set<String>>{};
    void add(
      SettingsSectionId page,
      String id,
      String title,
      double weight,
      Iterable<String> keywords,
      VoidCallback open,
    ) {
      final key = '${page.name}/${title.toLowerCase()}';
      (words[key] ??= {}).addAll(keywords);
      rows.putIfAbsent(
        key,
        () =>
            (keywords) => QuickOpenItem(
              id: 'settings/$id',
              group: QuickOpenGroup.settings,
              title: title,
              subtitle: id.startsWith('page/')
                  ? 'Settings'
                  : 'Settings · ${page.label}',
              icon: page.icon,
              keywords: keywords,
              weight: weight,
              opensTab: true,
              onSelect: () => dismiss(open),
            ),
      );
    }

    for (final page in SettingsSectionId.values) {
      if (!page.shownWith(caps)) continue;
      add(
        page,
        'page/${page.name}',
        page.label,
        _settingsPageWeight,
        page.aliases,
        () => openSettingsTab(ref, section: page),
      );
    }
    for (final anchor in SettingsAnchor.values) {
      if (!anchor.shownWith(caps)) continue;
      add(
        anchor.page,
        'anchor/${anchor.name}',
        anchor.title,
        _settingsWeight,
        anchor.keywords,
        () => openSettingsTab(ref, anchor: anchor),
      );
    }
    for (final entry in settingsEntries) {
      if (!entry.anchor.shownWith(caps)) continue;
      add(
        entry.page,
        'entry/${entry.anchor.name}/${entry.label}',
        entry.label,
        _settingsEntryWeight,
        entry.keywords,
        // As a hit in Settings' own search opens it: its section, scrolled to.
        () => openSettingsTab(ref, anchor: entry.anchor),
      );
    }
    return [
      for (final MapEntry(:key, value: build) in rows.entries)
        build(words[key]!.toList()),
    ];
  }

  // --- command snippets ----------------------------------------------------

  /// The saved commands that fit the terminal the user is in. The pane is
  /// captured at build; filtering is by its shell, and untagged fits anywhere.
  List<QuickOpenItem> _snippets() {
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    final state = ref.read(terminalSessionsControllerProvider);
    final target = resolveSnippetTarget(terminals, state);
    final all = ref.read(commandSnippetsProvider);
    final fitting = target == null ? all : target.filter(all);
    return [
      for (final snippet in fitting)
        QuickOpenItem(
          id: 'snippet/${snippet.id}',
          group: QuickOpenGroup.snippets,
          title: snippet.label,
          subtitle: snippet.command,
          // The one thing worth a badge: a snippet that will press Enter has
          // to say so *before* it is picked, not afterwards.
          detail: snippet.submit ? 'runs' : null,
          icon: AppIcons.bookBookmark,
          keywords: [
            snippet.command,
            'snippet',
            ?snippet.shellId,
            if (snippet.submit) 'run',
          ],
          weight: _snippetWeight,
          // Typed into the pane, which the phone then shows.
          onSelect: () => dismiss(
            target == null
                ? () => _insert(snippet, target)
                : _seen(() => _insert(snippet, target)),
          ),
        ),
      // Filtering is right; silence about it is not — a library that fits no
      // pane produced an empty palette, which reads as "my snippet is gone".
      if (fitting.length < all.length)
        QuickOpenItem(
          id: 'snippet/hidden',
          group: QuickOpenGroup.snippets,
          title: switch (all.length - fitting.length) {
            1 => '1 snippet is for another shell',
            final n => '$n snippets are for another shell',
          },
          subtitle: target?.shellId == null
              ? "This pane's shell is unknown, so only untagged snippets are "
                    'offered'
              : 'This pane runs ${target!.shellId}',
          icon: AppIcons.bookBookmark,
          keywords: const ['snippet', 'hidden', 'shell', 'other'],
          weight: _snippetAdminWeight,
          onSelect: () => dismiss(
            () => SnippetLibraryDialog.show(
              context,
              suggestedShellId: target?.shellId,
            ),
          ),
        ),
      QuickOpenItem(
        id: 'snippet/new',
        group: QuickOpenGroup.snippets,
        title: 'New command snippet…',
        subtitle: 'Keep a command so you can pick it instead of retyping it',
        icon: AppIcons.plus,
        keywords: const ['snippet', 'command', 'save', 'add'],
        weight: _snippetAdminWeight,
        onSelect: () => dismiss(() => _newSnippet(target)),
      ),
      QuickOpenItem(
        id: 'snippet/manage',
        group: QuickOpenGroup.snippets,
        title: 'Manage command snippets…',
        subtitle: 'Edit or remove what you have saved',
        icon: AppIcons.bookBookmark,
        keywords: const ['snippet', 'library', 'edit', 'delete'],
        weight: _snippetAdminWeight,
        onSelect: () => dismiss(
          () => SnippetLibraryDialog.show(
            context,
            suggestedShellId: target?.shellId,
          ),
        ),
      ),
    ];
  }

  void _insert(CommandSnippet snippet, SnippetTarget? target) {
    final message = target == null
        ? 'Open a terminal to type a snippet into.'
        : insertSnippet(
            terminals: ref.read(terminalSessionsControllerProvider.notifier),
            state: ref.read(terminalSessionsControllerProvider),
            snippet: snippet,
            paneId: target.paneId,
          ).message;
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// The notifier is resolved before the `await`, and has to be: [dismiss] pops
  /// the palette, and Riverpod 3 throws on a `ref.read` from an unmounted element.
  Future<void> _newSnippet(SnippetTarget? target) async {
    final snippets = ref.read(commandSnippetsProvider.notifier);
    final draft = await SnippetEditorDialog.show(
      context,
      suggestedShellId: target?.shellId,
    );
    if (draft == null) return;
    snippets.add(
      label: draft.label,
      command: draft.command,
      shellId: draft.shellId,
      submit: draft.submit,
    );
  }
}
