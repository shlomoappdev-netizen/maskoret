import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/json.dart';
import '../state/secure_file.dart';
import '../state/store.dart';
import 'ai_account.dart';
import 'ai_actions.dart';
import 'segments.dart';

/// Where answers come from: a cloud model with the user's own API key, or copy-paste to a chat website.
enum AIEngine {
  cloud('מודל בענן (מפתח API)'),
  manual('ידני — העתק והדבק מאתר צ׳אט');

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
  InsightMessage({
    required this.role,
    required this.text,
    String? id,
    DateTime? date,
    this.auto = false,
    this.model,
    this.label,
    this.images = const [],
    int? imageCount,
    this.applied,
    this.dismissed = false,
    this.actionError,
  })  : id = id ?? newId(),
        date = date ?? DateTime.now(),
        imageCount = imageCount ?? images.length;
  final String id;
  final String role; // "user" | "assistant"
  final String text;
  final DateTime date;
  final bool auto;
  final String? model;

  /// What the conversation shows instead of the text sent to the model (e.g. a quick action's long prompt).
  final String? label;

  /// Pictures the user attached (base64 JPEG). They stay on this device; other devices see only how many there were.
  final List<String> images;
  final int imageCount;

  /// Proposed changes (```actions) the user applied, by index, or dismissed.
  List<int>? applied;
  bool dismissed;
  String? actionError;

  String get shownText => auto ? '✨ תובנות אוטומטיות' : (label ?? text);

  /// The shape both apps keep in the account (and on this device, with the pictures).
  Map<String, dynamic> toJson({bool withImages = true}) => {
        'id': id,
        'role': role,
        'text': text,
        'date': date.toUtc().toIso8601String(),
        if (auto) 'auto': true,
        if (model != null) 'model': model,
        if (label != null) 'label': label,
        if (withImages && images.isNotEmpty) 'images': images,
        if (imageCount > 0) 'imageCount': imageCount,
        if (applied != null) 'applied': applied,
        if (dismissed) 'dismissed': true,
        if (actionError != null) 'actionError': actionError,
      };

  static InsightMessage fromJson(Map<String, dynamic> j) => InsightMessage(
        id: j['id'] is String ? (j['id'] as String).toUpperCase() : null,
        role: j['role'] as String? ?? 'user',
        text: j['text'] as String? ?? '',
        date: DateTime.tryParse(j['date'] as String? ?? '')?.toLocal(),
        auto: j['auto'] == true,
        model: j['model'] as String?,
        label: j['label'] as String?,
        images: (j['images'] as List?)?.whereType<String>().toList() ?? const [],
        imageCount: (j['imageCount'] as num?)?.toInt(),
        applied: (j['applied'] as List?)?.whereType<num>().map((n) => n.toInt()).toList(),
        dismissed: j['dismissed'] == true,
        actionError: j['actionError'] as String?,
      );
}

/// One turn of the conversation as the model gets it.
class AITurn {
  AITurn(this.role, this.text, [this.images = const []]);
  final String role;
  final String text;
  final List<String> images;
}

class _HttpFailure implements Exception {
  _HttpFailure(this.message);
  final String message;
}

/// The conversation with the model and the three ways of reaching one — port of InsightsEngine and CloudAI.swift.
/// The financial summary goes only to the chosen model, and to the cloud only when the user asks.
class InsightsEngine extends ChangeNotifier {
  InsightsEngine(this.prefs, this.secure, this.keys, {Future<void> Function(String)? copy, this.account})
      : _copy = copy ?? ((t) => Clipboard.setData(ClipboardData(text: t))) {
    keyInAccount = prefs.getBool('aiKeyInAccount') ?? true;
    engine = AIEngine.values.firstWhere((e) => e.name == prefs.getString('aiEngine'), orElse: () => AIEngine.cloud);
    cloudProvider = CloudProvider.values.firstWhere((p) => p.name == prefs.getString('aiCloudProvider'), orElse: () => CloudProvider.openai);
    cloudBaseURL = prefs.getString('aiCloudBase') ?? cloudProvider.defaultBaseURL;
    cloudModel = prefs.getString('aiCloudModel') ?? '';
    manualSite = prefs.getString('aiManualSite') ?? manualSites.keys.first;
  }

  static const defaultAnalysis =
      'תסתכל על כל הנתונים ותן לי 3–5 תובנות חשובות על המצב הכספי שלי החודש: מה בולט, איפה אני חורג, ואיפה אפשר לשפר. הוסף תרשים אחד שממחיש את הנקודה הכי חשובה, ואם יש שינוי שכדאי לעשות — הצע אותו כפעולה.';
  static const systemPrompt = '''
אתה העוזר הפיננסי של המשתמש בתוך האפליקציה ״מחשבון שכר״. ענה תמיד בעברית, קצר, ברור וממוקד, בלי הקדמות.
השתמש רק בנתונים שמופיעים למטה, במה שהמשתמש כתב ובתמונות שצירף. אל תמציא מספרים. סכומים בשקלים (₪).
הנתונים מגיעים מהאפליקציה: נטו, ניכויים, הוצאות קבועות, חשבונות וחיסכון, חיובי אשראי לפי חודש וקטגוריה, תשלומים, מגמות ותחזית.
חיוב אשראי ש״מצומד״ להוצאה קבועה כבר נספר בהוצאה הקבועה — אל תספור אותו פעמיים.

## תרשימים
כשתרשים עוזר להבין, הוסף בלוק בדיוק בפורמט הזה (JSON תקין, עד 8 נקודות, עד 2 תרשימים בתשובה):
```chart
{"type":"bar","title":"כותרת","data":[{"label":"שם","value":123}]}
```
type: bar, line או pie.

## פעולות באפליקציה
אתה יכול להציע שינויים בנתונים, והמשתמש מאשר אותם בלחיצה לפני שהם מתבצעים. הצע שינוי כשהמשתמש מבקש להכניס או לעדכן
נתונים (למשל מצילום מסך של חיסכון — העתק בדיוק את מה שמופיע בתמונה), או כשההמלצה שלך דורשת שינוי (תקרה למגמה,
הפקדה לחיסכון, הוצאה מתוכננת). כתוב קודם במשפט או שניים מה אתה מציע ולמה, ואז בלוק אחד בפורמט הזה (JSON תקין):
```actions
{"summary":"תיאור קצר","actions":[{"type":"update_account","account":"שם החשבון","balance":12500}]}
```
הסוגים והשדות (רק השדות שמשתנים; תאריכים בפורמט YYYY-MM-DD; שמות בדיוק כמו בנתונים):
- add_account: name, kind (savings=חיסכון נזיל, deposit=פיקדון/תוכנית חיסכון, pension=פנסיה), balance, balance_date, annual_rate (אחוז), rate_type (fixed/prime), prime_minus, monthly_contribution, contribution_day, start_date, maturity_date, note
- update_account: account (השם הקיים), new_name, ואותם שדות כמו add_account. balance = יתרה עדכנית (נרשמת כעדכון יתרה).
- add_trend: name, emoji, monthly_limit
- update_trend: trend (השם הקיים), monthly_limit (0 = בלי תקרה), new_name, emoji
- add_expense: name, amount, charge_day, to_account (אם זו הפקדה קבועה לחיסכון)
- update_expense: expense (השם הקיים), amount, active (true/false), charge_day, new_name
- add_transaction: title, amount, date, kind (expense/income/transfer), account (מאיזה חשבון; ברירת מחדל עו״ש), to_account (בהעברה), paid_by_card (true/false), installments, note
לכל פעולה אפשר להוסיף why — משפט קצר למה.
כשמשתמש צריך לקנות משהו יקר ולא צפוי: בדוק מאיפה כדאי לממן (עו״ש, חיסכון נזיל, תשלומים באשראי), מה ההשפעה על התחזית,
והצע את השינויים: הוצאה מתוכננת, העברה מחיסכון אם צריך, והורדת תקרות במגמות לחודשים הקרובים.
אל תציע פעולות בלי סיבה, ואל תחזור על פעולות שכבר בוצעו.

אם חסר לך מידע חשוב — שאל שאלה אחת ממוקדת בסוף התשובה.''';

  final SharedPreferences prefs;
  final SecureFile secure;
  final ApiKeyStore keys;

  /// The user's account (key and conversation shared by their devices); null in tests and when signed out.
  final AIAccount? account;
  final Future<void> Function(String) _copy;

  late AIEngine engine;
  late CloudProvider cloudProvider;
  late String cloudBaseURL;
  late String cloudModel;
  late String manualSite;

  List<String> cloudModels = [];
  bool hasCloudKey = false;

  /// Save the key in the account too, so the user's other devices get it.
  late bool keyInAccount;

  /// The result of "בדוק חיבור", shown under the button.
  (bool, String)? connectionCheck;
  bool checkingConnection = false;

  /// Undo of the last applied change list: the message, and the member's data from before it.
  (String, Map<String, dynamic>)? undo;

  DateTime? get clearedAt => DateTime.tryParse(prefs.getString('aiClearedAt') ?? '');
  set clearedAt(DateTime? v) => v == null ? prefs.remove('aiClearedAt') : prefs.setString('aiClearedAt', v.toUtc().toIso8601String());
  Timer? _pushTimer;
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

  void _save({bool push = true}) {
    final trimmed = messages.length > 200 ? messages.sublist(messages.length - 200) : messages;
    final text = jsonEncode([for (final m in trimmed) m.toJson()]);
    _pending = _pending.then((_) => secure.write(_file, text)).catchError((Object _) {});
    if (push) _schedulePush();
  }

  // MARK: The conversation on the user's other devices

  void _schedulePush({bool now = false}) {
    final acc = account;
    if (acc == null || !acc.signedIn) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(now ? Duration.zero : const Duration(seconds: 2), () async {
      final list = messages.length > 200 ? messages.sublist(messages.length - 200) : messages;
      try {
        await acc.saveConversation([for (final m in list) m.toJson(withImages: false)], clearedAt);
      } catch (_) {}
    });
  }

  /// Brings in what the user's other devices wrote, merged with this device's messages (by id).
  Future<void> pullConversation() async {
    final acc = account;
    if (acc == null || !acc.signedIn) return;
    SavedConversation? saved;
    try {
      saved = await acc.conversation();
    } catch (_) {
      return;
    }
    if (saved == null) {
      if (messages.isNotEmpty) _schedulePush(now: true);
      return;
    }
    final remoteCleared = saved.clearedAt;
    final localCleared = clearedAt;
    if (remoteCleared != null && (localCleared == null || remoteCleared.isAfter(localCleared))) clearedAt = remoteCleared;
    final since = clearedAt;
    bool keep(InsightMessage m) => since == null || m.date.isAfter(since);
    final byID = <String, InsightMessage>{for (final m in messages.where(keep)) m.id.toUpperCase(): m};
    for (final j in saved.messages) {
      final m = InsightMessage.fromJson(j);
      if (!keep(m)) continue;
      final local = byID[m.id];
      if (local == null) {
        byID[m.id] = m;
      } else {
        // Same message on both: keep this device's pictures, take the newest decision on its changes.
        if (local.applied == null && m.applied != null) {
          local.applied = m.applied;
          local.actionError = m.actionError;
        }
        if (m.dismissed) local.dismissed = true;
      }
    }
    final merged = byID.values.toList()..sort((a, b) => a.date.compareTo(b.date));
    final list = merged.length > 200 ? merged.sublist(merged.length - 200) : merged;
    final changed = list.length != messages.length ||
        [for (var i = 0; i < list.length; i++) list[i].id != messages[i].id || list[i].applied != messages[i].applied].any((x) => x);
    if (changed) {
      messages = list;
      _save(push: false);
      notifyListeners();
    }
    if (list.length != saved.messages.length || remoteCleared != clearedAt) _schedulePush(now: true);
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

  void setManualSite(String v) {
    manualSite = v;
    prefs.setString('aiManualSite', v);
    refreshStatus();
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
    connectionCheck = null;
    refreshStatus();
    final acc = account;
    if (acc != null && acc.signedIn) {
      try {
        if (trimmed.isEmpty) {
          await acc.deleteKey(cloudProvider.name);
        } else if (keyInAccount) {
          await acc.saveKey(cloudProvider.name, trimmed, cloudModel.trim(), cloudProvider == CloudProvider.custom ? cloudBaseURL : '');
        }
      } catch (_) {}
    }
  }

  void setKeyInAccount(bool v) {
    keyInAccount = v;
    prefs.setBool('aiKeyInAccount', v);
    notifyListeners();
    if (v) _apiKey().then((k) { if (k != null && k.isNotEmpty) pushKeySettings(key: k); });
  }

  /// Saves the key (or, without one, only the model and address) in the account.
  Future<void> pushKeySettings({String? key}) async {
    final acc = account;
    if (acc == null || !acc.signedIn || !keyInAccount || (key == null && !hasCloudKey)) return;
    try {
      await acc.saveKey(cloudProvider.name, key, cloudModel.trim(), cloudProvider == CloudProvider.custom ? cloudBaseURL : '');
    } catch (_) {}
  }

  /// No key on this device: take the one saved in the account (the chosen provider's, else the newest).
  Future<void> _pullKeyFromAccount() async {
    final acc = account;
    if (acc == null || !acc.signedIn) return;
    List<SavedAIKey> saved;
    try {
      saved = await acc.keys();
    } catch (_) {
      return;
    }
    if (saved.isEmpty) return;
    final pick = saved.where((k) => k.provider == cloudProvider.name).firstOrNull ?? saved.first;
    final provider = CloudProvider.values.where((p) => p.name == pick.provider).firstOrNull;
    if (provider == null || pick.apiKey.isEmpty) return;
    if (provider != cloudProvider) {
      cloudProvider = provider;
      prefs.setString('aiCloudProvider', provider.name);
    }
    setCloudBaseURL(pick.baseURL.isEmpty ? provider.defaultBaseURL : pick.baseURL);
    if (pick.model.isNotEmpty) {
      cloudModel = pick.model;
      prefs.setString('aiCloudModel', pick.model);
    }
    await keys.write(_keyAccount, pick.apiKey);
    _key = pick.apiKey;
  }

  /// "בדוק חיבור": asks the provider for its models with the key, and says whether the chosen model is there.
  Future<void> testConnection() async {
    connectionCheck = null;
    if (engine == AIEngine.manual) {
      connectionCheck = (true, 'במצב ידני אין חיבור לבדוק — השאלה מועתקת ללוח.');
      notifyListeners();
      return;
    }
    final key = await _apiKey();
    if (key == null || key.isEmpty) {
      connectionCheck = (false, 'אין מפתח API שמור');
      notifyListeners();
      return;
    }
    final uri = Uri.tryParse('$_cloudBase/models');
    if (uri == null || !uri.hasScheme) {
      connectionCheck = (false, 'כתובת ה-API לא תקינה');
      notifyListeners();
      return;
    }
    checkingConnection = true;
    notifyListeners();
    try {
      final ids = _ids(await _getJson(uri, _authHeaders(key), const Duration(seconds: 15)));
      if (ids.isNotEmpty) cloudModels = _filtered(ids);
      final model = cloudModel.trim();
      if (model.isEmpty) {
        connectionCheck = (true, 'המפתח תקין ✓ — עכשיו בחר מודל.');
      } else if (ids.isNotEmpty && !ids.contains(model)) {
        connectionCheck = (false, 'המפתח תקין, אבל המודל ״$model״ לא קיים אצל הספק. בחר מהרשימה.');
      } else {
        connectionCheck = (true, 'החיבור תקין ✓');
      }
      hasCloudKey = true;
      connected = true;
    } on _HttpFailure catch (e) {
      connectionCheck = (false, e.message == '401' || e.message == '403'
          ? 'הספק דחה את המפתח (${e.message}). בדוק שהעתקת אותו נכון.'
          : 'הספק החזיר שגיאה ${e.message}.');
    } catch (_) {
      connectionCheck = (false, 'אין חיבור לספק');
    }
    checkingConnection = false;
    refreshStatus();
  }

  static List<String> _filtered(List<String> ids) => ids.where((id) {
        final l = id.toLowerCase();
        return !l.contains('embed') && !l.contains('whisper') && !l.contains('tts') && !l.contains('dall') &&
            !l.contains('image') && !l.contains('aqa') && !l.contains('imagen') && !l.contains('veo');
      }).toList()
        ..sort();

  String _trimmedBase(String s) => s.trim().replaceFirst(RegExp(r'/+$'), '');
  String get _cloudBase => _trimmedBase(cloudBaseURL.trim().isEmpty ? cloudProvider.defaultBaseURL : cloudBaseURL);

  Map<String, String> _authHeaders(String key) => cloudProvider.isAnthropic
      ? {'x-api-key': key, 'anthropic-version': '2023-06-01'}
      : {'authorization': 'Bearer $key'};

  // MARK: Models

  Future<void> loadModels() async {
    switch (engine) {
      case AIEngine.cloud:
        if (((await _apiKey()) ?? '').isEmpty) await _pullKeyFromAccount();
        hasCloudKey = ((await _apiKey()) ?? '').isNotEmpty;
        connected = hasCloudKey;
        refreshStatus();
      case AIEngine.manual:
        connected = true;
        refreshStatus();
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
            if (m is Map && m['id'] is String) (m['id'] as String).replaceFirst('models/', '')
      ];

  /// Lists the provider's models (so the name doesn't have to be typed).
  Future<void> loadCloudModels() async {
    final key = await _apiKey();
    final uri = Uri.tryParse('$_cloudBase/models');
    if (key == null || key.isEmpty || uri == null) return;
    try {
      final ids = _ids(await _getJson(uri, _authHeaders(key), const Duration(seconds: 15)));
      cloudModels = _filtered(ids);
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
        AIEngine.cloud => hasCloudKey && cloudModel.trim().isNotEmpty,
        AIEngine.manual => !awaitingPaste,
      };

  /// The name shown next to answers and in the header.
  String get activeModelName => switch (engine) {
        AIEngine.cloud => cloudModel.isEmpty ? '' : cloudModel,
        AIEngine.manual => 'ידני · $manualSite',
      };

  void refreshStatus() {
    switch (engine) {
      case AIEngine.cloud:
        status = !hasCloudKey
            ? 'הכנס מפתח API בהגדרות'
            : cloudModel.isEmpty
                ? 'בחר מודל בהגדרות'
                : cloudProvider.title;
      case AIEngine.manual:
        status = awaitingPaste ? 'הדבק ב-$manualSite את מה שהועתק, ואז הדבק כאן את התשובה' : 'ידני · $manualSite';
    }
    notifyListeners();
  }

  // MARK: Chat

  /// `label` is what the conversation shows instead of a long prompt; `images` are base64 JPEGs.
  void send(String prompt, {required String context, String? label, List<String> images = const [], bool auto = false}) {
    final text = prompt.trim();
    if ((text.isEmpty && images.isEmpty) || isRunning || !canSend) return;
    messages = [
      ...messages,
      InsightMessage(role: 'user', text: text.isEmpty ? 'מצורפת תמונה.' : text, auto: auto, label: label, images: images),
    ];
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
    undo = null;
    clearedAt = DateTime.now();
    _save();
    notifyListeners();
  }

  // MARK: Changes the model proposed

  /// Applies the chosen changes of one answer to the member being edited; keeps an undo.
  void apply(AIActionPlan plan, Set<int> chosen, String messageID, AppStore store) {
    final message = messages.where((m) => m.id == messageID).firstOrNull;
    if (message == null) return;
    final before = jsonDecode(jsonEncode(store.file.json)) as Map<String, dynamic>;
    final done = <int>[];
    final errors = <String>[];
    store.edit((file) {
      for (final action in plan.actions.where((a) => chosen.contains(a.id))) {
        try {
          applyAIAction(action, file);
          done.add(action.id);
        } catch (e) {
          errors.add('${action.title}: $e');
        }
      }
    });
    message.applied = done;
    message.actionError = errors.isEmpty ? null : errors.join('\n');
    if (done.isNotEmpty) undo = (messageID, before);
    _save();
    notifyListeners();
  }

  void dismiss(String messageID) {
    final message = messages.where((m) => m.id == messageID).firstOrNull;
    if (message == null) return;
    message.dismissed = true;
    _save();
    notifyListeners();
  }

  void undoLast(AppStore store) {
    final u = undo;
    if (u == null) return;
    final message = messages.where((m) => m.id == u.$1).firstOrNull;
    store.edit((file) {
      // Key by key: the document's map may be typed more narrowly than the decoded copy.
      file.json.removeWhere((k, _) => !u.$2.containsKey(k));
      for (final e in u.$2.entries) {
        if (e.value != null) file.json[e.key] = e.value as Object;
      }
    });
    message?.applied = null;
    message?.actionError = null;
    undo = null;
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

  List<AITurn> _turns() {
    final recent = messages.length > 12 ? messages.sublist(messages.length - 12) : messages;
    final turns = <AITurn>[];
    for (var i = 0; i < recent.length; i++) {
      final m = recent[i];
      final parts = <String>[];
      for (final s in InsightParser.parse(m.text)) {
        if (s is TextSegment) {
          parts.add(s.text);
        } else if (s is ChartSegment) {
          parts.add('[תרשים: ${s.spec.title ?? ''}]');
        } else if (s is ActionsSegment) {
          final state = m.dismissed ? 'המשתמש דחה' : (m.applied?.isNotEmpty == true ? 'בוצע' : 'ממתין לאישור');
          parts.add('```actions\n${s.raw.trim()}\n```\n[$state${s.plan.summary.isEmpty ? '' : ': ${s.plan.summary}'}]');
        }
      }
      var content = parts.isEmpty ? m.text : parts.join('\n');
      // Pictures go with the newest question only; earlier ones are already described in the answers.
      final images = i == recent.length - 1 ? m.images : const <String>[];
      if (m.role == 'user' && m.imageCount > 0 && images.isEmpty) content += '\n[צורפה תמונה]';
      turns.add(AITurn(m.role, content, images));
    }
    return turns;
  }

  void _run(String context) {
    final system = '$systemPrompt\n\n# הנתונים\n$context';
    final turns = _turns();
    switch (engine) {
      case AIEngine.manual:
        _prepareManual(system, turns);
      case AIEngine.cloud:
        _runCloud(system, turns);
    }
  }

  /// PNG (pictures shrunk on this device) or JPEG (camera photos sent as they are).
  static String _mime(String b64) => b64.startsWith('iVBOR') ? 'image/png' : 'image/jpeg';

  static dynamic _content(AITurn t, {required bool anthropic}) {
    if (t.images.isEmpty || t.role != 'user') return t.text;
    return [
      for (final b64 in t.images)
        anthropic
            ? {'type': 'image', 'source': {'type': 'base64', 'media_type': _mime(b64), 'data': b64}}
            : {'type': 'image_url', 'image_url': {'url': 'data:${_mime(b64)};base64,$b64'}},
      {'type': 'text', 'text': t.text},
    ];
  }

  Future<void> _runCloud(String system, List<AITurn> turns) async {
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
    if (anthropic) list = turns.skipWhile((t) => t.role == 'assistant').toList();
    final messageList = [for (final t in list) {'role': t.role, 'content': _content(t, anthropic: anthropic)}];
    final name = activeModelName;
    _stream(
      uri,
      _authHeaders(key),
      {
        'model': cloudModel.trim(),
        'stream': true,
        if (anthropic) ...{
          'system': system,
          'max_tokens': 8192,
          'messages': messageList,
        } else
          'messages': [
            {'role': 'system', 'content': system},
            ...messageList,
          ],
      },
      working: 'שולח…',
      answering: 'חושב…',
      // Only the answer itself: thinking comes in other fields ("reasoning", "thinking_delta") and is left out.
      piece: (json) {
        if (!anthropic) return _openAIPiece(json);
        final delta = json['delta'];
        return json['type'] == 'content_block_delta' && delta is Map && delta['type'] == 'text_delta' ? delta['text'] as String? : null;
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
    final answer = InsightParser.withoutThinking(output).trim();
    if (answer.isNotEmpty) {
      messages = [...messages, InsightMessage(role: 'assistant', text: answer, model: label())];
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

  void _prepareManual(String system, List<AITurn> turns) {
    final text = StringBuffer('$system\n\n');
    if (turns.length > 1) {
      text.write('# השיחה שלנו עד עכשיו\n');
      for (final t in turns.sublist(0, turns.length - 1)) {
        text.write('${t.role == 'user' ? 'אני: ' : 'אתה: '}${t.text}\n\n');
      }
    }
    text.write('# השאלה שלי עכשיו\n${turns.isEmpty ? '' : turns.last.text}');
    if (turns.isNotEmpty && turns.last.images.isNotEmpty) text.write('\n(צירפתי תמונה — היא מצורפת להודעה הזו)');
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
    messages = [...messages, InsightMessage(role: 'assistant', text: InsightParser.withoutThinking(answer), model: 'ידני · $manualSite')];
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
