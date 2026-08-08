import 'package:flutter/material.dart';

import '../model/audit_entry.dart';
import '../theme/sr_tokens.dart';
import 'decision_widgets.dart';

class RecordActivity extends StatelessWidget {
  const RecordActivity({
    super.key,
    required this.entries,
    required this.emptyTitle,
    required this.emptyBody,
    this.intro,
  });

  final List<AuditEntry> entries;
  final String? intro;
  final String emptyTitle;
  final String emptyBody;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 34),
        decoration: BoxDecoration(
          color: SR.surfaceSubtle,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: SR.hairline),
        ),
        child: Column(
          children: [
            Text(emptyTitle, style: sans(12.5, w: 600)),
            const SizedBox(height: 4),
            Text(
              emptyBody,
              textAlign: TextAlign.center,
              style: sans(11.5, height: 1.6, color: SR.ink4),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (intro case final intro?)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 14, 0, 4),
            child: Text(intro, style: sans(11, height: 1.6, color: SR.muted)),
          ),
        for (final entry in entries) _ActivityRow(entry: entry),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 13),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: SR.divider)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Initials(text: entry.initials, size: 30, fontSize: 10),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 7,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(entry.actor, style: sans(12, w: 600)),
                  Text(entry.action, style: sans(11.5, color: SR.ink4)),
                  if (entry.material)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: SR.amberTint,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: SR.amberLine),
                      ),
                      child: Text(
                        'MATERIAL',
                        style: mono(8.5, w: 600, color: SR.amberTitle),
                      ),
                    ),
                  Text(entry.when, style: mono(10.5, color: SR.muted)),
                ],
              ),
              if (entry.diff.isNotEmpty) ...[
                const SizedBox(height: 7),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: SR.surfaceSubtle,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: SR.hairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in entry.diff)
                        Text(
                          line,
                          style: mono(11, w: 500, height: 1.65, color: SR.ink2),
                        ),
                    ],
                  ),
                ),
              ],
              if (entry.reason.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  entry.reason,
                  style: sans(11, height: 1.55, color: SR.amberInk),
                ),
              ],
              const SizedBox(height: 5),
              Text(entry.absolute, style: sans(10, color: SR.muted)),
            ],
          ),
        ),
      ],
    ),
  );
}
