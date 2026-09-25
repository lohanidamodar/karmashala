import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// The model lists the CLIs themselves report, read 2026-09-23.
void main() {
  group('Claude Code list_models', () {
    // Claude Code 2.1.280's answer, trimmed to the fields that matter.
    const answer =
        '{"type":"control_response","response":{"subtype":"success",'
        '"request_id":"karmashala-models","response":{"models":['
        '{"value":"default","displayName":"Default (recommended)",'
        '"description":"Opus 5.5 with 1M context"},'
        '{"value":"opus[1m]","displayName":"Opus (1M context)",'
        '"description":"Opus 5.5 with 1M context"},'
        '{"value":"claude-fable-5-1[1m]","displayName":"Fable",'
        '"description":"Fable 5.1"},'
        '{"value":"sonnet","displayName":"Sonnet","description":"Sonnet 5"},'
        '{"value":"old","displayName":"Old","disabled":true},'
        '{"value":"haiku","displayName":"Haiku","description":"Haiku 4.5"}'
        ']}}}';

    test('names every model the account can run, in its order', () {
      final models = parseClaudeModelList('noise\n$answer\n')!;
      expect(models.map((m) => m.id), [
        'opus[1m]',
        'claude-fable-5-1[1m]',
        'sonnet',
        'haiku',
      ]);
      expect(models.first.label, 'Opus (1M context)');
      expect(models.first.summary, 'Opus 5.5 with 1M context');
    });

    test('`default` is not a model, and a disabled row is not offered', () {
      final ids = parseClaudeModelList(answer)!.map((m) => m.id);
      expect(ids, isNot(contains('default')));
      expect(ids, isNot(contains('old')));
    });

    test('an older CLI that refuses the request gives no list', () {
      expect(
        parseClaudeModelList(
          '{"type":"control_response","response":{"subtype":"error",'
          '"request_id":"karmashala-models","error":"unknown"}}',
        ),
        isNull,
      );
      expect(parseClaudeModelList(''), isNull);
    });

    test('the request is one line the CLI answers and exits on', () {
      expect(kClaudeListModelsRequest, endsWith('\n'));
      expect(kClaudeListModelsRequest.trim(), contains('"list_models"'));
      expect(kClaudeListModelsArguments, contains('stream-json'));
    });
  });

  group('Codex models_cache.json', () {
    const cache = '''
{"fetched_at":"2026-09-23","models":[
 {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","description":"Newest."},
 {"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide"},
 {"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list"}
]}''';

    test('lists what its own picker lists, hidden entries left out', () {
      final models = parseCodexModelsCache(cache)!;
      expect(models.map((m) => m.id), ['gpt-6-astra', 'gpt-5.5']);
      expect(models.first.label, 'GPT-6-Astra');
      expect(models.first.summary, 'Newest.');
    });

    test('a file that is not the cache gives no list', () {
      expect(parseCodexModelsCache('not json'), isNull);
      expect(parseCodexModelsCache('{"models":[]}'), isNull);
    });
  });

  test('a reported list changes the models, never how one is asked for', () {
    final claude = AgentRegistry.builtIn.byId('claudeCode')!.launch.model;
    final found = claude.withModels(const [
      AgentModel(id: 'opus[1m]', label: 'Opus (1M context)', summary: ''),
    ]);
    expect(found.models.single.id, 'opus[1m]');
    expect(found.switchesLive, claude.switchesLive);
    expect(found.commandFor('opus[1m]'), '/model opus[1m]');
    expect(found.argumentsFor('opus[1m]'), ['--model', 'opus[1m]']);
    expect(const ClaudeCodeAdapter().modelLister, isA<ClaudeModelLister>());
  });
}
