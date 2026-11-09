import 'package:supabase_flutter/supabase_flutter.dart';

/// A saved API key from the account (table user_ai_keys, decrypted by ai_keys()).
class SavedAIKey {
  SavedAIKey(this.provider, this.apiKey, this.model, this.baseURL);
  final String provider;
  final String apiKey;
  final String model;
  final String baseURL;
}

/// The conversation as the account keeps it (table ai_conversations).
class SavedConversation {
  SavedConversation(this.messages, this.clearedAt);
  final List<Map<String, dynamic>> messages;
  final DateTime? clearedAt;
}

/// What the AI screen keeps in the user's account, so every device they sign in on has it:
/// the API key (encrypted in Supabase Vault) and the conversation. Same tables and functions as the Mac app.
abstract class AIAccount {
  bool get signedIn;
  Future<void> saveKey(String provider, String? key, String model, String baseURL);
  Future<void> deleteKey(String provider);
  Future<List<SavedAIKey>> keys();
  Future<SavedConversation?> conversation();
  Future<void> saveConversation(List<Map<String, dynamic>> messages, DateTime? clearedAt);
}

class SupabaseAIAccount implements AIAccount {
  SupabaseClient get _c => Supabase.instance.client;

  @override
  bool get signedIn => _c.auth.currentUser != null;

  @override
  Future<void> saveKey(String provider, String? key, String model, String baseURL) => _c.rpc('ai_key_save',
      params: {'p_provider': provider, 'p_key': key, 'p_model': model, 'p_base_url': baseURL});

  @override
  Future<void> deleteKey(String provider) => _c.rpc('ai_key_delete', params: {'p_provider': provider});

  @override
  Future<List<SavedAIKey>> keys() async {
    final rows = await _c.rpc('ai_keys') as List? ?? const [];
    return [
      for (final r in rows.whereType<Map>())
        SavedAIKey('${r['provider'] ?? ''}', '${r['api_key'] ?? ''}', '${r['model'] ?? ''}', '${r['base_url'] ?? ''}'),
    ];
  }

  @override
  Future<SavedConversation?> conversation() async {
    final rows = await _c.from('ai_conversations').select('messages,cleared_at');
    if (rows.isEmpty) return null;
    final row = rows.first;
    final list = (row['messages'] as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    return SavedConversation(list, DateTime.tryParse('${row['cleared_at'] ?? ''}'));
  }

  @override
  Future<void> saveConversation(List<Map<String, dynamic>> messages, DateTime? clearedAt) async {
    final user = _c.auth.currentUser;
    if (user == null) return;
    await _c.from('ai_conversations').upsert({
      'user_id': user.id,
      'messages': messages,
      'cleared_at': clearedAt?.toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id');
  }
}
