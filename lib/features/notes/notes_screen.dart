import 'package:flutter/material.dart';

import '../../data/design_notes.dart';
import '../../theme/sr_tokens.dart';

class NotesScreen extends StatelessWidget {
  const NotesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final stacked = width < SR.tabletMin;
    return Scrollbar(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          stacked ? 14 : 24,
          stacked ? 14 : 20,
          stacked ? 14 : 24,
          40,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 940),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final note in designNotes)
                  _NoteCard(note: note, stacked: stacked),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, required this.stacked});

  final DesignNote note;
  final bool stacked;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: EdgeInsets.symmetric(horizontal: stacked ? 16 : 22, vertical: 20),
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SR.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 2,
          children: [
            Text(
              note.number,
              style: mono(10, w: 500, tracking: .06, color: SR.blue),
            ),
            Text(note.title, style: sans(14, w: 600, tracking: -.01)),
          ],
        ),
        const SizedBox(height: 12),
        for (final item in note.items)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: SR.divider)),
            ),
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.key,
                        style: sans(11.5, w: 500, height: 1.5, color: SR.ink2),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.value,
                        style: sans(12, height: 1.65, color: SR.ink4),
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 190,
                        child: Text(
                          item.key,
                          style: sans(
                            11.5,
                            w: 500,
                            height: 1.5,
                            color: SR.ink2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          item.value,
                          style: sans(12, height: 1.65, color: SR.ink4),
                        ),
                      ),
                    ],
                  ),
          ),
      ],
    ),
  );
}
