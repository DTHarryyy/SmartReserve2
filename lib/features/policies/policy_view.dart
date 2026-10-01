import 'package:flutter/material.dart';

import '../../data/policies.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/responsive_dialog.dart';

enum PolicyKind {
  terms(termsAndConditionsTitle, termsAndConditions),
  rules(rulesAndRegulationsTitle, rulesAndRegulations);

  const PolicyKind(this.title, this.content);

  final String title;
  final String content;
}

/// Opens the Terms and Conditions or the Rules and Regulations (full screen on
/// phones).
Future<void> showPolicyDocument(BuildContext context, PolicyKind kind) =>
    showDialog<void>(context: context, builder: (_) => _PolicyDialog(kind));

class _PolicyDialog extends StatelessWidget {
  const _PolicyDialog(this.kind);

  final PolicyKind kind;

  @override
  Widget build(BuildContext context) {
    final pad = SR.isCompact(MediaQuery.sizeOf(context).width)
        ? SR.space16
        : SR.space24;
    return SrAdaptiveDialog(
      maxWidth: 720,
      maxHeight: 760,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              pad,
              SR.space16,
              SR.space8,
              SR.space12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    kind.title,
                    style: SrType.heading(color: context.srColors.ink),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: context.srColors.hairline),
          Flexible(
            child: Scrollbar(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(pad),
                child: SelectionArea(child: PolicyText(kind.content)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final _numbered = RegExp(r'^(\d+)\.\s+(.*)$');

/// Renders policy text: `## ` headings, `1. ` numbered items, paragraphs.
class PolicyText extends StatelessWidget {
  const PolicyText(this.content, {super.key});

  final String content;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final body = SrType.body(color: c.ink3);
    final lines = content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    final children = <Widget>[];
    for (final line in lines) {
      if (line.startsWith('## ')) {
        children.add(
          Padding(
            padding: EdgeInsets.only(
              top: children.isEmpty ? 0 : SR.space20,
              bottom: SR.space8,
            ),
            child: Text(line.substring(3), style: SrType.subhead(color: c.ink)),
          ),
        );
      } else if (_numbered.firstMatch(line) case final match?) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: SR.space8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '${match.group(1)}.',
                    style: body.copyWith(color: c.ink4),
                  ),
                ),
                Expanded(child: _rich(match.group(2)!, body)),
              ],
            ),
          ),
        );
      } else {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: SR.space8),
            child: _rich(line, body),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  static Widget _rich(String text, TextStyle style) {
    final parts = text.split('**');
    return Text.rich(
      TextSpan(
        children: [
          for (final (i, part) in parts.indexed)
            TextSpan(
              text: part,
              style: i.isOdd
                  ? const TextStyle(fontWeight: FontWeight.w600)
                  : null,
            ),
        ],
      ),
      style: style,
    );
  }
}
