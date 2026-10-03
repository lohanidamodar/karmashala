import 'package:karmashala_host/mcp_tools.dart';
import 'package:karmashala_mcp/instructions.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:flutter_test/flutter_test.dart';

/// The annotation table, held against the tools it describes.
///
/// The table's whole value is that it is complete. An annotation a client never
/// receives is worse than none at all — it reads as "this tool was considered
/// and found safe" when what happened is that nobody looked. So the coverage is
/// asserted in both directions, and a new tool cannot ship until someone has
/// decided whether it can be undone.
void main() {
  final servedNames = <String>{
    for (final schema in _served) schema['name']! as String,
  };

  test('every served tool declares what it does', () {
    expect(
      servedNames.difference(kMcpToolAnnotations.keys.toSet()),
      isEmpty,
      reason: 'these tools are served with no annotations',
    );
  });

  test('the table describes no tool that is not served', () {
    expect(
      kMcpToolAnnotations.keys.toSet().difference(servedNames),
      isEmpty,
      reason: 'these annotations describe a tool that no longer exists',
    );
  });

  test('a read-only tool is never also destructive', () {
    for (final entry in kMcpToolAnnotations.entries) {
      if (!entry.value.readOnly) continue;
      expect(
        entry.value.destructive,
        isFalse,
        reason: '${entry.key} cannot both change nothing and destroy something',
      );
    }
  });

  test('the tools that end things say so', () {
    // Named individually rather than counted: the point is that *these* are
    // marked, and a rename of one must fail here rather than pass on a total.
    for (final name in const [
      'checkpoint_restore',
      'session_end',
      'session_answer',
      'terminal_run',
      'terminal_close',
      'note_delete',
      'inbox_dismiss',
      'device_stop_emulator',
      'device_tap',
      'browser_evaluate',
    ]) {
      expect(
        kMcpToolAnnotations[name]?.destructive,
        isTrue,
        reason: '$name has no undo and must be annotated as destructive',
      );
    }
  });

  test('annotations reach the served schemas, and only add to them', () {
    final annotated = annotatedToolSchemas(_served);
    expect(annotated, hasLength(_served.length));
    for (var i = 0; i < annotated.length; i++) {
      final original = _served[i];
      final hints = annotated[i]['annotations']! as Map<String, Object?>;
      expect(annotated[i]['name'], original['name']);
      expect(annotated[i]['description'], original['description']);
      expect(annotated[i]['inputSchema'], original['inputSchema']);
      // All four are written out. The spec defaults `destructiveHint` to true
      // and `openWorldHint` to true, so an omitted hint is a claim of its own.
      // The fifth is ours and travels with them, because the caller deciding
      // whether to run this over a list is the reader it is written for.
      expect(hints.keys, <String>{
        'readOnlyHint',
        'destructiveHint',
        'idempotentHint',
        'openWorldHint',
        'movesAttentionHint',
      });
    }
  });

  group('the fifth axis: does it move the user out of what they were at', () {
    // Named individually, and asserted **both ways** — one step stricter than
    // the destructive list above. The value of this axis is entirely that
    // somebody opened each of the ninety-odd implementations and followed the
    // call chain; a one-way list would let a tool acquire the mark on a guess,
    // and a total would pass while every answer rotted underneath it.
    const movers = <String>{
      // Opens an agent tab, makes it the active tab, focuses its pane.
      'open_new_session',
      // The same launch, then a wait for the child's answer.
      'subagent_run',
      // Reattaches and focuses the pane and rewrites the selected session; an
      // imported session opens an external terminal window instead.
      'open_session',
      // Both launch the continuing session into a focused tab, and the
      // checkpoint fork launches one too — on top of rewriting the files.
      'session_handoff',
      'session_fork',
      'session_fork_from_checkpoint',
      // Takes the pane away; the next tab becomes active and takes the keys.
      'session_end',
      'terminal_open',
      'terminal_close',
      // `focusWatchedSession`: project, repository and session selection.
      'inbox_open',
      // Repoints the Explorer, the diff view and the side panel.
      'select_checkout',
      // Opens a terminal tab for the run and focuses it — and the same for
      // project_build's "build", which is the worst of that tool's four.
      'flutter_run',
      'project_build',
      // A pane per configured check, opened in turn like project_build's.
      'checks_run',
      // Puts the running app into widget-select mode and waits on a person.
      'flutter_pick_widget',
      // Each can end up launching a visible Chrome; `browser_tabs` opens a
      // foreground tab in it, and `browser_pick` fronts it and blocks.
      'browser_connect',
      'browser_navigate',
      'browser_tabs',
      'browser_pick',
      // Selects the simulator in the device pane, and with headless off opens
      // Simulator.app.
      'device_boot',
      // Connects a browser for a URL run, which can be a new window.
      'verification_start',
    };

    test('these tools move the user\'s attention, and exactly these', () {
      expect(<String>{
        for (final entry in kMcpToolAnnotations.entries)
          if (entry.value.movesAttention) entry.key,
      }, movers);
    });

    test('a shared const never carries the answer for one of them', () {
      // `read` and `readOutside` answer for about a third of the table, so
      // they answer "moves nothing" and a read-only tool that *does* move
      // attention has to spell its annotations out. Two do — the two pickers,
      // which change nothing and interrupt everything.
      expect(McpToolAnnotations.read.movesAttention, isFalse);
      expect(McpToolAnnotations.readOutside.movesAttention, isFalse);
      for (final name in const ['browser_pick', 'flutter_pick_widget']) {
        expect(kMcpToolAnnotations[name]?.readOnly, isTrue);
        expect(kMcpToolAnnotations[name]?.movesAttention, isTrue);
      }
    });

    test('the payload tools describe their delivery, not their payload', () {
      // `terminal_run`, `snippet_insert` and `browser_evaluate` carry a
      // command the caller wrote, which could open anything. They are marked
      // destructive for exactly that reason and are **not** marked here: a
      // hint that says "possibly" on every one of them tells a client nothing,
      // and what these three do themselves is type into a pane the caller
      // named or evaluate in a page it is already driving.
      for (final name in const [
        'terminal_run',
        'snippet_insert',
        'browser_evaluate',
      ]) {
        expect(kMcpToolAnnotations[name]?.destructive, isTrue);
        expect(kMcpToolAnnotations[name]?.movesAttention, isFalse);
      }
    });
  });

  group('the listing a person reads', () {
    // The annotations above are for a client; this is for whoever opens
    // Settings → Tools and asks what the thing they installed can do. It rots
    // the same way the annotation table would without the two assertions at
    // the top of this file — a tool with no line beside it reads as one nobody
    // thought was worth explaining — so the coverage is asserted both ways and
    // the length cap is a gate rather than a convention.

    test('every served tool has a category and a summary', () {
      expect(
        servedNames.difference(kMcpToolListings.keys.toSet()),
        isEmpty,
        reason:
            'these tools would be listed with a name and nothing else: give '
            'each a category and one line in mcp_tool_catalogue.dart',
      );
    });

    test('the listing describes no tool that is not served', () {
      expect(
        kMcpToolListings.keys.toSet().difference(servedNames),
        isEmpty,
        reason: 'these summaries describe a tool that no longer exists',
      );
    });

    test('a summary is one line, and short enough to be one', () {
      for (final entry in kMcpToolListings.entries) {
        final summary = entry.value.summary;
        expect(summary.trim(), isNotEmpty, reason: '${entry.key} says nothing');
        expect(
          summary,
          summary.trim(),
          reason: '${entry.key} is padded, and the page does not trim',
        );
        expect(
          summary,
          isNot(contains('\n')),
          reason: '${entry.key} is a paragraph; the schema is where those go',
        );
        expect(
          summary.length,
          lessThanOrEqualTo(McpToolListing.summaryLimit),
          reason:
              '${entry.key} is ${summary.length} chars — over '
              '${McpToolListing.summaryLimit} it wraps and stops being a line '
              'the eye can skip',
        );
      }
    });

    test('a summary says something the name does not', () {
      for (final entry in kMcpToolListings.entries) {
        expect(
          entry.value.summary.split(' ').length,
          greaterThan(3),
          reason: '${entry.key} is restated, not explained',
        );
      }
    });

    test('every category has at least one tool in it', () {
      // The page draws a heading per category, so an empty one is a heading
      // over nothing — and it is the shape a rename leaves behind when a
      // family is moved but its category is not retired.
      for (final category in McpToolCategory.values) {
        expect(
          kMcpToolsByCategory[category],
          isNotEmpty,
          reason: '${category.name} would be a heading with nothing under it',
        );
      }
    });

    test('the grouping lists every tool exactly once', () {
      final listed = <String>[
        for (final tools in kMcpToolsByCategory.values) ...tools,
      ];
      expect(listed.toSet(), hasLength(listed.length));
      expect(listed.toSet(), kMcpToolListings.keys.toSet());
    });
  });

  group('a destructive family names its guide', () {
    // The table above says which tools cannot be undone. That is the right
    // answer to "should a client confirm this", and the wrong answer to "what
    // should I have known before calling it" — an annotation has no room to
    // say that a successful `terminal_run` may carry no exit code, or that
    // `checkpoint_restore` saves the tree it is about to overwrite. The guides
    // in `instructions_tools.dart` are where that goes, and this is what makes
    // writing one non-optional: a tool with no undo whose family nobody
    // documented fails here rather than shipping with a description and a
    // shrug.
    final claimed = <String, String>{
      for (final guide in kMcpGuides)
        for (final tool in guide.tools) tool: guide.topic,
    };

    test('every destructive tool is covered by a guide', () {
      final uncovered = <String>[
        for (final entry in kMcpToolAnnotations.entries)
          if (entry.value.destructive && !claimed.containsKey(entry.key))
            entry.key,
      ];
      expect(
        uncovered,
        isEmpty,
        reason:
            'these tools have no undo and no guide: add them to a family in '
            'instructions_tools.dart, or write a new one',
      );
    });

    test('no two guides claim the same tool', () {
      // Membership is computed from name prefixes, so an overlap is silent —
      // and an agent that reads one guide would be told a tool is somebody
      // else's problem while the other guide says the opposite.
      for (final tool in kMcpToolAnnotations.keys) {
        final owners = <String>[
          for (final guide in kMcpGuides)
            if (guide.claims(tool)) guide.topic,
        ];
        expect(
          owners.length,
          lessThan(2),
          reason: '$tool is claimed by ${owners.join(' and ')}',
        );
      }
    });

    test('a guide claims nothing that is not served', () {
      // Against the *declared* names, not the computed roster: the roster is
      // filtered through this table and so cannot disagree with it, while a
      // hand-written `extraTools` entry for a renamed tool would just quietly
      // stop covering anything.
      for (final guide in kMcpGuides) {
        expect(
          guide.extraTools.toSet().difference(kMcpToolAnnotations.keys.toSet()),
          isEmpty,
          reason: '${guide.topic} names a tool that no longer exists',
        );
      }
    });

    test('the guides tool is itself in the table', () {
      // It is served, so by the two assertions at the top of this file it has
      // to be here — this names it so the reason is visible.
      expect(kMcpToolAnnotations['instructions']?.readOnly, isTrue);
    });
  });
}

/// What agents are served: the server's tools, and nothing else — no tool
/// is forwarded to an app since slice 5b (protocol 28).
final List<Map<String, dynamic>> _served = [...serverToolSchemas];
