import 'package:flutter/material.dart';

import '../model/reservation.dart';
import '../theme/sr_theme.dart';

typedef EvidenceUrlResolver = Future<String?> Function(String storagePath);

/// Photos attached to an admin's post-use assessment. The bucket is private,
/// so each thumbnail resolves a short-lived signed URL through [resolveUrl].
class EvidenceThumbnailStrip extends StatelessWidget {
  const EvidenceThumbnailStrip({
    super.key,
    required this.files,
    required this.resolveUrl,
    this.size = 72,
  });

  final List<ReservationUseAssessmentFile> files;
  final EvidenceUrlResolver resolveUrl;
  final double size;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (var i = 0; i < files.length; i++)
        _EvidenceThumbnail(
          key: ValueKey(files[i].storagePath),
          file: files[i],
          label: 'Evidence photo ${i + 1} of ${files.length}',
          resolveUrl: resolveUrl,
          size: size,
        ),
    ],
  );
}

class _EvidenceThumbnail extends StatefulWidget {
  const _EvidenceThumbnail({
    super.key,
    required this.file,
    required this.label,
    required this.resolveUrl,
    required this.size,
  });

  final ReservationUseAssessmentFile file;
  final String label;
  final EvidenceUrlResolver resolveUrl;
  final double size;

  @override
  State<_EvidenceThumbnail> createState() => _EvidenceThumbnailState();
}

class _EvidenceThumbnailState extends State<_EvidenceThumbnail> {
  // Resolved once per mount: AppState rebuilds this subtree constantly, and
  // each resolve is a storage round trip.
  late Future<String?> _url = widget.resolveUrl(widget.file.storagePath);

  void _retry() => setState(() {
    _url = widget.resolveUrl(widget.file.storagePath);
  });

  Future<void> _open() async {
    // Re-sign on open so a thumbnail left on screen past the URL's TTL still
    // opens.
    final url = await widget.resolveUrl(widget.file.storagePath);
    if (!mounted) return;
    if (url == null) {
      _retry();
      return;
    }
    await showEvidenceViewer(context, url: url, label: widget.label);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Semantics(
      button: true,
      label: widget.label,
      child: Tooltip(
        message: widget.file.fileName.isEmpty
            ? widget.label
            : widget.file.fileName,
        child: InkWell(
          onTap: _open,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: widget.size,
            height: widget.size,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: c.surfaceSubtle,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: FutureBuilder<String?>(
              future: _url,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const _ThumbSpinner();
                }
                final url = snapshot.data;
                if (url == null) return _ThumbError(onRetry: _retry);
                return Image.network(
                  url,
                  fit: BoxFit.cover,
                  cacheWidth:
                      (widget.size * MediaQuery.devicePixelRatioOf(context))
                          .ceil(),
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : const _ThumbSpinner(),
                  errorBuilder: (_, _, _) => _ThumbError(onRetry: _retry),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ThumbSpinner extends StatelessWidget {
  const _ThumbSpinner();

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

class _ThumbError extends StatelessWidget {
  const _ThumbError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Photo unavailable. Retry',
    onPressed: onRetry,
    icon: Icon(
      Icons.broken_image_outlined,
      size: 20,
      color: context.srColors.textMuted,
    ),
  );
}

Future<void> showEvidenceViewer(
  BuildContext context, {
  required String url,
  required String label,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black87,
  builder: (dialogContext) => Dialog(
    backgroundColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(16),
    child: Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Semantics(
                image: true,
                label: label,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                  errorBuilder: (_, _, _) => const Text(
                    'This photo could not be loaded.',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton.filled(
            tooltip: 'Close',
            onPressed: () => Navigator.of(dialogContext).pop(),
            style: IconButton.styleFrom(backgroundColor: Colors.black54),
            icon: const Icon(Icons.close_rounded, color: Colors.white),
          ),
        ),
      ],
    ),
  ),
);
