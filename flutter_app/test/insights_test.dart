import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/card.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/month_picture.dart';
import 'package:maskoret/data/fmt.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/insights/ai_context.dart';
import 'package:maskoret/insights/engine.dart';
import 'package:maskoret/state/secure_file.dart';
import 'package:maskoret/state/store.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:maskoret/insights/markdown.dart';
import 'package:maskoret/insights/segments.dart';

void main() {
  final canRun = Platform.isMacOS && Process.runSync('which', ['swiftc']).exitCode == 0;

  const samples = [
    'שלום עולם',
    '<think>חושב על זה</think>התשובה היא 5',
    'לפני\n<think>לא נגמר',
    'טקסט\n```chart\n{"type":"pie","title":"הוצאות","data":[{"label":"אוכל","value":420},{"label":"דלק","value":"1,234 ₪"}]}\n```\nאחרי',
    '```chart\n{"data":"שבור"}\n```',
    '```chart\n{"type":"bar","data":[{"label":"א","value":1}',
    'קוד:\n```python\nprint(1)\n```\nסוף',
    'הועתק מאתר:\nchart\nCopy code\n{"type":"line","title":"מגמה","data":[{"label":"ינו","value":1.5},{"label":5,"value":2}]}\nהמשך',
    'קודם {לא json} ואז \u201Cמרכאות\u201D {\u201Ctype\u201D:\u201Cbar\u201D,\u201Cdata\u201D:[{\u201Clabel\u201D:\u201Cא\u201D,\u201Cvalue\u201D:7}]}',
    '```json\n{"data":[{"label":"בלי סוג","value":"3."},{"bad":1}]}\n```',
    '{"name":"לא תרשים","other":[1,2]}',
    'א\n\n```\n{"data":[]}\n```\n\nב',
  ];

  List<Map<String, dynamic>> mine(String s) => [
        for (final seg in InsightParser.parse(s))
          switch (seg) {
            TextSegment(:final text) => {'k': 'text', 'v': text},
            BrokenSegment(:final text) => {'k': 'broken', 'v': text},
            ChartSegment(:final spec) => {
                'k': 'chart',
                'labels': [for (final p in spec.data) p.label],
                'title': spec.title ?? '',
                'type': spec.type,
                'values': [for (final p in spec.data) p.value],
              },
          }
      ];

  /// Same keys and values, whatever the order or number format.
  dynamic canon(dynamic v) => switch (v) {
        Map m => {for (final k in m.keys.map((k) => k as String).toList()..sort()) k: canon(m[k])},
        List l => [for (final x in l) canon(x)],
        num n => n.toDouble(),
        _ => v,
      };

  test('answers split into text and charts exactly like the Swift app', () {
    final dir = Directory.systemTemp.createTempSync('parse');
    final file = File('${dir.path}/samples.json')..writeAsStringSync(jsonEncode(samples));
    final out = Process.runSync('zsh', ['tool/swift_check.sh', 'parse', file.path], stdoutEncoding: utf8);
    expect(out.exitCode, 0, reason: '${out.stderr}');
    final swift = jsonDecode(out.stdout as String) as List;
    for (var i = 0; i < samples.length; i++) {
      expect(canon(mine(samples[i])), canon(swift[i]), reason: samples[i]);
    }
    dir.deleteSync(recursive: true);
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('markdown blocks', () {
    final blocks = parseMarkdown('# כותרת\nפסקה\nשורה\n\n- א\n  - ב\n1. ג\n> ציטוט\n---\n| a | b |\n|---|---|\n| 1 | 2 |\n\n**מה טוב:**\n```\nx\n```\nשאלות:\n- מה?');
    expect(blocks.map((b) => b.runtimeType.toString()), [
      'MdHeading', 'MdParagraph', 'MdBullet', 'MdBullet', 'MdNumbered', 'MdQuote', 'MdRule', 'MdTable', 'MdHeading', 'MdCode', 'MdQuestions', 'MdBullet',
    ]);
    expect((blocks[3] as MdBullet).indent, 1);
    expect((blocks[7] as MdTable).rows, [['a', 'b'], ['1', '2']]);
    final runs = parseInline('רגיל **מודגש** *נטוי* `קוד` [קישור](https://x)');
    expect(runs.where((r) => r.bold).single.text, 'מודגש');
    expect(runs.where((r) => r.italic).single.text, 'נטוי');
    expect(runs.where((r) => r.code).single.text, 'קוד');
    expect(runs.map((r) => r.text).join(), 'רגיל מודגש נטוי קוד קישור');
  });

  group('engine', () {
    late Directory dir;
    late SecureFile secure;
    late HttpServer server;
    late InsightsEngine ai;
    late _Keys keys;
    final requests = <(String path, Map<String, String> headers, Map<String, dynamic> body)>[];
    var status = 200;
    var chunks = <String>[];
    var copied = '';

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('ai');
      secure = SecureFile(dir, _MemoryKeys());
      SharedPreferences.setMockInitialValues({});
      requests.clear();
      status = 200;
      chunks = [];
      copied = '';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        final text = await utf8.decoder.bind(r).join();
        final headers = <String, String>{};
        r.headers.forEach((k, v) => headers[k] = v.join(','));
        requests.add((r.uri.path, headers, text.isEmpty ? {} : (jsonDecode(text) as Map).cast<String, dynamic>()));
        r.response.statusCode = status;
        if (r.uri.path.endsWith('/models')) {
          r.response.write(jsonEncode({'data': [{'id': 'good-model'}, {'id': 'text-embed-1'}, {'id': 'whisper-1'}]}));
        } else if (status >= 400) {
          r.response.write('{"error":"bad"}');
        } else {
          for (final c in chunks) {
            r.response.write('$c\n\n');
          }
        }
        await r.response.close();
      });
      keys = _Keys();
      ai = InsightsEngine(await SharedPreferences.getInstance(), secure, keys, copy: (t) async => copied = t);
    });

    tearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    String base() => 'http://127.0.0.1:${server.port}/v1';

    Future<void> untilDone() async {
      for (var i = 0; i < 200 && ai.isRunning; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('without a key or a model nothing can be sent', () async {
      ai.send('שאלה', context: 'סודי');
      expect(ai.messages, isEmpty);
      await ai.saveAPIKey('secret-key');
      expect(ai.canSend, isFalse, reason: 'no model yet');
      ai.setCloudModel('good-model');
      expect(ai.canSend, isTrue);
    });

    test('OpenAI format: the key in the header, the data in the system message, the answer streams and is saved', () async {
      ai.setCloudBaseURL(base());
      ai.setCloudModel('good-model');
      await ai.saveAPIKey('secret-key');
      chunks = [
        'data: {"choices":[{"delta":{"content":"שלום "}}]}',
        'data: not json',
        ': keep-alive',
        'data: {"choices":[{"delta":{"content":"עולם"}}]}',
        'data: [DONE]',
        'data: {"choices":[{"delta":{"content":"אחרי הסוף"}}]}',
      ];
      ai.send('כמה נשאר?', context: 'נטו 100');
      await Future<void>.delayed(Duration.zero);
      await untilDone();
      final (path, headers, body) = requests.single;
      expect(path, '/v1/chat/completions');
      expect(headers['authorization'], 'Bearer secret-key');
      expect(body['model'], 'good-model');
      expect(body['stream'], true);
      expect((body['messages'] as List).first['role'], 'system');
      expect((body['messages'] as List).first['content'], contains('נטו 100'));
      expect((body['messages'] as List).last['content'], 'כמה נשאר?');
      expect(jsonEncode(body), isNot(contains('secret-key')));
      expect(ai.messages.last.text, 'שלום עולם');
      expect(ai.messages.last.model, startsWith('good-model'));

      await ai.flush();
      expect(SecureFile.isEncrypted(File('${dir.path}/insights.json').readAsBytesSync()), isTrue);
      final again = InsightsEngine(await SharedPreferences.getInstance(), secure, keys);
      await again.load();
      expect(again.messages.map((m) => m.text), ['כמה נשאר?', 'שלום עולם']);
    });

    test('Anthropic format: its headers, system apart, and the conversation starts with the user', () async {
      ai.setProvider(CloudProvider.anthropic);
      ai.setCloudBaseURL(base());
      ai.setCloudModel('claude');
      await ai.saveAPIKey('ant-key');
      ai.messages = [InsightMessage(role: 'assistant', text: 'ישן')];
      chunks = [
        'event: message_start',
        'data: {"type":"message_start"}',
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"תשובה"}}',
        'data: {"type":"message_stop"}',
      ];
      ai.send('שאלה', context: 'נתונים');
      await Future<void>.delayed(Duration.zero);
      await untilDone();
      final (path, headers, body) = requests.single;
      expect(path, '/v1/messages');
      expect(headers['x-api-key'], 'ant-key');
      expect(headers['anthropic-version'], '2023-06-01');
      expect(headers.containsKey('authorization'), isFalse);
      expect(body['system'], contains('נתונים'));
      expect(body['max_tokens'], 4096);
      expect((body['messages'] as List).map((m) => m['role']), ['user']);
      expect(ai.messages.last.text, 'תשובה');
    });

    test('a refused request shows the error, keeps the question and saves no answer', () async {
      ai.setCloudBaseURL(base());
      ai.setCloudModel('m');
      await ai.saveAPIKey('k');
      status = 401;
      ai.send('שאלה', context: 'x');
      await Future<void>.delayed(Duration.zero);
      await untilDone();
      expect(ai.status, contains('401'));
      expect(ai.messages.single.role, 'user');
      expect(ai.isRunning, isFalse);
    });

    test('the models list leaves out what can\'t chat', () async {
      ai.setCloudBaseURL(base());
      await ai.saveAPIKey('k');
      await ai.loadCloudModels();
      expect(ai.cloudModels, ['good-model']);
    });

    test('LM Studio: only the chosen model is used', () async {
      ai.setEngine(AIEngine.lmStudio);
      ai.setServerURL(base());
      await ai.loadModels();
      expect(ai.models, ['good-model', 'whisper-1']);
      ai.setModel('gone');
      expect(ai.canSend, isFalse, reason: 'never falls back to another model');
      ai.setModel('good-model');
      expect(ai.canSend, isTrue);
      chunks = ['data: {"model":"other","choices":[{"delta":{"content":"ת"}}]}'];
      ai.send('ש', context: 'x');
      await Future<void>.delayed(Duration.zero);
      await untilDone();
      expect(requests.last.$3['model'], 'good-model');
      expect(requests.last.$2.containsKey('authorization'), isFalse, reason: 'no key goes to a local server');
      expect(ai.messages.last.model, contains('לא מודל ברירת המחדל'));
    });

    test('manual: the prompt goes to the clipboard, the pasted answer joins the conversation', () async {
      ai.setEngine(AIEngine.manual);
      await ai.loadModels();
      ai.send('שאלה ראשונה', context: 'נתוני הכסף');
      expect(copied, contains('נתוני הכסף'));
      expect(copied, contains('# השאלה שלי עכשיו\nשאלה ראשונה'));
      expect(ai.awaitingPaste, isTrue);
      expect(ai.canSend, isFalse);
      ai.submitManualAnswer('  תשובה מהאתר\n```chart\n{"data":[{"label":"א","value":1}]}\n```');
      expect(ai.awaitingPaste, isFalse);
      expect(ai.messages.last.model, startsWith('ידני'));
      ai.send('שאלה שנייה', context: 'נתוני הכסף');
      expect(copied, contains('# השיחה שלנו עד עכשיו'));
      expect(copied, contains('[תרשים: ]'));
    });

    test('signing out forgets the conversation, also an answer still on its way', () async {
      ai.setCloudBaseURL(base());
      ai.setCloudModel('m');
      await ai.saveAPIKey('k');
      chunks = ['data: {"choices":[{"delta":{"content":"סוד"}}]}'];
      ai.send('שאלה', context: 'x');
      ai.forgetConversation();
      await untilDone();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ai.flush();
      expect(ai.messages, isEmpty);
      expect(File('${dir.path}/insights.json').existsSync(), isFalse);
      expect(requests.where((r) => r.$1.endsWith('/chat/completions')), isEmpty, reason: 'nothing is sent after signing out');
      expect(await keys.read('api-key-openai'), 'k', reason: 'the key belongs to the device, like the Keychain');
    });
  });

  test('the summary for the model has the same numbers as the screens', () async {
    await initializeDateFormatting('he');
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('ctx');
    final store = await AppStore.open(dir, await SharedPreferences.getInstance(), _MemoryKeys());
    store.replace((jsonDecode(File('assets/demo_household.json').readAsStringSync()) as Map).cast<String, dynamic>());
    await store.flush();
    final text = aiContext(store);
    final p = MonthPicture.current(store.dashboard);
    expect(text, contains('נשאר מההכנסה האחרונה (לפי האפליקציה): ${Fmt.money(p.remaining)}'));
    expect(text, contains('## תלוש'));
    expect(text, contains('## חשבונות'));
    expect(text, contains('## כרטיס אשראי'));
    expect(text, contains('## מגמות'));
    expect(text, contains('## מעקב רכישות'));
    expect(text, contains('## תחזית'));
    final s = CardMonthSummary.of(CardData(store.money).chargedIn(CardData(store.money).cardBillingKeys.first));
    expect(text, contains('סה״כ ${Fmt.money(s.total)}'));
    expect(insightsDue(store.money, null), isTrue);
    expect(insightsDue(MoneyData(JObj({})), DateTime.now()), isFalse);
    await store.flush();
    dir.deleteSync(recursive: true);
  });
}

class _MemoryKeys implements KeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

class _Keys implements ApiKeyStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String account) async => map[account];
  @override
  Future<void> write(String account, String value) async => map[account] = value;
  @override
  Future<void> delete(String account) async => map.remove(account);
}
