import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/sr_toast_controller.dart';
import '../../model/facility_draft.dart';
import '../../model/facility_photo.dart';
import '../../model/notice.dart';
import 'safe_change_notifier.dart';

/// Owns photo upload/reorder/cover state for the Add Facility editor.
class PhotosController extends ChangeNotifier with SafeChangeNotifier {
  PhotosController({
    required this.draft,
    required SrToastController toasts,
    required this.onFieldEdited,
  }) : _toasts = toasts;

  final FacilityDraft draft;
  final SrToastController _toasts;

  /// Bridge: notify the coordinator that a field changed, so it can
  /// revalidate and schedule an autosave.
  final VoidCallback onFieldEdited;

  final _picker = ImagePicker();
  bool dragging = false;

  static const maxPhotos = 8;

  void _edit(VoidCallback change) {
    change();
    notifyListeners();
    onFieldEdited();
  }

  void setDragging(bool value) {
    if (dragging == value) return;
    dragging = value;
    notifyListeners();
  }

  bool get photosFull => draft.photos.length >= maxPhotos;

  void addPlaceholderPhoto() {
    if (_rejectIfFull()) return;
    _edit(
      () => draft.photos.add(FacilityPhoto.placeholder(draft.photos.length)),
    );
  }

  bool _rejectIfFull() {
    if (!photosFull) return false;
    showToast(
      const ToastMessage(
        'That is the $maxPhotos-photo limit. Remove one to add another.',
        tone: AdvisoryTone.warn,
      ),
    );
    return true;
  }

  Future<void> pickFiles() async {
    if (_rejectIfFull()) return;
    try {
      final picked = await _picker.pickMultiImage();
      await _ingest(picked);
    } catch (e) {
      showToast(
        const ToastMessage(
          'No image picker is available on this platform. Use "Add '
          'placeholder" while testing.',
          tone: AdvisoryTone.warn,
        ),
      );
    }
  }

  Future<void> pickCamera() async {
    if (_rejectIfFull()) return;
    try {
      final shot = await _picker.pickImage(source: ImageSource.camera);
      if (shot != null) await _ingest([shot]);
    } catch (e) {
      showToast(
        const ToastMessage(
          'No camera is available on this device.',
          tone: AdvisoryTone.warn,
        ),
      );
    }
  }

  Future<void> addFiles(List<XFile> files) => _ingest(files);

  Future<void> _ingest(List<XFile> picked) async {
    if (picked.isEmpty) return;
    final photos = <FacilityPhoto>[];
    for (final file in picked) {
      if (draft.photos.length + photos.length >= maxPhotos) break;
      final lower = file.name.toLowerCase();
      if (!lower.endsWith('.jpg') &&
          !lower.endsWith('.jpeg') &&
          !lower.endsWith('.png')) {
        showToast(
          ToastMessage(
            '${file.name} is not a JPG or PNG.',
            tone: AdvisoryTone.warn,
          ),
        );
        continue;
      }
      if (await file.length() > 10 * 1024 * 1024) {
        showToast(
          ToastMessage(
            '${file.name} is larger than 10 MB.',
            tone: AdvisoryTone.warn,
          ),
        );
        continue;
      }
      photos.add(
        FacilityPhoto(
          id: '${file.path}-${DateTime.now().microsecondsSinceEpoch}',

          path: kIsWeb ? null : file.path,
          bytes: kIsWeb ? await file.readAsBytes() : null,
          label: file.name,
        ),
      );
    }
    if (photos.isEmpty) return;
    _edit(() => draft.photos.addAll(photos));
  }

  void removePhoto(String id) =>
      _edit(() => draft.photos.removeWhere((p) => p.id == id));

  void movePhoto(String id, int delta) {
    final index = draft.photos.indexWhere((p) => p.id == id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= draft.photos.length) return;
    _edit(() {
      final photo = draft.photos.removeAt(index);
      draft.photos.insert(target, photo);
    });
  }

  void makeCover(String id) {
    final index = draft.photos.indexWhere((p) => p.id == id);
    if (index <= 0) return;
    _edit(() {
      final photo = draft.photos.removeAt(index);
      draft.photos.insert(0, photo);
    });
    showToast(const ToastMessage('Cover photo updated.'));
  }

  void showToast(ToastMessage message, {Duration? duration}) =>
      _toasts.show(message, duration: duration);
}
