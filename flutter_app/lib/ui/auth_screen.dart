import 'package:flutter/material.dart';

import '../sync/account.dart';
import 'common.dart';

enum _Mode { signIn, signUp, verify, forgot, reset }

/// Sign in / sign up with a 6-digit code / forgot password — like AuthView.swift.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.onContinueWithout, this.onDone});

  /// "Continue without an account" (only on the first screen of the app).
  final VoidCallback? onContinueWithout;
  final VoidCallback? onDone;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  var mode = _Mode.signIn;
  final email = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  final code = TextEditingController();
  final newPassword = TextEditingController();
  bool busy = false;
  String? error;
  String? info;

  @override
  void dispose() {
    for (final c in [email, password, name, code, newPassword]) {
      c.dispose();
    }
    super.dispose();
  }

  UserAccount get account => context.scope.account;

  Future<void> _go(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
      info = null;
    });
    try {
      await action();
    } catch (e) {
      error = UserAccount.describe(e);
    }
    if (mounted) setState(() => busy = false);
  }

  bool _validEmail() {
    if (!email.text.contains('@')) {
      setState(() => error = 'כתובת המייל לא תקינה.');
      return false;
    }
    return true;
  }

  void _submit() {
    switch (mode) {
      case _Mode.signIn:
        if (!_validEmail()) return;
        _go(() async {
          await account.signIn(email.text, password.text);
          widget.onDone?.call();
        });
      case _Mode.signUp:
        if (!_validEmail()) return;
        if (password.text.length < 8) {
          setState(() => error = 'הסיסמה קצרה מדי — לפחות 8 תווים.');
          return;
        }
        _go(() async {
          final needsCode = await account.signUp(email.text, password.text, name.text);
          if (needsCode) {
            mode = _Mode.verify;
            info = 'שלחנו קוד בן 6 ספרות אל ${email.text.trim()}';
          } else {
            widget.onDone?.call();
          }
        });
      case _Mode.verify:
        _go(() async {
          await account.verifySignUp(email.text, code.text);
          widget.onDone?.call();
        });
      case _Mode.forgot:
        if (!_validEmail()) return;
        _go(() async {
          await account.sendPasswordReset(email.text);
          mode = _Mode.reset;
          info = 'שלחנו קוד לאיפוס הסיסמה אל ${email.text.trim()}';
        });
      case _Mode.reset:
        if (newPassword.text.length < 8) {
          setState(() => error = 'הסיסמה קצרה מדי — לפחות 8 תווים.');
          return;
        }
        _go(() async {
          await account.resetPassword(email.text, code.text, newPassword.text);
          widget.onDone?.call();
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = switch (mode) {
      _Mode.signIn => 'התחברות',
      _Mode.signUp => 'הרשמה',
      _Mode.verify => 'אימות המייל',
      _Mode.forgot => 'שכחתי סיסמה',
      _Mode.reset => 'סיסמה חדשה',
    };
    final action = switch (mode) {
      _Mode.signIn => 'התחבר',
      _Mode.signUp => 'הירשם',
      _Mode.verify => 'אמת',
      _Mode.forgot => 'שלח קוד',
      _Mode.reset => 'שמור סיסמה והתחבר',
    };

    return Scaffold(
      appBar: widget.onContinueWithout == null ? AppBar(title: Text(title)) : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.onContinueWithout != null) ...[
                      Icon(Icons.account_balance_wallet_rounded, size: 64, color: theme.colorScheme.primary),
                      const SizedBox(height: 12),
                      Text('מחשבון שכר', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                      const SizedBox(height: 4),
                      Text('המשכורת, הניכויים וההוצאות של משק הבית — מסונכרנים בין כל המכשירים',
                          textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 28),
                      Text(title, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                    ],
                    if (mode == _Mode.signUp) ...[
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(labelText: 'השם שלך (יוצג לחברי משק הבית)', border: OutlineInputBorder()),
                        autofillHints: const [AutofillHints.name],
                      ),
                      gap,
                    ],
                    if (mode != _Mode.verify && mode != _Mode.reset) ...[
                      TextField(
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        textDirection: TextDirection.ltr,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(labelText: 'מייל', border: OutlineInputBorder()),
                      ),
                      gap,
                    ],
                    if (mode == _Mode.signIn || mode == _Mode.signUp) ...[
                      TextField(
                        controller: password,
                        obscureText: true,
                        textDirection: TextDirection.ltr,
                        autofillHints: [mode == _Mode.signUp ? AutofillHints.newPassword : AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'סיסמה',
                          helperText: mode == _Mode.signUp ? 'לפחות 8 תווים' : null,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                      gap,
                    ],
                    if (mode == _Mode.verify || mode == _Mode.reset) ...[
                      TextField(
                        controller: code,
                        keyboardType: TextInputType.number,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.center,
                        maxLength: 6,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 8),
                        decoration: const InputDecoration(labelText: 'הקוד מהמייל', border: OutlineInputBorder()),
                      ),
                      gap,
                    ],
                    if (mode == _Mode.reset) ...[
                      TextField(
                        controller: newPassword,
                        obscureText: true,
                        textDirection: TextDirection.ltr,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: const InputDecoration(
                            labelText: 'סיסמה חדשה', helperText: 'לפחות 8 תווים', border: OutlineInputBorder()),
                      ),
                      gap,
                    ],
                    if (info != null) Text(info!, style: TextStyle(color: theme.colorScheme.primary)),
                    if (error != null) Text(error!, style: TextStyle(color: theme.colorScheme.error)),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: busy ? null : _submit,
                      child: busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(action),
                    ),
                    const SizedBox(height: 8),
                    if (mode == _Mode.signIn) ...[
                      TextButton(
                          onPressed: () => setState(() {
                                mode = _Mode.signUp;
                                error = null;
                              }),
                          child: const Text('אין לך חשבון? הרשמה')),
                      TextButton(
                          onPressed: () => setState(() {
                                mode = _Mode.forgot;
                                error = null;
                              }),
                          child: const Text('שכחתי סיסמה')),
                    ],
                    if (mode == _Mode.verify)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _go(() async {
                                  await account.resendSignUpCode(email.text);
                                  info = 'נשלח קוד חדש';
                                }),
                        child: const Text('שלח קוד חדש'),
                      ),
                    if (mode != _Mode.signIn)
                      TextButton(
                          onPressed: () => setState(() {
                                mode = _Mode.signIn;
                                error = null;
                                info = null;
                              }),
                          child: const Text('חזרה להתחברות')),
                    if (widget.onContinueWithout != null) ...[
                      const Divider(height: 32),
                      OutlinedButton(onPressed: widget.onContinueWithout, child: const Text('המשך בלי חשבון')),
                      const SizedBox(height: 6),
                      Text('הנתונים יישמרו רק במכשיר הזה. אפשר להתחבר בהמשך, והם יעלו לחשבון.',
                          textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
