import 'package:flutter/material.dart';

import '../data/family.dart';
import '../data/fmt.dart';
import '../data/models.dart';
import 'common.dart';
import 'theme.dart';

/// Family members — who is in the household and whose data is being edited (FamilySwitcher / MemberSheet in Swift).
class FamilyScreen extends StatelessWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final theme = Theme.of(context);
      final members = store.members;
      final primary = store.family.state.primaryID;
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'add-member',
          icon: const Icon(Icons.person_add_alt),
          label: const Text('בן משפחה'),
          onPressed: () => editMember(context, null),
        ),
        body: PageList(children: [
          Text(
            'לכל בן משפחה יש תלוש, ניכויים, הוצאות קבועות, חשבונות, כרטיס אשראי וחודשים משלו. טיפ: בן משפחה בשם ״🏠 משותף״ '
            'מתאים לחשבון משותף ולהוצאות של הבית כמו שכירות.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SectionCard(
            title: 'בני המשפחה',
            trailing: members.length > 1
                ? TextButton(
                    onPressed: () => store.viewedMembers.length == members.length ? store.showOnly(store.activeMemberId) : store.showEveryone(),
                    child: Text(store.viewedMembers.length == members.length ? 'כל אחד לבד' : 'כולם יחד'),
                  )
                : null,
            children: [
            for (final m in members)
              () {
                final editing = m.id == store.activeMemberId;
                final file = store.family.file(m.id);
                final inView = store.viewedMembers.any((v) => v.id == m.id);
                return ListTile(
                  leading: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (members.length > 1)
                      Tooltip(
                        message: 'להציג בסיכום, בתחזית ובסרגל',
                        child: Checkbox(value: inView, onChanged: (_) => store.toggleInView(m.id)),
                      ),
                    CircleAvatar(
                    backgroundColor: editing ? AppColors.teal.withValues(alpha: 0.15) : theme.colorScheme.surfaceContainerHighest,
                    child: FittedBox(child: Padding(padding: const EdgeInsets.all(4), child: Text(m.emoji, style: const TextStyle(fontSize: 20)))),
                    ),
                  ]),
                  title: Text(m.name, style: TextStyle(fontWeight: editing ? FontWeight.w700 : FontWeight.w500)),
                  subtitle: Text([
                    if (editing) '✏️ בעריכה במכשיר הזה',
                    if (file != null && file.budget.net > 0) 'נטו ${Fmt.money(file.budget.net)}',
                    if (m.id == primary) 'ראשי',
                  ].join(' · ')),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'פעולות',
                    onSelected: (action) async {
                      switch (action) {
                        case 'edit':
                          await editMember(context, m);
                        case 'delete':
                          if (await confirm(context, 'למחוק את ${m.name}?',
                                  'כל הנתונים של ${m.name} — תלוש, הוצאות, חשבונות, כרטיס אשראי וחודשים — יימחקו מכל המכשירים.',
                                  ok: 'מחק') &&
                              context.mounted) {
                            String? next;
                            store.editFamily((f) => next = FamilyActions(f).delete(m.id, store.activeMemberId));
                            if (next != null) store.activeMemberId = next!;
                          }
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('עריכת שם ואימוג׳י')),
                      if (m.id != primary) const PopupMenuItem(value: 'delete', child: Text('מחיקה, עם הנתונים')),
                    ],
                  ),
                  onTap: editing ? null : () => store.setEditing(m.id),
                );
              }(),
            const EmptyHint('לחיצה על בן משפחה עוברת לעריכת הנתונים שלו (הבחירה נשמרת במכשיר הזה). סימון ✓ מצרף לתצוגה המשותפת: '
                'הסיכום, התחזית והסרגל מציגים את המסומנים יחד — כל אחד עם הנטו שלו, החשבונות של כולם, וכרטיס אשראי שיובא אצל '
                'שניים נספר פעם אחת.'),
          ]),
        ]),
      );
    });
  }
}

const _presets = [('👨', 'אבא'), ('👩', 'אמא'), ('🏠', 'משותף'), ('🧒', 'ילד'), ('👴', 'סבא'), ('👵', 'סבתא')];

/// Add (`member == null`) or rename a family member — MemberSheet.
Future<void> editMember(BuildContext context, FamilyMember? member) async {
  final store = context.store;
  final isNew = member == null;
  var name = member?.name ?? '';
  var emoji = member?.emoji ?? '🙂';
  final nameController = TextEditingController(text: name);
  final emojiController = TextEditingController(text: emoji);
  await showEditor(
    context,
    title: isNew ? 'בן משפחה חדש' : 'עריכת בן משפחה',
    builder: (context, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: nameController,
        autofocus: isNew,
        decoration: const InputDecoration(labelText: 'שם', hintText: 'למשל: נועה', border: OutlineInputBorder()),
        onChanged: (v) => name = v,
      ),
      const SizedBox(height: 12),
      TextField(
        controller: emojiController,
        decoration: const InputDecoration(labelText: 'אימוג׳י', border: OutlineInputBorder()),
        onChanged: (v) => emoji = v,
      ),
      if (isNew) ...[
        const SizedBox(height: 12),
        Text('הצעות', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (e, n) in _presets)
            ActionChip(
              label: Text('$e $n'),
              onPressed: () => setState(() {
                emoji = e;
                emojiController.text = e;
                if (name.isEmpty || _presets.any((p) => p.$2 == name)) {
                  name = n;
                  nameController.text = n;
                }
              }),
            ),
        ]),
        const SizedBox(height: 12),
        Text(
          'לבן משפחה חדש מתחילים נתונים ריקים, עם שיעורי המס הנוכחיים. אחרי ההוספה עוברים לעריכת הנתונים שלו.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ]),
    onSave: () {
      if (isNew) {
        late String id;
        store.editFamily((f) => id = FamilyActions(f).add(name: name, emoji: emoji, copyFrom: store.file));
        store.activeMemberId = id;
      } else {
        store.editFamily((f) => FamilyActions(f).update(member.id, name: name.trim().isEmpty ? member.name : name, emoji: emoji));
      }
    },
  );
}

/// "סיכום ותחזית: 👨 אבא + 👩 אמא" above the dashboards in the together view (FamilyContextBar).
class FamilyContextLine extends StatelessWidget {
  const FamilyContextLine({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    if (!store.isCombined) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(spacing: 14, runSpacing: 4, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.groups, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text('יחד: ${store.viewedMembers.map((m) => m.title).join(' + ')}', style: theme.textTheme.bodySmall),
        ]),
        if (store.activeMember != null)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.edit, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text('עריכה: ${store.activeMember!.title}', style: theme.textTheme.bodySmall),
          ]),
      ]),
    );
  }
}
