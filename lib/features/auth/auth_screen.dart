import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../model/verification.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/sr_controls.dart';
import 'auth_controller.dart';

class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key, required this.controller, required this.state});

  final AuthController controller;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final desktop = width >= SR.desktopMin;
          final tablet = width >= SR.tabletMin && !desktop;
          final reduceMotion = MediaQuery.disableAnimationsOf(context);
          final content = SafeArea(
            child: Scrollbar(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  desktop
                      ? 48
                      : tablet
                      ? 32
                      : 20,
                  desktop ? 40 : 20,
                  desktop
                      ? 48
                      : tablet
                      ? 32
                      : 20,
                  24 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: tablet ? 660 : 510),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!desktop) _topBar(),
                        if (tablet) ...[
                          const SizedBox(height: 18),
                          const _HeroBanner(),
                        ],
                        const SizedBox(height: 18),
                        if (_progressLabels.isNotEmpty) _progress(),
                        _Card(
                          framed: width >= SR.tabletMin,
                          child: AnimatedSwitcher(
                            duration: reduceMotion
                                ? Duration.zero
                                : SR.entrance,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween(
                                      begin: const Offset(.025, 0),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                            child: KeyedSubtree(
                              key: ValueKey(controller.step),
                              child: _body(context),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Office of the Registrar · Cagayan State University, Aparri Campus',
                          textAlign: TextAlign.center,
                          style: sans(11.5, height: 1.5, color: SR.ink4),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          return ColoredBox(
            color: width < SR.tabletMin ? SR.surface : SR.bg,
            child: desktop
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Expanded(flex: 45, child: _Pitch()),
                      Expanded(flex: 55, child: content),
                    ],
                  )
                : content,
          );
        },
      ),
    );
  }

  Widget _topBar() => const _BrandHeader();

  List<String> get _progressLabels => switch (controller.step) {
    AuthStep.signUp ||
    AuthStep.otp ||
    AuthStep.question ||
    AuthStep.details ||
    AuthStep.pending => const [
      '1 Account',
      '2 Confirm email',
      '3 Campus status',
    ],
    AuthStep.forgot ||
    AuthStep.reset => const ['1 Email', '2 Reset code', '3 New password'],
    _ => const [],
  };

  int get _progressIndex => switch (controller.step) {
    AuthStep.signUp => 0,
    AuthStep.otp => 1,
    AuthStep.forgot => 0,
    AuthStep.reset => 1,
    _ => 2,
  };

  Widget _progress() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        for (var i = 0; i < _progressLabels.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  height: 3,
                  decoration: BoxDecoration(
                    color: i <= _progressIndex ? SR.blue : SR.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _progressLabels[i],
                  style: mono(9, w: 500, tracking: .03, color: SR.muted),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );

  Widget _body(BuildContext context) => AutofillGroup(
    child: switch (controller.step) {
      AuthStep.signUp => _signUp(),
      AuthStep.signIn => _signIn(),
      AuthStep.otp => _otp(),
      AuthStep.question => _question(),
      AuthStep.details => _details(),
      AuthStep.pending => _pending(),
      AuthStep.forgot => _forgot(),
      AuthStep.reset => _reset(),
      AuthStep.guest => _guest(),
      AuthStep.member => _member(),
    },
  );

  Widget _signUp() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Create your account'),
      _Lede(
        'Use the same name shown on your campus document. We will email a six-digit confirmation code.',
      ),
      const SizedBox(height: 16),
      const SrLabel('Full name'),
      SrTextField(
        controller: controller.fullNameField,
        placeholder: 'e.g. Juan Dela Cruz',
        semanticLabel: 'Full name',
        hasError: controller.fullNameError != null,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.name],
        textCapitalization: TextCapitalization.words,
      ),
      SrErrorText(controller.fullNameError),
      const SizedBox(height: 10),
      const SrLabel('Email address'),
      SrTextField(
        controller: controller.emailField,
        placeholder: 'e.g. juan.delacruz@example.com',
        semanticLabel: 'Email address',
        keyboardType: TextInputType.emailAddress,
        hasError: controller.emailError != null,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.newUsername, AutofillHints.email],
        autocorrect: false,
      ),
      SrErrorText(controller.emailError),
      const SrLabel('Password'),
      _PasswordField(controller: controller, newPassword: true),
      const SizedBox(height: 7),
      Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 3,
                decoration: BoxDecoration(
                  color: i < controller.passwordStrength
                      ? (controller.passwordStrength >= 3
                            ? SR.green
                            : SR.orange)
                      : SR.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 6),
      Text(controller.passwordNote, style: sans(11, color: SR.muted)),
      SrErrorText(controller.passwordError),
      const SizedBox(height: 16),
      _submitButton(
        'Send confirmation code',
        'Creating account…',
        controller.submitSignUp,
      ),
      SrErrorText(controller.operationError),
      const SizedBox(height: 12),
      _FooterLink(
        prefix: 'Already registered?',
        label: 'Sign in',
        onTap: () => controller.goTo(AuthStep.signIn),
      ),
      const SizedBox(height: 10),
      Text(
        'This form produces users only. Administrators are invited by an '
        'existing internal admin.',
        style: sans(10.5, height: 1.6, color: SR.mutedLight),
      ),
    ],
  );

  Widget _signIn() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Sign in to SmartReserve'),
      _Lede(
        'Reserve CSU Aparri facilities and follow every request in one place.',
      ),
      const SizedBox(height: 16),
      const SrLabel('Email address'),
      SrTextField(
        controller: controller.emailField,
        placeholder: 'name@example.com',
        semanticLabel: 'Email address',
        keyboardType: TextInputType.emailAddress,
        hasError: controller.emailError != null,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.username, AutofillHints.email],
        autocorrect: false,
      ),
      SrErrorText(controller.emailError),
      SrLabel(
        'Password',
        meta: _InlineLink(
          label: 'Forgot password',
          onTap: () => controller.goTo(AuthStep.forgot),
        ),
      ),
      _PasswordField(
        controller: controller,
        placeholder: 'Enter your password',
        onSubmitted: (_) => controller.busy ? null : controller.submitSignIn(),
      ),
      const SizedBox(height: 16),
      _submitButton('Sign in', 'Signing in…', controller.submitSignIn),
      SrErrorText(controller.operationError),
      const SizedBox(height: 12),
      _FooterLink(
        prefix: 'New here?',
        label: 'Create an account',
        onTap: () => controller.goTo(AuthStep.signUp),
      ),
    ],
  );

  Widget _otp() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Confirm your email'),
      _Lede(
        'Enter the six-digit code sent to '
        '${_maskedEmail(controller.emailField.text.trim())}. It expires in 15 minutes.',
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: _InlineLink(
          label: 'Use another email',
          onTap: () => controller.goTo(AuthStep.signUp),
        ),
      ),
      const SizedBox(height: 18),
      _OtpCells(controller: controller, label: '6-digit confirmation code'),
      SrErrorText(controller.otpError),
      const SizedBox(height: 12),
      _submitButton(
        'Confirm and continue',
        'Confirming code…',
        controller.confirmOtp,
      ),
      const SizedBox(height: 12),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _InlineLink(
            label: controller.resendSeconds > 0
                ? 'Resend code in ${controller.resendSeconds}s'
                : 'Resend code',
            onTap: () => controller.resendCode(),
            enabled: !controller.busy && controller.resendSeconds == 0,
          ),
        ],
      ),
    ],
  );

  Widget _question() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('How are you connected to CSU Aparri?'),
      _Lede(
        'Campus members reserve facilities free of charge after verification. '
        'Outside groups may reserve at the published rate. Answer honestly — '
        'the registrar checks documents.',
      ),
      const SizedBox(height: 16),
      for (final claim in CampusClaim.values)
        _ClaimOption(
          claim: claim,
          selected: controller.claim == claim,
          onTap: () => controller.chooseClaim(claim),
        ),
      const SizedBox(height: 16),
      _submitButton(
        'Continue',
        'Saving selection…',
        controller.continueFromQuestion,
      ),
    ],
  );

  Widget _details() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Verify your ${controller.claim.label.toLowerCase()} status'),
      _Lede(
        'The registrar checks this within one business day. Your document is '
        'visible only to them and is deleted after the decision.',
      ),
      const SizedBox(height: 16),
      SrLabel(controller.claim.idLabel),
      SrTextField(
        controller: controller.idField,
        placeholder: _idPlaceholder,
        semanticLabel: controller.claim.idLabel,
        mono: true,
        hasError: controller.idError != null,
        textInputAction: TextInputAction.next,
      ),
      SrErrorText(controller.idError),
      const SizedBox(height: 10),
      SrLabel(controller.claim.unitLabel),
      SrTextField(
        controller: controller.unitField,
        placeholder: _unitPlaceholder,
        semanticLabel: controller.claim.unitLabel,
        hasError: controller.unitError != null,
        textCapitalization: TextCapitalization.words,
      ),
      SrErrorText(controller.unitError),
      const SizedBox(height: 14),
      DashedBox(
        radius: 11,
        background: SR.surfaceSubtle,
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Text(
              controller.claim.documentLabel,
              textAlign: TextAlign.center,
              style: sans(12, w: 500, color: SR.ink2),
            ),
            const SizedBox(height: 3),
            Text(
              'JPG, PNG, or PDF · up to 10 MB · make sure your name and ID are readable',
              textAlign: TextAlign.center,
              style: sans(10.5, color: SR.muted),
            ),
            const SizedBox(height: 11),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 7,
              runSpacing: 7,
              children: [
                SrButton(
                  label: 'Take a photo',
                  kind: SrButtonKind.primary,
                  dense: true,
                  fontSize: 11.5,
                  onPressed: controller.busy
                      ? null
                      : () => controller.takeDocumentPhoto(),
                ),
                SrButton(
                  label: 'Choose a file',
                  dense: true,
                  fontSize: 11.5,
                  onPressed: controller.busy
                      ? null
                      : () => controller.chooseDocument(),
                ),
              ],
            ),
            if (controller.documentName case final name?) ...[
              const SizedBox(height: 11),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: SR.blueTint,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        '$name · ${controller.documentSizeLabel}',
                        overflow: TextOverflow.ellipsis,
                        style: mono(11, color: SR.blueDark),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Hoverable(
                      builder: (context, hovered) => GestureDetector(
                        onTap: controller.clearDocument,
                        child: Text(
                          '✕',
                          style: sans(
                            11,
                            color: hovered ? SR.blueDark : SR.blueToken,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      SrErrorText(controller.documentError),
      const SizedBox(height: 12),
      _submitButton(
        'Submit for verification',
        'Uploading document…',
        controller.submitVerification,
      ),
      SrErrorText(controller.operationError),
    ],
  );

  Widget _pending() {
    final submission = controller.submission;
    final decision = submission?.decision ?? VerificationDecision.pending;

    return switch (decision) {
      VerificationDecision.approved => _Outcome(
        glyph: Icons.check_rounded,
        background: SR.greenTint,
        foreground: SR.greenDark,
        title: 'You are verified',
        body:
            'The registrar confirmed your campus status. Reservations are now '
            'free of charge and any request you left waiting has been '
            'released.',
        action: SrButton(
          label: 'Go to your account',
          kind: SrButtonKind.primary,
          expand: true,
          minHeight: 44,
          fontSize: 13,
          onPressed: () => state.goTo(AppView.userApp),
        ),
      ),
      VerificationDecision.changesRequested => _Outcome(
        glyph: Icons.refresh_rounded,
        background: const Color(0xFFFFFAEB),
        foreground: SR.amber,
        title: 'A clearer document is needed',
        body: submission?.reason ?? '',
        quoteBody: true,
        footnote: 'Your place in the queue is kept — this is not a rejection.',
        action: SrButton(
          label: 'Send a new photo',
          kind: SrButtonKind.primary,
          expand: true,
          minHeight: 44,
          fontSize: 13,
          onPressed: () => controller.goTo(AuthStep.details),
        ),
      ),
      VerificationDecision.rejected => _Outcome(
        glyph: Icons.close_rounded,
        background: SR.redTint,
        foreground: SR.red,
        title: 'Verification was not approved',
        body: submission?.reason ?? '',
        quoteBody: true,
        footnote:
            'You may appeal once with a different document. Your account still '
            'works — you can reserve at the external rate in the meantime.',
        action: Column(
          children: [
            SrButton(
              label: 'Appeal with another document',
              kind: SrButtonKind.primary,
              expand: true,
              minHeight: 44,
              fontSize: 13,
              onPressed: () => controller.goTo(AuthStep.details),
            ),
            const SizedBox(height: 8),
            SrButton(
              label: 'Continue as a paying guest',
              expand: true,
              minHeight: 44,
              fontSize: 12.5,
              onPressed: () => state.goTo(AppView.userApp),
            ),
          ],
        ),
      ),
      VerificationDecision.pending => _Outcome(
        glyph: Icons.hourglass_empty_rounded,
        background: const Color(0xFFFFFAEB),
        foreground: SR.amber,
        title: 'Waiting for the registrar',
        body:
            'Campus documents are reviewed each morning — usually within one '
            'business day. Return here to see the decision.',
        panel:
            'Browse facilities, view them on the campus map, and prepare a '
            'reservation. Requests you submit are held and released '
            'automatically the moment you are verified — nothing is lost by '
            'starting now.',
        panelTitle: 'What you can do now',
        action: Column(
          children: [
            SrButton(
              label: 'Browse facilities meanwhile',
              kind: SrButtonKind.primary,
              expand: true,
              minHeight: 44,
              fontSize: 13,
              onPressed: () => state.goTo(AppView.userApp),
            ),
          ],
        ),
      ),
    };
  }

  Widget _forgot() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Reset your password'),
      _Lede(
        'We send a six-digit code to your registered email. For your security '
        'the message is the same whether or not the address exists.',
      ),
      const SizedBox(height: 16),
      const SrLabel('Email address'),
      SrTextField(
        controller: controller.emailField,
        placeholder: 'name@example.com',
        semanticLabel: 'Email address',
        keyboardType: TextInputType.emailAddress,
        hasError: controller.emailError != null,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.email],
        autocorrect: false,
        onSubmitted: (_) => controller.busy ? null : controller.sendReset(),
      ),
      SrErrorText(controller.emailError),
      const SizedBox(height: 14),
      _submitButton(
        'Send reset code',
        'Sending reset code…',
        controller.sendReset,
      ),
      SrErrorText(controller.operationError),
      const SizedBox(height: 12),
      Center(
        child: _InlineLink(
          label: 'Back to sign in',
          onTap: () => controller.goTo(AuthStep.signIn),
        ),
      ),
    ],
  );

  Widget _reset() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Enter your reset code'),
      _Lede(
        'We sent a six-digit code to ${_maskedEmail(controller.emailField.text.trim())}. Then choose a new password.',
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: _InlineLink(
          label: 'Edit email address',
          onTap: () => controller.goTo(AuthStep.forgot),
        ),
      ),
      const SizedBox(height: 14),
      _OtpCells(controller: controller, label: '6-digit reset code'),
      SrErrorText(controller.otpError),
      const SizedBox(height: 10),
      const SrLabel('New password'),
      _PasswordField(
        controller: controller,
        newPassword: true,
        placeholder: 'Create a new passphrase',
      ),
      SrErrorText(controller.passwordError),
      const SizedBox(height: 10),
      const SrLabel('Confirm new password'),
      _PasswordField(
        controller: controller,
        fieldController: controller.confirmPasswordField,
        placeholder: 'Enter the new password again',
        semanticLabel: 'Confirm new password',
        hasError: controller.confirmPasswordError != null,
        onSubmitted: (_) => controller.busy ? null : controller.confirmReset(),
      ),
      SrErrorText(controller.confirmPasswordError),
      Center(
        child: _InlineLink(
          label: controller.resendSeconds > 0
              ? 'Resend code in ${controller.resendSeconds}s'
              : 'Resend reset code',
          onTap: controller.resendResetCode,
          enabled: !controller.busy && controller.resendSeconds == 0,
        ),
      ),
      const SizedBox(height: 14),
      _submitButton(
        'Change password',
        'Changing password…',
        controller.confirmReset,
      ),
      SrErrorText(controller.operationError),
    ],
  );

  Widget _guest() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title("You're all set"),
      _Lede(
        'No documents needed. You can reserve any facility open to outside '
        'groups.',
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: SR.blueTint2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: SR.blueLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How payment works',
              style: sans(11.5, w: 600, color: SR.blueDark),
            ),
            const SizedBox(height: 4),
            Text(
              'You see the rate before you request. Payment is authorised once '
              'the registrar approves and captured when you check in. If the '
              'request is declined or the facility closes for maintenance, '
              'nothing is charged.',
              style: sans(11.5, height: 1.7, color: SR.blueInk),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Text.rich(
        TextSpan(
          text: 'Students and faculty of CSU Aparri reserve free. ',
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _InlineLink(
                label: 'I am a campus member',
                onTap: () => controller.goTo(AuthStep.question),
              ),
            ),
          ],
        ),
        style: sans(11.5, height: 1.6, color: SR.ink4),
      ),
      const SizedBox(height: 14),
      SrButton(
        label: 'Browse facilities',
        kind: SrButtonKind.primary,
        expand: true,
        minHeight: 44,
        fontSize: 13,
        onPressed: () => state.goTo(AppView.userApp),
      ),
    ],
  );

  Widget _member() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Your account'),
      _Lede(
        'You are signed in. The catalogue and the booking flow are in the '
        'student app.',
      ),
      const SizedBox(height: 14),
      SrButton(
        label: 'Open the student app',
        kind: SrButtonKind.primary,
        expand: true,
        minHeight: 44,
        fontSize: 13,
        onPressed: () => state.goTo(AppView.userApp),
      ),
      const SizedBox(height: 8),
      SrButton(
        label: 'Restart onboarding',
        expand: true,
        minHeight: 44,
        fontSize: 12.5,
        onPressed: controller.restart,
      ),
    ],
  );

  String get _idPlaceholder => switch (controller.claim) {
    CampusClaim.student => 'e.g. 2022-01458',
    CampusClaim.faculty => 'e.g. FAC-01234',
    CampusClaim.staff => 'e.g. EMP-01234',
    CampusClaim.none => 'Enter your identification number',
  };

  String get _unitPlaceholder => switch (controller.claim) {
    CampusClaim.student => 'e.g. BS Information Technology, 4th Year',
    CampusClaim.faculty => 'e.g. College of Information and Computing Sciences',
    CampusClaim.staff => 'e.g. Office of the Registrar',
    CampusClaim.none => 'e.g. Office or organisation',
  };

  String _maskedEmail(String email) {
    final parts = email.split('@');
    if (parts.length != 2 || parts.first.length < 3) return email;
    return '${parts.first.substring(0, 2)}${'•' * (parts.first.length - 2)}@${parts.last}';
  }

  Widget _submitButton(
    String label,
    String busyLabel,
    Future<void> Function() action,
  ) => SrButton(
    label: controller.busy ? busyLabel : label,
    kind: SrButtonKind.primary,
    expand: true,
    minHeight: 48,
    fontSize: 13.5,
    trailing: controller.busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: SR.muted),
          )
        : null,
    onPressed: controller.busy ? null : action,
  );
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: SR.blue,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('S', style: sans(17, w: 700, color: SR.surface)),
      ),
      const SizedBox(width: 12),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SmartReserve', style: sans(15, w: 600, tracking: -.01)),
          Text(
            'CSU APARRI',
            style: mono(10, w: 500, tracking: .04, color: SR.ink4),
          ),
        ],
      ),
    ],
  );
}

class _HeroBanner extends StatelessWidget {
  const _HeroBanner();

  @override
  Widget build(BuildContext context) => Container(
    height: 184,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: SR.navBg,
      borderRadius: BorderRadius.circular(18),
      gradient: const LinearGradient(
        colors: [Color(0xFF101418), Color(0xFF163D6B)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Stack(
      children: [
        const Positioned(right: 30, top: 28, child: _FacilityMotif()),
        Padding(
          padding: const EdgeInsets.all(22),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 310,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CSU APARRI',
                    style: mono(10, w: 500, tracking: .06, color: SR.blueSoft),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Every campus space, easier to find and reserve.',
                    style: sans(22, w: 600, height: 1.25, color: SR.surface),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _FacilityMotif extends StatelessWidget {
  const _FacilityMotif();

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: .8,
    child: SizedBox(
      width: 150,
      height: 120,
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: 0,
            child: Icon(
              Icons.location_on_rounded,
              size: 42,
              color: SR.blueBright,
            ),
          ),
          Positioned(
            right: 42,
            bottom: 3,
            child: Icon(
              Icons.apartment_rounded,
              size: 82,
              color: Color(0x42FFFFFF),
            ),
          ),
          Positioned(
            right: 4,
            bottom: 0,
            child: Container(width: 122, height: 1, color: Color(0x52FFFFFF)),
          ),
        ],
      ),
    ),
  );
}

class _Pitch extends StatelessWidget {
  const _Pitch();

  static const _pillars = [
    (
      '01',
      'Every room, pinned',
      'Forty-six facilities, each at its real coordinates.',
    ),
    (
      '02',
      'One decision queue',
      'The registrar clears requests without creating a clash.',
    ),
    (
      '03',
      'Free for campus members',
      'Verified students and faculty reserve at no charge.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0xFF101418), Color(0xFF14283F)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 40),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: SR.blue,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text('S', style: sans(14, w: 700, color: SR.surface)),
            ),
            const SizedBox(width: 11),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SmartReserve',
                  style: sans(15, w: 600, tracking: -.01, color: SR.surface),
                ),
                Text(
                  'CAGAYAN STATE UNIVERSITY — APARRI',
                  style: mono(10, color: const Color(0x73FFFFFF)),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 44),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Text(
            'Reserve any room on campus, and know exactly where it is.',
            style: sans(
              30,
              w: 600,
              height: 1.18,
              tracking: -.03,
              color: SR.surface,
            ),
          ),
        ),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 330),
          child: Text(
            'Forty-six facilities across the Aparri campus, each pinned to its '
            'real coordinates.',
            style: sans(13, height: 1.7, color: const Color(0x8CFFFFFF)),
          ),
        ),
        const Spacer(),
        for (final (number, title, body) in _pillars)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    number,
                    style: mono(10, w: 500, color: SR.blueBright),
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: sans(12.5, w: 600, color: SR.surface)),
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: sans(
                          11.5,
                          height: 1.6,
                          color: const Color(0x7AFFFFFF),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.framed = true});

  final Widget child;
  final bool framed;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(framed ? 28 : 0),
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(14),
      border: framed ? Border.all(color: SR.border) : null,
      boxShadow: framed
          ? const [
              BoxShadow(
                color: Color(0x0F10141A),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ]
          : null,
    ),
    child: child,
  );
}

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: sans(19, w: 600, height: 1.35, tracking: -.02));
}

class _Lede extends StatelessWidget {
  const _Lede(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 5),
    child: Text(text, style: sans(12, height: 1.6, color: SR.ink4)),
  );
}

class _PasswordField extends StatefulWidget {
  const _PasswordField({
    required this.controller,
    this.fieldController,
    this.placeholder,
    this.semanticLabel = 'Password',
    this.hasError,
    this.newPassword = false,
    this.onSubmitted,
  });

  final AuthController controller;
  final TextEditingController? fieldController;
  final String? placeholder;
  final String semanticLabel;
  final bool? hasError;
  final bool newPassword;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool hidden = true;

  @override
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    return SrTextField(
      controller: widget.fieldController ?? widget.controller.passwordField,
      placeholder:
          widget.placeholder ??
          (widget.newPassword
              ? 'Create a passphrase of 10+ characters'
              : 'Enter your password'),
      semanticLabel: widget.semanticLabel,
      hasError: widget.hasError ?? widget.controller.passwordError != null,
      obscureText: hidden,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: [
        widget.newPassword ? AutofillHints.newPassword : AutofillHints.password,
      ],
      textInputAction: widget.onSubmitted == null
          ? TextInputAction.next
          : TextInputAction.done,
      onSubmitted: widget.onSubmitted,
      onChanged: (_) => widget.controller.refresh(),
      suffix: Semantics(
        button: true,
        label: hidden ? 'Show password' : 'Hide password',
        child: SizedBox.square(
          dimension: compact ? 44 : 20,
          child: IconButton(
            tooltip: hidden ? 'Show password' : 'Hide password',
            constraints: BoxConstraints.tightFor(
              width: compact ? 44 : 20,
              height: compact ? 44 : 20,
            ),
            padding: EdgeInsets.zero,
            icon: Icon(
              hidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 19,
              color: SR.ink4,
            ),
            onPressed: () => setState(() => hidden = !hidden),
          ),
        ),
      ),
    );
  }
}

class _OtpCells extends StatelessWidget {
  const _OtpCells({required this.controller, required this.label});

  final AuthController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    final code = controller.otpField.text;
    return Semantics(
      label: label,
      textField: true,
      value: code.isEmpty
          ? 'No code entered'
          : '${code.length} of 6 digits entered',
      child: Stack(
        children: [
          Row(
            children: [
              for (var i = 0; i < 6; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: SR.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: i < code.length ? SR.blue : SR.borderField,
                      ),
                    ),
                    child: Text(
                      i < code.length ? code[i] : '',
                      style: mono(20, w: 500),
                    ),
                  ),
                ),
              ],
            ],
          ),
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: controller.otpField,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                textInputAction: TextInputAction.done,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                onChanged: (_) => controller.refresh(),
                decoration: const InputDecoration(border: InputBorder.none),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClaimOption extends StatelessWidget {
  const _ClaimOption({
    required this.claim,
    required this.selected,
    required this.onTap,
  });

  final CampusClaim claim;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      button: true,
      selected: selected,
      child: Hoverable(
        builder: (context, hovered) => Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: AnimatedContainer(
              duration: SR.stateChange,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              decoration: BoxDecoration(
                color: selected ? SR.blueTint : SR.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected
                      ? SR.blue
                      : (hovered ? SR.blueSoft : SR.border),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    margin: const EdgeInsets.only(top: 2),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? SR.blue : SR.borderField,
                      ),
                    ),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: selected ? SR.blue : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(claim.label, style: sans(12.5, w: 600)),
                        const SizedBox(height: 2),
                        Text(
                          claim.description,
                          style: sans(11, height: 1.5, color: SR.ink4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Outcome extends StatelessWidget {
  const _Outcome({
    required this.glyph,
    required this.background,
    required this.foreground,
    required this.title,
    required this.body,
    required this.action,
    this.panel,
    this.panelTitle,
    this.footnote,
    this.quoteBody = false,
  });

  final IconData glyph;
  final Color background;
  final Color foreground;
  final String title;
  final String body;
  final Widget action;
  final String? panel;
  final String? panelTitle;
  final String? footnote;

  final bool quoteBody;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Center(
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(glyph, size: 20, color: foreground),
        ),
      ),
      const SizedBox(height: 14),
      Text(
        title,
        textAlign: TextAlign.center,
        style: sans(16.5, w: 600, tracking: -.015),
      ),
      const SizedBox(height: 6),
      if (quoteBody && body.isNotEmpty)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: foreground.withValues(alpha: .3)),
          ),
          child: Text('“$body”', style: sans(12, height: 1.65, color: SR.ink4)),
        )
      else
        Text(
          body,
          textAlign: TextAlign.center,
          style: sans(12, height: 1.65, color: SR.ink4),
        ),
      if (panel != null) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: SR.surfaceSubtle,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: SR.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(panelTitle ?? '', style: sans(11.5, w: 600, color: SR.ink2)),
              const SizedBox(height: 5),
              Text(panel!, style: sans(11.5, height: 1.7, color: SR.ink4)),
            ],
          ),
        ),
      ],
      if (footnote != null) ...[
        const SizedBox(height: 10),
        Text(
          footnote!,
          textAlign: TextAlign.center,
          style: sans(11.5, height: 1.6, color: SR.muted),
        ),
      ],
      const SizedBox(height: 14),
      action,
    ],
  );
}

class _InlineLink extends StatelessWidget {
  const _InlineLink({
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: enabled ? onTap : null,
    style: TextButton.styleFrom(
      foregroundColor: SR.blue,
      minimumSize: const Size(44, 44),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: sans(11.5, w: 500),
    ),
    child: Text(label),
  );
}

class _FooterLink extends StatelessWidget {
  const _FooterLink({
    required this.prefix,
    required this.label,
    required this.onTap,
  });

  final String prefix;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 5,
    children: [
      Text(prefix, style: sans(11.5, color: SR.ink4)),
      _InlineLink(label: label, onTap: onTap),
    ],
  );
}
