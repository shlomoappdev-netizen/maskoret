import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/fmt.dart';
import 'theme.dart';
import '../state/store.dart';
import '../sync/account.dart';
import '../sync/server_sync.dart';
import '../support/announcements.dart';
import '../support/support.dart';
import '../update/updater.dart';

/// Gives every screen the store, the account and the sync.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.store,
    required this.account,
    required this.sync,
    required this.prefs,
    required this.updater,
    required this.support,
    required this.announcements,
    required super.child,
  });

  final AppStore store;
  final UserAccount account;
  final ServerSync sync;
  final SharedPreferences prefs;
  final Updater updater;
  final SupportCenter support;
  final Announcements announcements;

  static AppScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}

extension ScopeX on BuildContext {
  AppScope get scope => AppScope.of(this);
  AppStore get store => AppScope.of(this).store;
}

/// Rebuilds when the household data changes.
class StoreBuilder extends StatelessWidget {
  const StoreBuilder({super.key, required this.builder});
  final Widget Function(BuildContext context, AppStore store) builder;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    return ListenableBuilder(listenable: store, builder: (context, _) => builder(context, store));
  }
}

const double wideBreakpoint = 840;

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= wideBreakpoint;

/// A list page with a max width on desktop.
class PageList extends StatelessWidget {
  const PageList({super.key, required this.children, this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 110)});
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: ListView(padding: padding, children: children),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.subtitle, required this.children, this.trailing});
  final String? title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title!, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        if (subtitle != null)
                          Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          ...children,
          const SizedBox(height: 8),
        ],
      ),
      ),
    );
  }
}

/// A row of "label ………… amount".
class AmountRow extends StatelessWidget {
  const AmountRow(this.label, this.amount,
      {super.key, this.bold = false, this.negative = false, this.color, this.detail, this.onTap});
  final String label;
  final double amount;
  final bool bold;
  final bool negative;
  final Color? color;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = bold ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700) : theme.textTheme.bodyLarge;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: style),
                  if (detail != null)
                    Text(detail!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            Text(
              (negative && amount != 0 ? '−' : '') + Fmt.money(amount),
              style: style?.copyWith(color: color, fontFeatures: tabular),
              textDirection: TextDirection.rtl,
            ),
          ],
        ),
      ),
    );
  }
}

/// A number field (shekels, percent, hours).
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.suffix,
    this.helper,
    this.autofocus = false,
  });
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final String? suffix;
  final String? helper;
  final bool autofocus;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final controller = TextEditingController(text: widget.value == 0 ? '' : Fmt.plain(widget.value));
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: widget.autofocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))],
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
      decoration: InputDecoration(
        labelText: widget.label,
        suffixText: widget.suffix,
        helperText: widget.helper,
        helperMaxLines: 3,
        errorText: error,
        border: const OutlineInputBorder(),
      ),
      onChanged: (t) {
        final v = Fmt.parse(t);
        setState(() => error = v == null ? 'מספר לא תקין' : null);
        if (v != null) widget.onChanged(v);
      },
    );
  }
}

class TextInput extends StatelessWidget {
  const TextInput({super.key, required this.label, required this.initial, required this.onChanged, this.autofocus = false});
  final String label;
  final String initial;
  final ValueChanged<String> onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: initial,
      autofocus: autofocus,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      onChanged: onChanged,
    );
  }
}

/// A date row that opens the date picker.
class DateField extends StatelessWidget {
  const DateField({super.key, required this.label, required this.value, required this.onChanged, this.allowClear = false});
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool allowClear;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: value ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  final v = value;
                  // Keep the time of day of an existing date (Swift dates have one).
                  onChanged(v == null
                      ? DateTime(picked.year, picked.month, picked.day, 12)
                      : DateTime(picked.year, picked.month, picked.day, v.hour, v.minute, v.second));
                }
              },
              child: Text(value == null ? 'לא נקבע' : Fmt.date(value!)),
            ),
          ),
          if (allowClear && value != null)
            IconButton(
              tooltip: 'ניקוי',
              icon: const Icon(Icons.clear, size: 18),
              onPressed: () => onChanged(null),
            ),
        ],
      ),
    );
  }
}

/// Opens an editing form as a bottom sheet (phone) or a dialog (desktop). Returns true when saved.
Future<bool> showEditor(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext context, StateSetter setState) builder,
  required VoidCallback onSave,
  VoidCallback? onDelete,
  String deleteLabel = 'מחיקה',
}) async {
  Widget body(BuildContext ctx, StateSetter setState) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [builder(ctx, setState)],
      );

  List<Widget> actions(BuildContext ctx) => [
        if (onDelete != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () async {
              if (await confirm(ctx, '$deleteLabel?', 'אי אפשר לבטל את הפעולה.') && ctx.mounted) {
                onDelete();
                Navigator.pop(ctx, true);
              }
            },
            child: Text(deleteLabel),
          ),
        const Spacer(),
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
        FilledButton(
          onPressed: () {
            onSave();
            Navigator.pop(ctx, true);
          },
          child: const Text('שמירה'),
        ),
      ];

  if (isWide(context)) {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 460, child: SingleChildScrollView(child: body(ctx, setState))),
          actions: [SizedBox(width: double.maxFinite, child: Row(children: actions(ctx)))],
        ),
      ),
    );
    return r ?? false;
  }
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              body(ctx, setState),
              const SizedBox(height: 16),
              Row(children: actions(ctx)),
            ],
          ),
        ),
      ),
    ),
  );
  return r ?? false;
}

/// Space between form fields.
const gap = SizedBox(height: 12);

Future<bool> confirm(BuildContext context, String title, String message, {String ok = 'אישור', bool danger = true}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Runs a server action, showing the error in Hebrew when it fails. Returns true on success.
Future<bool> run(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } catch (e) {
    if (context.mounted) showMessage(context, UserAccount.describe(e));
    return false;
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

/// Pushes a page with the app's glass background behind it.
Route<T> glassRoute<T>(WidgetBuilder builder) =>
    MaterialPageRoute<T>(builder: (context) => GlassBackground(child: builder(context)));
