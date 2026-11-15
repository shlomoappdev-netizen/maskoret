import 'package:flutter/material.dart';

import '../data/assistant.dart';
import 'common.dart';

/// One getting-to-know-you question at the top of the screens it belongs to (AssistantQuestionCard in
/// AssistantView.swift). At most one a day; the answer becomes something the assistant knows about the member
/// being edited.
class AssistantQuestionCard extends StatelessWidget {
  const AssistantQuestionCard({super.key, required this.screen});

  /// The screen's name (Dest.name, the same as the Mac's SidebarItem raw value).
  final String screen;

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final question = store.money.assistant.questionFor(screen);
      if (question == null) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final quiet = TextButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: theme.textTheme.bodySmall,
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1060),
            child: Container(
              padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 10, 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.auto_awesome, size: 18, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(question.text, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                      Text('כדי שההמלצות יתאימו לך',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final answer in question.answers)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: FilledButton.tonal(
                          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                          onPressed: () => store.edit((f) => f.money.assistant.answer(question, answer)),
                          child: Text(answer),
                        ),
                      ),
                  ]),
                ),
                Row(children: [
                  TextButton(
                    style: quiet,
                    onPressed: () => store.edit((f) => f.money.assistant.postpone()),
                    child: const Text('לא עכשיו'),
                  ),
                  TextButton(
                    style: quiet,
                    onPressed: () => store.edit((f) => f.money.assistant.skip(question)),
                    child: const Text('אל תשאל שוב'),
                  ),
                  const Spacer(),
                  Flexible(
                    child: TextButton(
                      style: quiet,
                      onPressed: () => openAssistantFacts(context),
                      child: const Text('מה העוזר יודע עליי', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

void openAssistantFacts(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AssistantFactsScreen()));

/// "מה העוזר יודע עליי": everything the assistant knows about the member being edited — delete what's wrong, add in
/// your own words (AssistantFactsView in AssistantView.swift).
class AssistantFactsScreen extends StatefulWidget {
  const AssistantFactsScreen({super.key});

  @override
  State<AssistantFactsScreen> createState() => _AssistantFactsScreenState();
}

class _AssistantFactsScreenState extends State<AssistantFactsScreen> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _add() {
    final value = _text.text;
    if (value.trim().isEmpty) return;
    context.store.edit((f) => f.money.assistant.remember(value));
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('מה העוזר יודע עליי')),
      body: StoreBuilder(builder: (context, store) {
        final theme = Theme.of(context);
        final facts = store.money.assistant.facts;
        final member = store.members.length > 1 ? store.activeMember?.title : null;
        return PageList(children: [
          SectionCard(
            title: member ?? 'מה ידוע',
            subtitle: 'העוזר משתמש בזה כדי להתאים את התשובות וההמלצות. זה נשמר עם הנתונים שלך ומסתנכרן בין המכשירים.',
            children: [
              if (facts.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                  child: Text('עדיין כלום. אפשר לענות על השאלות שבראש המסכים, או לכתוב כאן.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
              for (final fact in facts)
                ListTile(
                  dense: true,
                  title: Text(fact.text, style: theme.textTheme.bodyLarge),
                  trailing: IconButton(
                    tooltip: 'מחיקה',
                    icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                    onPressed: () => store.edit((f) => f.money.assistant.forget(fact.id)),
                  ),
                ),
            ],
          ),
          SectionCard(title: 'להוסיף משהו', children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    maxLength: AssistantProfile.maxFactLength,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _add(),
                    decoration: const InputDecoration(hintText: 'למשל: חוסכים לחתונה בקיץ', counterText: ''),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _add, child: const Text('הוספה')),
              ]),
            ),
          ]),
        ]);
      }),
    );
  }
}
