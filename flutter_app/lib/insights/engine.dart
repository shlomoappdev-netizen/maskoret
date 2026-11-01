import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/secure_file.dart';
import 'segments.dart';

/// Where answers come from. There's no built-in model here (that's MLX, only on the Mac).
enum AIEngine {
  cloud('מודל בענן (מפתח API)'),
  manual('ידני — העתק והדבק מאתר צ׳אט'),
  lmStudio('LM Studio');

  const AIEngine(this.title);
  final String title;
}

enum CloudProvider {
  openai('OpenAI (ChatGPT)', 'https://api.openai.com/v1', 'https://platform.openai.com/api-keys'),
  anthropic('Anthropic (Claude)', 'https://api.anthropic.com/v1', 'https://console.anthropic.com/settings/keys'),
  gemini('Google Gemini', 'https://generativelanguage.googleapis.com/v1beta/openai', 'https://aistudio.google.com/apikey'),
  openrouter('OpenRouter', 'https://openrouter.ai/api/v1', 'https://openrouter.ai/keys'),
  custom('אחר (תואם OpenAI)', '', null);

  const CloudProvider(this.title, this.defaultBaseURL, this.keyPage);
  final String title;
  final String defaultBaseURL;
  final String? keyPage;
  bool get isAnthropic => this == anthropic;
}

/// Chat websites for the manual (copy & paste) mode.
const manualSites = {
  'ChatGPT': 'https://chatgpt.com',
  'Claude': 'https://claude.ai/new',
  'Gemini': 'https://gemini.google.com/app',
  'Perplexity': 'https://www.perplexity.ai',
  'Copilot': 'https://copilot.microsoft.com',
};

/// API keys live in the system's secure storage, one per provider, never in the household or on the server.
abstract class ApiKeyStore {
  Future<String?> read(String account);
  Future<void> write(String account, String value);
  Future<void> delete(String account);
}

class SystemApiKeyStore implements ApiKeyStore {
  static const _storage = FlutterSecureStorage();
  static String _name(String account) => 'maskoret-ai-$account';

  @override
  Future<String?> read(String account) => _storage.read(key: _name(account));
  @override
  Future<void> write(String account, String value) => _storage.write(key: _name(account), value: value);
  @override
  Future<void> delete(String account) => _storage.delete(key: _name(account));
}

class InsightMessage {
  InsightMessage({required this.role, required this.text, DateTime? date, this.auto = false, this.model})
      : date = date ?? DateTime.now();
  final String role; // "user" | "assistant"
  final String text;
  final DateTime date;
  final bool auto;
  final String? model;

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        'date': date.toIso8601String(),
        if (auto) 'auto': true,
        if (model != null) 'model': model,
      };

  static InsightMessage fromJson(Map<String, dynamic> j) => InsightMessage(
      role: j['role'] as String? ?? 'user',
      text: j['text'] as String? ?? '',
      date: DateTime.tryParse(j['date'] as String? ?? ''),
      auto: j['auto'] == true,
      model: j['model'] as String?);
}

class _HttpFailure implements Exception {
  _HttpFailure(this.message);
  final String message;
}

/// The conversation with the model and the three ways of reaching one — port of InsightsEngine and CloudAI.swift.
/// The financial summary goes only to the chosen model, and to the cloud only when the user asks.
class InsightsEngine extends ChangeNotifier {
  InsightsEngine(this.prefs, this.secure, this.keys, {Future<void> Function(String)? copy})
      : _copy = copy ?? ((t) => Clipboard.setData(ClipboardData(text: t))) {
    engine = AIEngine.values.firstWhere((e) => e.name == prefs.getString('aiEngine'), orElse: () => AIEngine.cloud);
    cloudProvider = CloudProvider.values.firstWhere((p) => p.name == prefs.getString('aiCloudProvider'), orElse: () => CloudProvider.openai);
    cloudBaseURL = prefs.getString('aiCloudBase') ?? cloudProvider.defaultBaseURL;
    cloudModel = prefs.getString('aiCloudModel') ?? '';
    serverURL = prefs.getString('aiServerURL') ?? defaultURL;
    model = prefs.getString('aiModel') ?? '';
    manualSite = prefs.getString('aiManualSite') ?? manualSites.keys.first;
    autoInsights = prefs.getBool('aiAuto') ?? true;
  }

  static const defaultURL = 'http://127.0.0.1:1234/v1';
  static const defaultAnalysis =
      'תסתכל על כל הנתונים ותן לי 3–5 תובנות חשובות על המצב הכספי שלי החודש: מה בולט, איפה אני חורג, ואיפה אפשר לשפר. הוסף תרשים אחד שממחיש את הנקודה הכי חשובה.';
  static const systemPrompt = '''
אתה יועץ תקציב אישי של המשתמש, בתוך האפליקציה ״מחשבון שכר״. ענה תמיד בעברית, קצר, ברור וממוקד.
השתמש רק בנתונים שמופיעים למטה ובמה שהמשתמש כתב בשיחה. אל תמציא מספרים. סכומים בשקלים (₪).
הנתונים מגיעים מהאפליקציה: נטו, ניכויים, הוצאות קבועות, חשבונות וחיסכון, חיובי אשראי לפי חודש וקטגוריה, תשלומים, מגמות ותחזית.
חיוב אשראי ש״מצומד״ להוצאה קבועה כבר נספר בהוצאה הקבועה — אל תספור אותו פעמיים.

כשתרשים יעזור להבין — הוסף תרשים בבלוק בדיוק בפורמט הזה (JSON תקין, עד 8 נקודות):
```chart
{"type":"bar","title":"כותרת","data":[{"label":"שם","value":123}]}
```
type יכול להיות bar, line או pie. אל תוסיף יותר מ-2 תרשימים בתשובה.

בסוף כל תשובה שאל שאלה אחת או שתיים ממוקדות שיעזרו לנהל את התקציב טוב יותר בהמשך
(למשל: מטרה לחיסכון, הוצאה שלא ברורה, תקרה למגמה). כתוב אותן אחרי הכותרת ״שאלות:״.''';

  final SharedPreferences prefs;
  final SecureFile secure;
  final ApiKeyStore keys;
  final Future<void> Function(String) _copy;

  late AIEngine engine;
  late CloudProvider cloudProvider;
  late String cloudBaseURL;
  late String cloudModel;
  late String serverURL;
  late String model;
  late String manualSite;
  late bool autoInsights;

  List<String> cloudModels = [];
  List<String> models = [];
  bool hasCloudKey = false;
  String? _key;
  bool? connected;
  String status = '';
  List<InsightMessage> messages = [];
  String streaming = '';
  bool isRunning = false;
  bool awaitingPaste = false;
  String manualPrompt = '';
  HttpClient? _client;
  bool _stopped = false;

  /// Bumped when the conversation is forgotten, so an answer still on its way isn't saved afterwards.
  int _generation = 0;

  File get _file => File('${secure.folder.path}/insights.json');

  DateTime? get lastAutoAt => DateTime.tryParse(prefs.getString('aiLastAuto') ?? '');

  /// Loads the saved conversation (encrypted, next to the household copy).
  Future<void> load() async {
    try {
      final text = await secure.read(_file);
      if (text == null) return;
      messages = [for (final m in jsonDecode(text) as List) InsightMessage.fromJson((m as Map).cast<String, dynamic>())];
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _pending = Future.value();

  void _save() {
    final trimmed = messages.length > 200 ? messages.sublist(messages.length - 200) : messages;
    final text = jsonEncode(trimmed);
    _pending = _pending.then((_) => secure.write(_file, text)).catchError((Object _) {});
  }

  /// Waits for the conversation to reach the disk (tests).
  Future<void> flush() => _pending;

  // MARK: Settings

  void setEngine(AIEngine e) {
    engine = e;
    prefs.setString('aiEngine', e.name);
    notifyListeners();
    loadModels();
  }

  void setProvider(CloudProvider p) {
    cloudProvider = p;
    cloudBaseURL = p.defaultBaseURL;
    cloudModels = [];
    _key = null;
    prefs.setString('aiCloudProvider', p.name);
    prefs.setString('aiCloudBase', cloudBaseURL);
    loadModels();
  }

  void setCloudBaseURL(String v) {
    cloudBaseURL = v;
    prefs.setString('aiCloudBase', v);
  }

  void setCloudModel(String v) {
    cloudModel = v;
    prefs.setString('aiCloudModel', v);
    refreshStatus();
  }

  void setServerURL(String v) {
    serverURL = v;
    prefs.setString('aiServerURL', v);
  }

  void setModel(String v) {
    model = v;
    prefs.setString('aiModel', v);
    refreshStatus();
  }

  void setManualSite(String v) {
    manualSite = v;
    prefs.setString('aiManualSite', v);
    refreshStatus();
  }

  void setAuto(bool v) {
    autoInsights = v;
    prefs.setBool('aiAuto', v);
    notifyListeners();
  }

  String get _keyAccount => 'api-key-${cloudProvider.name}';

  Future<String?> _apiKey() async => _key ??= await keys.read(_keyAccount);

  Future<void> saveAPIKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await keys.delete(_keyAccount);
    } else {
      await keys.write(_keyAccount, trimmed);
    }
    _key = trimmed.isEmpty ? null : trimmed;
    hasCloudKey = trimmed.isNotEmpty;
    connected = hasCloudKey;
    refreshStatus();
  }

  String _trimmedBase(String s) => s.trim().replaceFirst(RegExp(r'/+$'), '');
  String get _cloudBase => _trimmedBase(cloudBaseURL.trim().isEmpty ? cloudProvider.defaultBaseURL : cloudBaseURL);

  Map<String, String> _authHeaders(String key) => cloudProvider.isAnthropic
      ? {'x-api-key': key, 'anthropic-version': '2023-06-01'}
      : {'authorization': 'Bearer $key'};

  // MARK: Models

  Future<void> loadModels() async {
    switch (engine) {
      case AIEngine.cloud:
        hasCloudKey = ((await _apiKey()) ?? '').isNotEmpty;
        connected = hasCloudKey;
        refreshStatus();
      case AIEngine.manual:
        connected = true;
        refreshStatus();
      case AIEngine.lmStudio:
        await _loadLocalModels();
    }
  }

  Future<dynamic> _getJson(Uri url, Map<String, String> headers, Duration timeout) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) throw _HttpFailure('${response.statusCode}');
      return jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }

  static List<String> _ids(dynamic json) => [
        if (json is Map && json['data'] is List)
          for (final m in json['data'] as List)
            if (m is Map && m['id'] is String) m['id'] as String
      ];

  Future<void> _loadLocalModels() async {
    final uri = Uri.tryParse('${_trimmedBase(serverURL)}/models');
    if (uri == null || !uri.hasScheme) {
      connected = false;
      status = 'כתובת השרת לא תקינה';
      notifyListeners();
      return;
    }
    try {
      models = _ids(await _getJson(uri, const {}, const Duration(seconds: 5))).where((m) => !m.toLowerCase().contains('embed')).toList();
      connected = true;
      refreshStatus();
    } catch (_) {
      connected = false;
      status = 'אין חיבור ל-LM Studio';
      notifyListeners();
    }
  }

  /// Lists the provider's models (so the name doesn't have to be typed).
  Future<void> loadCloudModels() async {
    final key = await _apiKey();
    final uri = Uri.tryParse('$_cloudBase/models');
    if (key == null || key.isEmpty || uri == null) return;
    try {
      final ids = _ids(await _getJson(uri, _authHeaders(key), const Duration(seconds: 15)));
      cloudModels = ids.where((id) {
        final l = id.toLowerCase();
        return !l.contains('embed') && !l.contains('whisper') && !l.contains('tts') && !l.contains('dall') && !l.contains('image');
      }).toList()
        ..sort();
      status = cloudModels.isEmpty ? 'לא התקבלה רשימת מודלים — כתוב את שם המודל ידנית' : 'נמצאו ${cloudModels.length} מודלים';
    } on _HttpFailure catch (e) {
      status = 'המפתח לא התקבל (${e.message}) — בדוק אותו';
    } catch (_) {
      status = 'לא הצלחתי להתחבר לספק';
    }
    notifyListeners();
  }

  /// Only the chosen model may answer — no automatic fallback to another one.
  bool get canSend => switch (engine) {
        AIEngine.lmStudio => connected == true && model.isNotEmpty && models.contains(model),
        AIEngine.cloud => hasCloudKey && cloudModel.trim().isNotEmpty,
        AIEngine.manual => !awaitingPaste,
      };

  /// The name shown next to answers and in the header.
  String get activeModelName => switch (engine) {
        AIEngine.lmStudio => model,
        AIEngine.cloud => cloudModel.isEmpty ? '' : '$cloudModel · ${cloudProvider.title}',
        AIEngine.manual => 'ידני · $manualSite',
      };

  void refreshStatus() {
    switch (engine) {
      case AIEngine.cloud:
        status = !hasCloudKey
            ? 'הכנס מפתח API בהגדרות (⚙︎)'
            : cloudModel.isEmpty
                ? 'כתוב איזה מודל להשתמש בהגדרות (⚙︎)'
                : 'מחובר ל-${cloudProvider.title} · הנתונים נשלחים לשרת שלהם';
      case AIEngine.manual:
        status = awaitingPaste
            ? 'הפרומפט הועתק — הדבק אותו ב-$manualSite, ואז הדבק כאן את התשובה'
            : 'ידני: השאלה תועתק ללוח, ואת התשובה מדביקים כאן';
      case AIEngine.lmStudio:
        if (connected == true) {
          status = models.isEmpty
              ? 'השרת פועל, אבל אין מודלים זמינים'
              : model.isEmpty
                  ? 'בחר מודל ברירת מחדל בהגדרות (⚙︎)'
                  : !models.contains(model)
                      ? 'מודל ברירת המחדל לא נמצא ב-LM Studio — לא נשלח כלום'
                      : 'מחובר ל-LM Studio';
        }
    }
    notifyListeners();
  }

  // MARK: Chat

  void send(String prompt, {required String context, bool auto = false}) {
    final text = prompt.trim();
    if (text.isEmpty || isRunning || !canSend) return;
    messages = [...messages, InsightMessage(role: 'user', text: text, auto: auto)];
    _save();
    if (auto) prefs.setString('aiLastAuto', DateTime.now().toIso8601String());
    _run(context);
    notifyListeners();
  }

  void stop() {
    _stopped = true;
    _client?.close(force: true);
  }

  void clear() {
    stop();
    messages = [];
    streaming = '';
    awaitingPaste = false;
    manualPrompt = '';
    _save();
    notifyListeners();
  }

  /// Signing out: the conversation talks about that account's money, and its file was already deleted.
  void forgetConversation() {
    _generation++;
    stop();
    messages = [];
    streaming = '';
    awaitingPaste = false;
    manualPrompt = '';
    // A save that was already queued mustn't bring the file back.
    _pending = _pending.then((_) async {
      if (_file.existsSync()) await _file.delete();
    }).catchError((Object _) {});
    notifyListeners();
  }

  List<(String, String)> _turns() {
    final recent = messages.length > 12 ? messages.sublist(messages.length - 12) : messages;
    return [
      for (final m in recent)
        () {
          final parts = <String>[
            for (final s in InsightParser.parse(m.text))
              if (s is TextSegment) s.text else if (s is ChartSegment) '[תרשים: ${s.spec.title ?? ''}]'
          ];
          return (m.role, parts.isEmpty ? m.text : parts.join('\n'));
        }()
    ];
  }

  void _run(String context) {
    final system = '$systemPrompt\n\n# הנתונים\n$context';
    final turns = _turns();
    switch (engine) {
      case AIEngine.manual:
        _prepareManual(system, turns);
      case AIEngine.cloud:
        _runCloud(system, turns);
      case AIEngine.lmStudio:
        _runLocal(system, turns);
    }
  }

  void _runLocal(String system, List<(String, String)> turns) {
    final uri = Uri.tryParse('${_trimmedBase(serverURL)}/chat/completions');
    if (uri == null) return;
    final used = model;
    String? answeredBy;
    _stream(
      uri,
      const {},
      {
        'messages': [
          {'role': 'system', 'content': system},
          for (final (role, text) in turns) {'role': role, 'content': text},
        ],
        'stream': true,
        'temperature': 0.4,
        'model': used,
      },
      working: 'המודל חושב…',
      piece: (json) {
        final m = json['model'];
        if (answeredBy == null && m is String && m.isNotEmpty) answeredBy = m;
        return _openAIPiece(json);
      },
      // Flag it if LM Studio answered with a different model than the default.
      label: () {
        final by = answeredBy;
        return by != null && !by.contains(used) && !used.contains(by) ? '$by ⚠︎ לא מודל ברירת המחדל' : used;
      },
      onFailure: () => connected = false,
    );
  }

  Future<void> _runCloud(String system, List<(String, String)> turns) async {
    final generation = _generation;
    final key = await _apiKey();
    if (generation != _generation) return; // signed out meanwhile: nothing is sent.
    if (key == null || key.isEmpty) {
      status = 'אין מפתח API';
      notifyListeners();
      return;
    }
    final anthropic = cloudProvider.isAnthropic;
    final uri = Uri.tryParse(_cloudBase + (anthropic ? '/messages' : '/chat/completions'));
    if (uri == null) return;
    // Anthropic's messages must start with the user.
    var list = turns;
    if (anthropic) list = turns.skipWhile((t) => t.$1 == 'assistant').toList();
    final messageList = [for (final (role, text) in list) {'role': role, 'content': text}];
    final name = activeModelName;
    _stream(
      uri,
      _authHeaders(key),
      {
        'model': cloudModel.trim(),
        'stream': true,
        if (anthropic) ...{
          'system': system,
          'max_tokens': 4096,
          'messages': messageList,
        } else
          'messages': [
            {'role': 'system', 'content': system},
            ...messageList,
          ],
      },
      working: 'שולח ל-${cloudProvider.title}…',
      answering: 'המודל עונה…',
      piece: (json) {
        if (!anthropic) return _openAIPiece(json);
        final delta = json['delta'];
        return json['type'] == 'content_block_delta' && delta is Map ? delta['text'] as String? : null;
      },
      label: () => name,
    );
  }

  static String? _openAIPiece(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) return null;
    final delta = (choices.first as Map)['delta'];
    final content = delta is Map ? delta['content'] : null;
    return content is String ? content : null;
  }

  Future<void> _stream(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body, {
    required String working,
    String? answering,
    required String? Function(Map<String, dynamic>) piece,
    required String Function() label,
    VoidCallback? onFailure,
  }) async {
    isRunning = true;
    streaming = '';
    status = working;
    _stopped = false;
    notifyListeners();
    var output = '';
    String? failure;
    final generation = _generation;
    final client = _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      headers.forEach(request.headers.set);
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      if (response.statusCode >= 400) {
        final text = await response.transform(utf8.decoder).join();
        throw _HttpFailure('שגיאה ${response.statusCode}: ${text.length > 300 ? text.substring(0, 300) : text}');
      }
      if (answering != null) status = answering;
      await for (final line in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (_stopped) break;
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') break;
        Map<String, dynamic>? json;
        try {
          json = (jsonDecode(payload) as Map).cast<String, dynamic>();
        } catch (_) {
          continue;
        }
        final p = piece(json);
        if (p != null && generation == _generation) {
          output += p;
          streaming = output;
          notifyListeners();
        }
      }
    } on _HttpFailure catch (e) {
      failure = e.message;
    } catch (_) {
      if (!_stopped) failure = 'אין חיבור לשרת';
    } finally {
      client.close(force: true);
      _client = null;
    }
    if (generation != _generation) {
      isRunning = false;
      return;
    }
    if (output.isNotEmpty) {
      messages = [...messages, InsightMessage(role: 'assistant', text: output, model: label())];
      _save();
    }
    streaming = '';
    isRunning = false;
    if (failure != null) {
      onFailure?.call();
      status = 'הבקשה נכשלה: $failure';
      notifyListeners();
    } else {
      refreshStatus();
    }
  }

  // MARK: Manual

  void _prepareManual(String system, List<(String, String)> turns) {
    final text = StringBuffer('$system\n\n');
    if (turns.length > 1) {
      text.write('# השיחה שלנו עד עכשיו\n');
      for (final (role, t) in turns.sublist(0, turns.length - 1)) {
        text.write('${role == 'user' ? 'אני: ' : 'אתה: '}$t\n\n');
      }
    }
    text.write('# השאלה שלי עכשיו\n${turns.isEmpty ? '' : turns.last.$2}');
    manualPrompt = text.toString();
    copyManualPrompt();
    awaitingPaste = true;
    refreshStatus();
  }

  Future<void> copyManualPrompt() => _copy(manualPrompt);

  Future<void> openManualSite() async {
    final url = manualSites[manualSite];
    if (url != null) await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Saves the answer that was pasted back from the website.
  void submitManualAnswer(String text) {
    final answer = text.trim();
    if (answer.isEmpty) return;
    messages = [...messages, InsightMessage(role: 'assistant', text: answer, model: 'ידני · $manualSite')];
    _save();
    awaitingPaste = false;
    manualPrompt = '';
    refreshStatus();
  }

  void cancelManual() {
    awaitingPaste = false;
    refreshStatus();
  }
}
