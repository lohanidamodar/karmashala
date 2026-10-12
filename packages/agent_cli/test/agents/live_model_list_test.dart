import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// The live model lists: Antigravity's `agy models`, and how a live list and
/// the curated one merge into what the picker offers.
void main() {
  group('agy models', () {
    // agy 1.3.3 in WSL, 2026-10-12, stdout as captured (the spinner is on
    // stderr), trimmed to rows that matter, plus an id nobody has seen.
    const captured =
        'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'
        'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\n'
        'gemini-flash-demo\tGemini 3.7 Flash\n'
        'agy-demo-low\tGemini 4 Argon (Low)\n'
        'agy-demo-high\tGemini 4 Argon (High)\n'
        'claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n'
        'gpt-oss-120b-medium\tGPT-OSS 120B (Medium)\n'
        'argon-4\n';

    test('reads each row as id and label, in its order', () {
      final models = parseAgyModels(captured)!;
      expect(models.map((m) => m.id), [
        'gemini-3.8-flash-high',
        'gemini-3.7-flash-low',
        'gemini-flash-demo',
        'agy-demo-low',
        'agy-demo-high',
        'claude-sonnet-4-6',
        'gpt-oss-120b-medium',
        'argon-4',
      ]);
      expect(models[3].label, 'Gemini 4 Argon (Low)');
      // An id with no label of its own keeps the id; the merge names it.
      expect(models.last.label, 'argon-4');
    });

    test('a spinner, a notice or a stray escape is not a model', () {
      final models = parseAgyModels(
        '\x1B[2K⠋ Fetching available models...\n'
        'Fetching available models...\n'
        'Usage: agy models [flags]\n'
        '\x1B[Kagy-demo-medium\tGemini 4 Argon (Medium)\n'
        'agy-demo-medium\tdup\n',
      )!;
      expect(models.map((m) => m.id), ['agy-demo-medium']);
    });

    test('output naming nothing is no list', () {
      expect(parseAgyModels(''), isNull);
      expect(parseAgyModels('Fetching available models...\n'), isNull);
    });

    test(
      'the lister runs `agy models` in the environment it is given',
      () async {
        final asked = <List<String>>[];
        final found = await const AntigravityModelLister().list(
          ModelListContext(
            hostEnvironment: const {},
            hostIsWindows: false,
            runLocalCli:
                (arguments, {stdinText, timeout = Duration.zero}) async {
                  asked.add(arguments);
                  return captured;
                },
          ),
        );
        expect(asked, [
          ['models'],
        ]);
        expect(found, hasLength(8));
      },
    );

    test('Antigravity declares the lister, and says where it reads', () {
      final adapter = AgentRegistry.builtIn.adapterFor(AgentIds.antigravity)!;
      expect(adapter.modelLister, isA<AntigravityModelLister>());
      expect(adapter.modelLister!.source, 'agy models');
    });

    test('the curated fallback carries Argon 4, as listed on 2026-10-12', () {
      final curated = AgentRegistry.builtIn
          .byId(AgentIds.antigravity)!
          .launch
          .model;
      expect(curated.modelFor('agy-demo-high')?.label, 'Gemini 4 Argon (High)');
      expect(curated.listedLive, isFalse);
    });
  });

  group('merging a live list with the curated one', () {
    const curated = [
      AgentModel(id: 'a-1', label: 'Curated A', summary: 'Curated summary A'),
      AgentModel(id: 'b-2', label: 'Curated B', summary: 'Curated summary B'),
    ];

    test('live ids decide what is offered and in what order', () {
      final merged = mergeModelLists(
        curated: curated,
        live: const [
          AgentModel(id: 'argon-4', label: 'argon-4', summary: ''),
          AgentModel(id: 'a-1', label: 'Agent A', summary: ''),
        ],
      );
      expect(merged.map((m) => m.id), ['argon-4', 'a-1']);
      // A curated id the agent no longer lists is gone.
      expect(merged.map((m) => m.id), isNot(contains('b-2')));
    });

    test('the agent\'s own label wins; a curated entry names an id the agent '
        'left bare, and lends its summary where the agent gave none', () {
      final merged = mergeModelLists(
        curated: curated,
        live: const [
          AgentModel(id: 'a-1', label: 'Agent A', summary: ''),
          AgentModel(id: 'b-2', label: 'b-2', summary: 'Agent says B'),
        ],
      );
      expect(merged[0].label, 'Agent A');
      expect(merged[0].summary, 'Curated summary A');
      expect(merged[1].label, 'Curated B');
      expect(merged[1].summary, 'Agent says B');
    });

    test('an unknown id keeps the agent\'s own label and description, or is '
        'named from its id', () {
      final merged = mergeModelLists(
        curated: curated,
        live: const [
          AgentModel(id: 'argon-4', label: 'argon-4', summary: ''),
          AgentModel(
            id: 'agy-demo-high',
            label: 'Gemini 4 Argon (High)',
            summary: 'Preview',
          ),
        ],
      );
      expect(merged[0].label, 'Argon 4');
      expect(merged[1].label, 'Gemini 4 Argon (High)');
      expect(merged[1].summary, 'Preview');
    });

    test('no live list leaves the curated one standing', () {
      expect(mergeModelLists(curated: curated, live: const []), curated);
    });

    test('ids read as names', () {
      expect(modelLabelFromId('argon-4'), 'Argon 4');
      expect(modelLabelFromId('gpt-oss-120b'), 'GPT OSS 120b');
      expect(modelLabelFromId('gemini_3.9-pro'), 'Gemini 3.9 Pro');
    });
  });

  group('no longer listed', () {
    final descriptor = AgentRegistry.builtIn.byId(AgentIds.antigravity)!;

    test('a chosen id the live list dropped stays, marked', () {
      final live = descriptor.launch.model.withModels(const [
        AgentModel(id: 'agy-demo-high', label: 'Argon', summary: ''),
      ]);
      final options = modelOptionsFor(
        descriptor,
        current: 'gemini-3.1-pro-high',
        support: live,
      );
      expect(options.map((o) => o.model.id), [
        'agy-demo-high',
        'gemini-3.1-pro-high',
      ]);
      final gone = options.last;
      expect(gone.fit, AgentModelFit.noLongerListed);
      expect(gone.fitLabel, 'no longer listed');
      // Named the way the curated list named it, not as a raw id.
      expect(gone.model.label, 'Gemini 3.1 Pro (High)');
      expect(gone.summary, contains('no longer lists'));
    });

    test('against the curated list the same row is only unlisted', () {
      final options = modelOptionsFor(descriptor, current: 'made-up-id');
      expect(options.last.fit, AgentModelFit.unlisted);
    });
  });

  test('a catalogue survives its own JSON', () {
    final catalog = AgentModelCatalog(
      installationId: 'agy1',
      models: const [
        AgentModel(id: 'argon-4', label: 'Argon 4', summary: 's'),
        AgentModel(id: 'x', label: 'X', summary: '', resolvedId: 'x-1'),
      ],
      readAt: DateTime.utc(2026, 10, 12, 9),
      source: 'agy models',
      failure: 'exit 1',
      failedAt: DateTime.utc(2026, 10, 12, 10),
    );
    final back = AgentModelCatalog.fromJson(catalog.toJson());
    expect(back.installationId, 'agy1');
    expect(back.models.map((m) => m.id), ['argon-4', 'x']);
    expect(back.models.last.resolvedId, 'x-1');
    expect(back.readAt, catalog.readAt);
    expect(back.source, 'agy models');
    expect(back.failure, 'exit 1');
    expect(back.failedAt, catalog.failedAt);
    expect(
      back.isStale(DateTime.utc(2026, 10, 12, 14), kAgentModelsTtl),
      isFalse,
    );
    expect(
      back.isStale(DateTime.utc(2026, 10, 12, 15), kAgentModelsTtl),
      isTrue,
    );
  });
}
