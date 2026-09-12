import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../backend/supabase_service.dart';
import '../../model/verification.dart';

enum AuthStep {
  signIn,
  passwordResetRequest,
  passwordResetSent,
  passwordReset,
  createAccount,
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
    _authSubscription = _backend?.authChanges.listen(_handleAuthChange);
    final profile = _state.sessionProfile;
    if (_state.hasSession && !_state.isAdmin && profile != null) {
      submissionId = _state.myVerification?.id;
      step = _nextStepFor(profile);
    }
  }

  final AppState _state;
  final _picker = ImagePicker();
  late bool _hadSession;
  StreamSubscription<AuthState>? _authSubscription;

  AuthStep step = AuthStep.signIn;
  final emailField = TextEditingController();
  final fullNameField = TextEditingController();
  final passwordField = TextEditingController();
  final confirmPasswordField = TextEditingController();
  final resetCodeField = TextEditingController();
  final idField = TextEditingController();
  final unitField = TextEditingController();
  CampusClaim claim = CampusClaim.student;
  SelectedDocument? document;
  String? submissionId;
  String? emailError;
  String? fullNameError;
  String? passwordError;
  String? confirmPasswordError;
  String? resetCodeError;
  String? idError;
  String? unitError;
  String? documentError;
  String? operationError;
  String? operationNotice;
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
    _authSubscription?.cancel();
    emailField.dispose();
    fullNameField.dispose();
    passwordField.dispose();
    confirmPasswordField.dispose();
    resetCodeField.dispose();
    idField.dispose();
    unitField.dispose();
    super.dispose();
  }

  void refresh() => notifyListeners();

  void setResetCode(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    final code = digits.length > 6 ? digits.substring(0, 6) : digits;
    if (resetCodeField.text == code) return;
    resetCodeField.value = TextEditingValue(
      text: code,
      selection: TextSelection.collapsed(offset: code.length),
    );
    resetCodeError = null;
    notifyListeners();
  }

  void goTo(AuthStep next) {
    step = next;
    emailError = null;
    fullNameError = null;
    passwordError = null;
    confirmPasswordError = null;
    resetCodeError = null;
    idError = null;
    unitError = null;
    documentError = null;
    operationError = null;
    operationNotice = null;
    notifyListeners();
  }

  void restart() {
    resetToSignIn();
  }

  void resetToSignIn() {
    emailField.clear();
    fullNameField.clear();
    passwordField.clear();
    confirmPasswordField.clear();
    resetCodeField.clear();
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

  void _handleAuthChange(AuthState authState) {
    if (authState.event != AuthChangeEvent.passwordRecovery) return;
    _state.goTo(AppView.auth);
    goTo(AuthStep.passwordReset);
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
      final profile = await backend.signInAndLoadProfile(
        emailField.text.trim(),
        passwordField.text,
      );
      await _state.applyBackendProfile(profile);
      if (!_state.isAdmin) {
        passwordField.clear();
        confirmPasswordField.clear();
        goTo(_nextStepFor(profile));
      }
    });
  }

  Future<void> requestPasswordReset() async {
    if (!_validateCredentials(requirePassword: false)) return;
    await _perform(() async {
      final backend = _backend;
      if (backend == null) throw StateError('Supabase is not configured.');
      await backend.requestPasswordReset(emailField.text.trim());
      goTo(AuthStep.passwordResetSent);
    });
  }

  Future<void> verifyPasswordResetCode() async {
    final code = resetCodeField.text.trim();
    resetCodeError = RegExp(r'^\d{6}$').hasMatch(code)
        ? null
        : 'Enter the six-digit code from your email.';
    if (resetCodeError != null) {
      notifyListeners();
      return;
    }
    await _perform(() async {
      final backend = _backend;
      if (backend == null) throw StateError('Supabase is not configured.');
      await backend.verifyPasswordResetCode(
        email: emailField.text.trim(),
        code: code,
      );
      resetCodeField.clear();
      goTo(AuthStep.passwordReset);
    });
  }

  Future<void> submitPasswordReset() async {
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
      await backend.updatePassword(passwordField.text);
      passwordField.clear();
      confirmPasswordField.clear();
      await _state.signOut();
      goTo(AuthStep.signIn);
      operationNotice = 'Password updated. Sign in with your new password.';
    });
  }

  Future<void> createExternalGuestAccount() async {
    fullNameError = fullNameField.text.trim().length >= 2
        ? null
        : 'Enter your full name.';
    if (!_validateCredentials(requirePassword: true)) return;
    if (fullNameError != null) {
      notifyListeners();
      return;
    }
    if (!passwordMeetsRequirements) {
      passwordError = 'Your password does not meet all requirements.';
      notifyListeners();
      return;
    }
    if (confirmPasswordField.text != passwordField.text) {
      confirmPasswordError = 'Enter the same password again.';
      notifyListeners();
      return;
    }
    await _perform(() async {
      final backend = _backend;
      if (backend == null) throw StateError('Supabase is not configured.');
      final profile = await backend.createExternalGuestAccount(
        fullName: fullNameField.text.trim(),
        email: emailField.text.trim(),
        password: passwordField.text,
      );
      passwordField.clear();
      confirmPasswordField.clear();
      await _state.applyBackendProfile(profile);
      goTo(AuthStep.guest);
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
      if (kDebugMode) {
        if (error case AuthSessionException failure) {
          debugPrint(
            'SmartReserve auth failure: ${failure.kind.name} '
            'status=${failure.statusCode ?? '-'} '
            'code=${failure.backendCode ?? '-'}',
          );
        } else {
          debugPrint('SmartReserve auth failure: $error');
        }
        debugPrintStack(stackTrace: stackTrace);
      }
      final message = userMessageFor(error);
      operationError = message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @visibleForTesting
  static String userMessageFor(Object error) {
    if (error case AuthSessionException(:final kind)) {
      return switch (kind) {
        AuthFailureKind.invalidCredentials =>
          'That email address or password is incorrect.',
        AuthFailureKind.emailUnconfirmed =>
          'This prototype account is not confirmed. Contact an Internal Admin.',
        AuthFailureKind.emailConfirmationRequired =>
          'Check your email to confirm this account, then sign in.',
        AuthFailureKind.emailAlreadyRegistered =>
          'An account already uses that email address. Sign in instead.',
        AuthFailureKind.rateLimited =>
          'Too many sign-in attempts. Wait a few minutes and try again.',
        AuthFailureKind.network =>
          'SmartReserve could not be reached. Check your connection and try again.',
        AuthFailureKind.profileMissing =>
          'Your credentials were accepted, but this account has not been set up. Contact an Internal Admin.',
        AuthFailureKind.profileContractUnavailable =>
          'SmartReserve is updating account access. Please try again shortly.',
        AuthFailureKind.profileAccessDenied =>
          'This account cannot load its access profile. Contact an Internal Admin.',
        AuthFailureKind.unknown =>
          'We couldn’t complete sign-in. Please try again.',
      };
    }
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
