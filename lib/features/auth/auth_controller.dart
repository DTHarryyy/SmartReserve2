import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/verification.dart';

enum AuthStep {
  signIn,
  initialPassword,
  accessRequired,
  question,
  details,
  pending,
  guest,
  member,
}

class PasswordRequirement {
  const PasswordRequirement(this.label, this.met);

  final String label;
  final bool met;
}

enum CampusClaim {
  student('Student', 'Enrolled this academic year at CSU Aparri.', 'student'),
  faculty('Faculty', 'Teaching staff with a current appointment.', 'faculty'),
  staff('University staff', 'Non-teaching staff of the university.', 'staff'),
  none(
    'None of these',
    'Outside group, alumnus, or a private booking.',
    'none',
  );

  const CampusClaim(this.label, this.description, this.raw);

  final String label;
  final String description;
  final String raw;

  bool get needsVerification => this != CampusClaim.none;

  String get idLabel => switch (this) {
    CampusClaim.student => 'Student number',
    CampusClaim.faculty => 'Faculty ID number',
    _ => 'Employee number',
  };

  String get unitLabel => switch (this) {
    CampusClaim.student => 'Programme and year',
    _ => 'College or office',
  };

  String get documentLabel => switch (this) {
    CampusClaim.student => 'Certificate of registration, or your school ID',
    CampusClaim.faculty => 'Appointment paper, or your faculty ID',
    _ => 'Service record or staff ID',
  };
}

class SelectedDocument {
  const SelectedDocument({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

class AuthController extends ChangeNotifier {
  AuthController(this._state) {
    _hadSession = _state.hasSession;
    _state.addListener(_handleAppStateChanged);
    final profile = _state.sessionProfile;
    if (_state.hasSession && !_state.isAdmin && profile != null) {
      submissionId = _state.myVerification?.id;
      step = _nextStepFor(profile);
    }
  }

  final AppState _state;
  final _picker = ImagePicker();
  late bool _hadSession;

  AuthStep step = AuthStep.signIn;
  final emailField = TextEditingController();
  final passwordField = TextEditingController();
  final confirmPasswordField = TextEditingController();
  final idField = TextEditingController();
  final unitField = TextEditingController();
  CampusClaim claim = CampusClaim.student;
  SelectedDocument? document;
  String? submissionId;
  String? emailError;
  String? passwordError;
  String? confirmPasswordError;
  String? idError;
  String? unitError;
  String? documentError;
  String? operationError;
  bool busy = false;

  SmartReserveBackend? get _backend => _state.backend;

  AuthStep _nextStepFor(SessionProfile profile) {
    if (profile.mustChangePassword) return AuthStep.initialPassword;
    if (profile.accountAccessType == 'legacy_unassigned') {
      return AuthStep.accessRequired;
    }
    if (_state.myVerification != null) return AuthStep.pending;
    return profile.onboardingComplete ? AuthStep.member : AuthStep.question;
  }

  VerificationSubmission? get submission {
    final id = submissionId;
    if (id != null) {
      final match = _state.verifications
          .cast<VerificationSubmission?>()
          .firstWhere((item) => item?.id == id, orElse: () => null);
      if (match != null) return match;
    }
    return _state.verifications.isEmpty ? null : _state.verifications.first;
  }

  String? get documentName => document?.name;
  String get documentSizeLabel {
    final bytes = document?.bytes.lengthInBytes ?? 0;
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).ceil()} KB';
  }

  @override
  void dispose() {
    _state.removeListener(_handleAppStateChanged);
    emailField.dispose();
    passwordField.dispose();
    confirmPasswordField.dispose();
    idField.dispose();
    unitField.dispose();
    super.dispose();
  }

  void refresh() => notifyListeners();

  void goTo(AuthStep next) {
    step = next;
    emailError = null;
    passwordError = null;
    confirmPasswordError = null;
    idError = null;
    unitError = null;
    documentError = null;
    operationError = null;
    notifyListeners();
  }

  void restart() {
    resetToSignIn();
  }

  void resetToSignIn() {
    emailField.clear();
    passwordField.clear();
    confirmPasswordField.clear();
    idField.clear();
    unitField.clear();
    document = null;
    submissionId = null;
    claim = CampusClaim.student;
    busy = false;
    goTo(AuthStep.signIn);
  }

  void _handleAppStateChanged() {
    final hasSession = _state.hasSession;
    final signedOut = _hadSession && !hasSession;
    _hadSession = hasSession;
    if (signedOut) resetToSignIn();
  }

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  int get passwordStrength {
    final password = passwordField.text;
    if (password.isEmpty) return 0;
    var score = 0;
    if (password.length >= 10) score++;
    if (password.length >= 14) score++;
    if (RegExp(r'\s').hasMatch(password.trim())) score++;
    if (RegExp(r'[0-9!-/:-@]').hasMatch(password)) score++;
    return score.clamp(0, 4);
  }

  String get passwordNote => switch (passwordStrength) {
    0 => 'Use at least 10 characters.',
    1 => 'Longer passphrases are harder to guess.',
    2 => 'Good password length.',
    _ => 'Strong password.',
  };

  List<PasswordRequirement> get passwordRequirements {
    final value = passwordField.text;
    return [
      PasswordRequirement('At least 10 characters', value.length >= 10),
      PasswordRequirement(
        'One uppercase letter',
        RegExp(r'[A-Z]').hasMatch(value),
      ),
      PasswordRequirement(
        'One lowercase letter',
        RegExp(r'[a-z]').hasMatch(value),
      ),
      PasswordRequirement('One number', RegExp(r'[0-9]').hasMatch(value)),
    ];
  }

  bool get passwordMeetsRequirements =>
      passwordRequirements.every((requirement) => requirement.met);

  bool _validateCredentials({
    required bool requirePassword,
    bool enforceNewPasswordLength = true,
  }) {
    emailError = _emailPattern.hasMatch(emailField.text.trim())
        ? null
        : 'Enter a valid email address.';
    passwordError = !requirePassword
        ? null
        : passwordField.text.isEmpty
        ? 'Enter your password.'
        : enforceNewPasswordLength && passwordField.text.length < 10
        ? 'Use at least 10 characters.'
        : null;
    notifyListeners();
    return emailError == null && passwordError == null;
  }

  Future<void> submitSignIn() async {
    if (!_validateCredentials(
      requirePassword: true,
      enforceNewPasswordLength: false,
    )) {
      return;
    }
    await _perform(() async {
      final backend = _backend;
      if (backend == null) throw StateError('Supabase is not configured.');
      await backend.signIn(emailField.text.trim(), passwordField.text);
      final profile = await backend.currentProfile();
      if (profile == null) {
        await backend.signOut();
        throw StateError('The signed-in account has no profile.');
      }
      await _state.applyBackendProfile(profile);
      if (!_state.isAdmin) {
        passwordField.clear();
        confirmPasswordField.clear();
        goTo(_nextStepFor(profile));
      }
    });
  }

  Future<void> submitInitialPassword() async {
    if (!passwordMeetsRequirements) {
      passwordError = 'Your password does not meet all requirements.';
      notifyListeners();
      return;
    }
    if (confirmPasswordField.text != passwordField.text) {
      confirmPasswordError = 'Enter the same new password again.';
      notifyListeners();
      return;
    }
    passwordError = null;
    confirmPasswordError = null;
    await _perform(() async {
      final backend = _backend;
      if (backend == null) throw StateError('Supabase is not configured.');
      final profile = await backend.completeInitialPasswordChange(
        passwordField.text,
      );
      passwordField.clear();
      confirmPasswordField.clear();
      await _state.applyBackendProfile(profile);
      if (!_state.isAdmin) goTo(_nextStepFor(profile));
    });
  }

  void chooseClaim(CampusClaim value) {
    claim = value;
    notifyListeners();
  }

  Future<void> continueFromQuestion() async {
    if (claim.needsVerification) {
      operationError =
          'Campus reservations are managed through one authorized representative account per organization or office. Contact your Internal Admin for access.';
      notifyListeners();
      return;
    }
    await _perform(() async {
      final backend = _backend;
      if (backend == null) throw StateError('Supabase is not configured.');
      await backend.completeGuestOnboarding();
      await _state.applyBackendProfile(await backend.currentProfile());
      goTo(AuthStep.guest);
    });
  }

  Future<void> takeDocumentPhoto() async {
    final image = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
    );
    if (image == null) return;
    await _setDocument(
      name: image.name,
      bytes: await image.readAsBytes(),
      mimeType: _mimeForName(image.name),
    );
  }

  Future<void> chooseDocument() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _setDocument(
      name: file.name,
      bytes: bytes,
      mimeType: _mimeForName(file.name),
    );
  }

  Future<void> _setDocument({
    required String name,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (bytes.lengthInBytes > 10 * 1024 * 1024) {
      documentError = 'Choose a file smaller than 10 MB.';
      notifyListeners();
      return;
    }
    if (mimeType.isEmpty) {
      documentError = 'Choose a JPG, PNG, or PDF file.';
      notifyListeners();
      return;
    }
    document = SelectedDocument(name: name, mimeType: mimeType, bytes: bytes);
    documentError = null;
    notifyListeners();
  }

  void attachDocument(String name) {
    documentError = 'Choose a real JPG, PNG, or PDF document.';
    notifyListeners();
  }

  void clearDocument() {
    document = null;
    notifyListeners();
  }

  Future<void> submitVerification() async {
    final selected = document;
    if (selected == null) {
      documentError = 'A document is required.';
      notifyListeners();
      return;
    }
    idError = idField.text.trim().isEmpty
        ? 'Enter your ${claim.idLabel.toLowerCase()}.'
        : null;
    unitError = unitField.text.trim().isEmpty
        ? 'Enter your ${claim.unitLabel.toLowerCase()}.'
        : null;
    if (idError != null || unitError != null) {
      notifyListeners();
      return;
    }
    await _perform(() async {
      final backend = _backend;
      if (backend == null) throw StateError('Supabase is not configured.');
      final record = await backend.submitVerification(
        claimType: claim.raw,
        campusId: idField.text.trim(),
        unit: unitField.text.trim(),
        documentName: selected.name,
        mimeType: selected.mimeType,
        bytes: selected.bytes,
      );
      submissionId = record.id;
      await _state.applyBackendProfile(await backend.currentProfile());
      await _state.refreshMyVerification();
      goTo(AuthStep.pending);
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    busy = true;
    operationError = null;
    notifyListeners();
    try {
      await action();
    } catch (error, stackTrace) {
      debugPrint('SmartReserve auth failure: $error');
      debugPrintStack(stackTrace: stackTrace);
      final message = _userMessageFor(error);
      operationError = message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  String _userMessageFor(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('weak_password') ||
        message.contains('password does not meet')) {
      return 'Choose a password with at least 10 characters, uppercase, lowercase, and a number.';
    }
    if (message.contains('invalid login credentials')) {
      return 'That email address or password is incorrect.';
    }
    if (message.contains('signed-in account has no profile')) {
      return 'This account is missing its SmartReserve profile. Ask an internal administrator to repair it.';
    }
    if (message.contains('email not confirmed')) {
      return 'This account cannot sign in yet. Please tell the prototype administrator.';
    }
    if (message.contains('organization assignment') ||
        message.contains('legacy_unassigned') ||
        message.contains('cannot be converted to a guest')) {
      return 'This account needs an Internal Admin to assign an organization account before it can reserve.';
    }
    if (message.contains('pgrst201')) {
      return 'Your account was confirmed, but we could not load your account details. Please try again.';
    }
    if (message.contains('socketexception') ||
        message.contains('failed host lookup') ||
        message.contains('clientexception')) {
      return 'We could not reach SmartReserve. Check your connection and try again.';
    }
    if (message.contains('supabase is not configured')) {
      return 'SmartReserve is not connected. Restart the app and try again.';
    }
    return 'We could not complete that request. Please try again.';
  }

  String _mimeForName(String name) =>
      switch (name.split('.').last.toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'pdf' => 'application/pdf',
        _ => '',
      };
}
