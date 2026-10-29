import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The app's Supabase project ("Maskoret") — the same one the iPhone/Mac app uses (SupabaseConfig.swift).
class SupabaseConfig {
  static const url = 'https://pukbrxsuucqrukiaojlp.supabase.co';

  /// The public (anon) key. What each user can read or change is decided by the database's
  /// row-level security and functions, not by this key.
  static const anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB1a2JyeHN1dWNxcnVraWFvamxwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMyNTIwMjksImV4cCI6MjEwODgyODAyOX0.EOR76pbmTJQUaM8IxCzevHUJM7WT4EF4EIUjk3xip1I';
}

/// A household the signed-in user belongs to. Ids from the server are lowercase.
class HouseholdInfo {
  HouseholdInfo(Map<String, dynamic> j)
      : id = (j['id'] as String).toLowerCase(),
        name = j['name'] as String? ?? '',
        role = j['role'] as String? ?? 'member',
        memberCount = (j['member_count'] as num?)?.toInt() ?? 1,
        revision = (j['revision'] as num?)?.toInt() ?? 0,
        updatedAt = j['updated_at'] as String?,
        device = j['device'] as String?;

  HouseholdInfo.local(this.id, this.name)
      : role = 'owner',
        memberCount = 1,
        revision = 0,
        updatedAt = null,
        device = null;

  final String id;
  final String name;
  final String role;
  final int memberCount;
  final int revision;
  final String? updatedAt;
  final String? device;

  bool get isOwner => role == 'owner';
}

class HouseholdMember {
  HouseholdMember(Map<String, dynamic> j)
      : userId = (j['user_id'] as String).toLowerCase(),
        role = j['role'] as String? ?? 'member',
        displayName = j['display_name'] as String? ?? '',
        email = j['email'] as String?;

  final String userId;
  final String role;
  final String displayName;
  final String? email;

  bool get isOwner => role == 'owner';
  String get title => displayName.isNotEmpty ? displayName : (email ?? 'חבר');
}

class HouseholdInvite {
  HouseholdInvite(Map<String, dynamic> j)
      : code = j['code'] as String,
        expiresAt = DateTime.tryParse(j['expires_at'] as String? ?? '')?.toLocal();
  final String code;
  final DateTime? expiresAt;
}

/// What the sync needs to know about the user (a fake one is used in the tests).
abstract class SyncAccount implements Listenable {
  bool get isSignedIn;
  String? get userId;
  List<HouseholdInfo> get households;
  Future<void> refreshHouseholds();
  String? get activeHouseholdId;
  set activeHouseholdId(String? id);
}

/// The signed-in user: login, the households they belong to, and managing them. Port of Account.swift.
class UserAccount extends ChangeNotifier implements SyncAccount {
  UserAccount(this.prefs);

  final SharedPreferences prefs;
  SupabaseClient get _c => Supabase.instance.client;

  @override
  String? userId;
  String? email;
  String displayName = '';
  @override
  List<HouseholdInfo> households = [];
  bool didLoad = false;

  /// Called when the user or their households change (wired to `ServerSync.accountChanged`).
  Future<void> Function()? onChanged;

  StreamSubscription<AuthState>? _sub;

  @override
  bool get isSignedIn => userId != null;

  @override
  String? get activeHouseholdId => prefs.getString('activeHouseholdID');
  @override
  set activeHouseholdId(String? id) {
    if (id == null) {
      prefs.remove('activeHouseholdID');
    } else {
      prefs.setString('activeHouseholdID', id.toLowerCase());
    }
    notifyListeners();
  }

  HouseholdInfo? get activeHousehold {
    for (final h in households) {
      if (h.id == activeHouseholdId) return h;
    }
    return null;
  }

  void start() {
    final current = _c.auth.currentUser;
    if (current != null) _setUser(current);
    didLoad = true;
    _sub ??= _c.auth.onAuthStateChange.listen((state) async {
      switch (state.event) {
        case AuthChangeEvent.initialSession:
        case AuthChangeEvent.signedIn:
        case AuthChangeEvent.tokenRefreshed:
        case AuthChangeEvent.userUpdated:
          final user = state.session?.user;
          if (user != null) {
            await _setUser(user);
          } else if (state.event == AuthChangeEvent.initialSession) {
            _clearUser();
          }
        case AuthChangeEvent.signedOut:
          _clearUser();
        default:
          break;
      }
      didLoad = true;
      notifyListeners();
    });
  }

  Future<void> _setUser(User user) async {
    final changed = userId != user.id.toLowerCase();
    userId = user.id.toLowerCase();
    email = user.email;
    // Email sign-ups store "display_name"; Google gives "full_name" / "name".
    final meta = user.userMetadata ?? const {};
    final name = [meta['display_name'], meta['full_name'], meta['name']]
        .firstWhere((v) => v is String && v.isNotEmpty, orElse: () => '');
    displayName = name as String;
    notifyListeners();
    if (changed) {
      await refreshHouseholds();
      await onChanged?.call();
    }
  }

  void _clearUser() {
    final was = userId != null;
    userId = null;
    email = null;
    displayName = '';
    households = [];
    notifyListeners();
    if (was) onChanged?.call();
  }

  // MARK: Sign up / in

  /// Returns true when the account still needs the code from the email.
  Future<bool> signUp(String email, String password, String name) async {
    final r = await _c.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'display_name': name.trim()},
    );
    return r.session == null;
  }

  Future<void> verifySignUp(String email, String code) =>
      _c.auth.verifyOTP(email: email.trim(), token: code.trim(), type: OtpType.signup);

  Future<void> resendSignUpCode(String email) => _c.auth.resend(email: email.trim(), type: OtpType.signup);

  Future<void> signIn(String email, String password) =>
      _c.auth.signInWithPassword(email: email.trim(), password: password);

  /// Where the browser sends the user back after signing in with Google (a deep link into the app).
  static const oauthRedirect = 'com.shlomodavid.maskoret://login-callback';

  /// Opens Google's sign-in page in the browser. The result arrives through the deep link,
  /// and the auth listener above picks up the new session.
  Future<void> signInWithGoogle() async {
    final opened = await _c.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: oauthRedirect,
      authScreenLaunchMode: LaunchMode.externalApplication,
      queryParams: {'prompt': 'select_account'},
    );
    if (!opened) throw const AuthException('could not open the browser');
  }

  Future<void> sendPasswordReset(String email) => _c.auth.resetPasswordForEmail(email.trim());

  /// The code from the "reset password" email signs the user in; then the new password is set.
  Future<void> resetPassword(String email, String code, String newPassword) async {
    await _c.auth.verifyOTP(email: email.trim(), token: code.trim(), type: OtpType.recovery);
    await _c.auth.updateUser(UserAttributes(password: newPassword));
  }

  Future<void> changePassword(String newPassword) => _c.auth.updateUser(UserAttributes(password: newPassword));

  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    final short = trimmed.length > 80 ? trimmed.substring(0, 80) : trimmed;
    await _c.auth.updateUser(UserAttributes(data: {'display_name': short}));
    if (userId != null) await _c.from('profiles').update({'display_name': short}).eq('id', userId!);
    displayName = short;
    notifyListeners();
  }

  Future<void> signOut() async {
    try {
      await _c.auth.signOut();
    } catch (_) {}
    _clearUser();
  }

  /// Households they own alone are deleted; shared ones pass to the longest-standing member.
  Future<void> deleteAccount() async {
    await _c.rpc('delete_my_account');
    try {
      await _c.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
    _clearUser();
  }

  // MARK: Households

  @override
  Future<void> refreshHouseholds() async {
    if (!isSignedIn) return;
    try {
      final list = await _c.rpc('my_households');
      if (list is List) {
        households = list.map((e) => HouseholdInfo((e as Map).cast<String, dynamic>())).toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<List<HouseholdMember>> members(String id) async {
    final list = await _c.rpc('household_members_list', params: {'hid': id});
    return (list as List).map((e) => HouseholdMember((e as Map).cast<String, dynamic>())).toList();
  }

  Future<HouseholdInvite> createInvite(String id) async =>
      HouseholdInvite((await _c.rpc('create_invite', params: {'hid': id}) as Map).cast<String, dynamic>());

  /// Joins with a code; returns the household's id.
  Future<String> acceptInvite(String code) async {
    final joined = await _c.rpc('accept_invite', params: {'p_code': code.trim()}) as Map;
    await refreshHouseholds();
    return (joined['id'] as String).toLowerCase();
  }

  Future<void> rename(String id, String name) async {
    await _c.rpc('rename_household', params: {'hid': id, 'p_name': name});
    await refreshHouseholds();
  }

  Future<void> leave(String id) async {
    await _c.rpc('leave_household', params: {'hid': id});
    await refreshHouseholds();
  }

  Future<void> delete(String id) async {
    await _c.rpc('delete_household', params: {'hid': id});
    await refreshHouseholds();
  }

  Future<void> removeMember(String member, String id) async {
    await _c.rpc('remove_member', params: {'hid': id, 'member': member});
    await refreshHouseholds();
  }

  // MARK: Errors in Hebrew

  static String describe(Object error) {
    var text = error.toString().toLowerCase();
    if (error is AuthException) text += ' ${error.message.toLowerCase()} ${error.code ?? ''}';
    if (error is PostgrestException) text += ' ${error.message.toLowerCase()} ${error.code ?? ''}';
    if (error is SocketException || text.contains('socketexception') || text.contains('failed host lookup')) {
      return 'אין חיבור לאינטרנט, או שלא ניתן להתחבר לשרת. נסה שוב בעוד רגע.';
    }
    if (text.contains('invalid or expired code')) return 'קוד ההזמנה לא נכון, כבר נוצל או שפג תוקפו.';
    if (text.contains('invalid login credentials')) return 'המייל או הסיסמה לא נכונים.';
    if (text.contains('email not confirmed')) return 'המייל עוד לא אומת — הכנס את הקוד שקיבלת במייל.';
    if (text.contains('already registered') || text.contains('already been registered') || text.contains('user_already_exists')) {
      return 'כבר יש חשבון עם המייל הזה — התחבר, או בחר ״שכחתי סיסמה״.';
    }
    if (text.contains('password') && (text.contains('at least') || text.contains('weak'))) {
      return 'הסיסמה קצרה או חלשה מדי — לפחות 8 תווים.';
    }
    if (text.contains('expired') || text.contains('otp') || (text.contains('token') && text.contains('invalid'))) {
      return 'הקוד לא נכון או שפג תוקפו. אפשר לבקש קוד חדש.';
    }
    if (text.contains('rate limit') || text.contains('too many') || text.contains('over_email_send_rate_limit')) {
      return 'יותר מדי ניסיונות. חכה כמה דקות ונסה שוב.';
    }
    if (text.contains('only the owner')) return 'רק הבעלים של משק הבית יכול לעשות את זה.';
    if (text.contains('not a member')) return 'אין לך גישה למשק הבית הזה.';
    if (text.contains('too many households')) return 'הגעת למספר המרבי של משקי בית (20).';
    if (text.contains('provider is not enabled') || text.contains('unsupported provider')) {
      return 'ההתחברות עם Google עוד לא הופעלה בשרת.';
    }
    if (text.contains('could not open the browser')) return 'לא ניתן לפתוח את הדפדפן.';
    if (text.contains('invalid email') || text.contains('unable to validate email')) return 'כתובת המייל לא תקינה.';
    final message = error is AuthException
        ? error.message
        : error is PostgrestException
            ? error.message
            : error.toString();
    return 'הפעולה נכשלה: $message';
  }
}
