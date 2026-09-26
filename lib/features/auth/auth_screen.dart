import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../model/verification.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_logo.dart';
import '../../widgets/sr_scroll_view.dart';
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
          final pad = EdgeInsets.fromLTRB(
            desktop
                ? SR.space48
                : tablet
                ? SR.space32
                : SR.space20,
            desktop ? SR.space40 : SR.space24,
            desktop
                ? SR.space48
                : tablet
                ? SR.space32
                : SR.space20,
            SR.space24 + MediaQuery.viewInsetsOf(context).bottom,
          );
          final content = SafeArea(
            child: LayoutBuilder(
              builder: (context, box) => SrScrollView(
                padding: pad,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (box.maxHeight - pad.vertical).clamp(
                      0.0,
                      double.infinity,
                    ),
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
                          if (_progressLabels.isNotEmpty) _progress(context),
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
                          if (!desktop) ...[
                            const SizedBox(height: 18),
                            Text(
                              'Office of the Registrar · Cagayan State University, Aparri Campus',
                              textAlign: TextAlign.center,
                              style: sans(
                                11.5,
                                height: 1.5,
                                color: context.srColors.ink4,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final shell = ColoredBox(
            color: width < SR.tabletMin
                ? context.srColors.surface
                : context.srColors.bg,
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
          if (!desktop) return shell;
          return Stack(
            children: [
              Positioned.fill(child: shell),
              Positioned(
                right: SR.space24,
                top: SR.space20,
                child: SafeArea(
                  child: SrThemeSelector(
                    value: state.themePreference,
                    compact: true,
                    onChanged: state.setThemePreference,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _topBar() => LayoutBuilder(
    builder: (context, constraints) => Row(
      children: [
        Expanded(child: _BrandHeader(compact: constraints.maxWidth < 400)),
        const SizedBox(width: SR.space8),
        SrThemeSelector(
          value: state.themePreference,
          compact: true,
          onChanged: state.setThemePreference,
        ),
      ],
    ),
  );

  List<String> get _progressLabels => switch (controller.step) {
    AuthStep.question ||
    AuthStep.details ||
    AuthStep.pending => const ['1 Account', '2 Campus status'],
    _ => const [],
  };

  int get _progressIndex => switch (controller.step) {
    AuthStep.question || AuthStep.details || AuthStep.pending => 1,
    _ => 2,
  };

  Widget _progress(BuildContext context) => Padding(
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
                    color: i <= _progressIndex
                        ? SR.primary
                        : context.srColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _progressLabels[i],
                  style: mono(
                    9,
                    w: 500,
                    tracking: .03,
                    color: context.srColors.muted,
                  ),
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
      AuthStep.signIn => _signIn(context),
      AuthStep.passwordResetRequest => _passwordResetRequest(context),
      AuthStep.passwordResetSent => _passwordResetSent(context),
      AuthStep.passwordReset => _passwordReset(context),
      AuthStep.createAccount => _createAccount(context),
      AuthStep.initialPassword => _initialPassword(context),
      AuthStep.accessRequired => _accessRequired(context),
      AuthStep.question => _question(context),
      AuthStep.details => _details(context),
      AuthStep.pending => _pending(context),
      AuthStep.guest => _guest(context),
      AuthStep.member => _member(),
    },
  );

  Widget _signIn(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Sign in to SmartReserve'),
      _Lede(
        'Sign in to manage your reservations and payments. Campus organization accounts are issued by an Internal Admin.',
      ),

      const SizedBox(height: 22),

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

      const SizedBox(height: 10),

      const SrLabel('Password'),
      _PasswordField(
        controller: controller,
        placeholder: 'Enter your password',
        onSubmitted: (_) => controller.busy ? null : controller.submitSignIn(),
      ),

      const SizedBox(height: 8),

      Align(
        alignment: Alignment.centerLeft,
        child: _InlineLink(
          label: 'Forgot password?',
          onTap: () => controller.goTo(AuthStep.passwordResetRequest),
        ),
      ),

      const SizedBox(height: 12),

      _submitButton(context, 'Sign in', 'Signing in…', controller.submitSignIn),

      SrErrorText(controller.operationError),
      if (controller.operationNotice case final notice?) ...[
        const SizedBox(height: 10),
        _Notice(message: notice),
      ],

      const SizedBox(height: 8),

      Text.rich(
        TextSpan(
          text: 'Renting a facility or paying for a reservation? ',
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _InlineLink(
                label: 'Create an account',
                onTap: () => controller.goTo(AuthStep.createAccount),
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        style: sans(11.5, height: 1.6, color: context.srColors.ink4),
      ),
    ],
  );

  Widget _passwordResetRequest(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Reset your password'),
      _Lede(
        'Enter the email address for your SmartReserve account and we’ll send a six-digit reset code.',
      ),
      const SizedBox(height: 22),
      const SrLabel('Email address'),
      SrTextField(
        controller: controller.emailField,
        placeholder: 'name@example.com',
        semanticLabel: 'Email address',
        keyboardType: TextInputType.emailAddress,
        hasError: controller.emailError != null,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.username, AutofillHints.email],
        autocorrect: false,
        onSubmitted: (_) =>
            controller.busy ? null : controller.requestPasswordReset(),
      ),
      SrErrorText(controller.emailError),
      const SizedBox(height: 14),
      _submitButton(
        context,
        'Send code',
        'Sending code…',
        controller.requestPasswordReset,
      ),
      SrErrorText(controller.operationError),
      const SizedBox(height: 8),
      Text.rich(
        TextSpan(
          text: 'Remembered your password? ',
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _InlineLink(
                label: 'Sign in',
                onTap: () => controller.goTo(AuthStep.signIn),
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        style: sans(11.5, height: 1.6, color: context.srColors.ink4),
      ),
    ],
  );

  Widget _passwordResetSent(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Check your email'),
      _Lede(
        'If an account matches that address, we’ve sent a six-digit reset code. Check your inbox and spam folder.',
      ),
      const SizedBox(height: 22),
      const SrLabel('Six-digit code'),
      _RecoveryCodeInput(
        value: controller.resetCodeField.text,
        onChanged: controller.setResetCode,
        hasError: controller.resetCodeError != null,
        enabled: !controller.busy,
        onSubmitted: controller.verifyPasswordResetCode,
      ),
      SrErrorText(controller.resetCodeError),
      const SizedBox(height: 14),
      _submitButton(
        context,
        'Verify code',
        'Verifying code…',
        controller.verifyPasswordResetCode,
      ),
      SrErrorText(controller.operationError),
      const SizedBox(height: 8),
      Text.rich(
        TextSpan(
          text: 'Didn’t receive a code? ',
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _InlineLink(
                label: 'Request another code',
                onTap: () => controller.goTo(AuthStep.passwordResetRequest),
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        style: sans(11.5, height: 1.6, color: context.srColors.ink4),
      ),
      _InlineLink(
        label: 'Back to sign in',
        onTap: () => controller.goTo(AuthStep.signIn),
      ),
    ],
  );

  Widget _passwordReset(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Choose a new password'),
      _Lede('Create a new password for your SmartReserve account.'),
      const SizedBox(height: 22),
      const SrLabel('New password'),
      _PasswordField(
        controller: controller,
        newPassword: true,
        placeholder: 'Create a secure password',
      ),
      const SizedBox(height: 8),
      _PasswordRequirements(requirements: controller.passwordRequirements),
      SrErrorText(controller.passwordError),
      const SizedBox(height: 10),
      const SrLabel('Confirm new password'),
      _PasswordField(
        controller: controller,
        fieldController: controller.confirmPasswordField,
        placeholder: 'Enter the same password again',
        semanticLabel: 'Confirm new password',
        hasError: controller.confirmPasswordError != null,
        newPassword: true,
        onSubmitted: (_) =>
            controller.busy ? null : controller.submitPasswordReset(),
      ),
      SrErrorText(controller.confirmPasswordError),
      const SizedBox(height: 14),
      _submitButton(
        context,
        'Save new password',
        'Saving password…',
        controller.submitPasswordReset,
      ),
      SrErrorText(controller.operationError),
    ],
  );

  Widget _createAccount(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Create your renter account'),
      _Lede(
        'For outside renters and paying customers. You can browse available facilities, submit reservations, and manage payments here.',
      ),

      const SizedBox(height: 22),

      const SrLabel('Full name'),
      SrTextField(
        controller: controller.fullNameField,
        placeholder: 'Your full name',
        semanticLabel: 'Full name',
        hasError: controller.fullNameError != null,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.name],
      ),
      SrErrorText(controller.fullNameError),

      const SizedBox(height: 10),

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

      const SizedBox(height: 10),

      const SrLabel('Password'),
      _PasswordField(
        controller: controller,
        newPassword: true,
        placeholder: 'Create a secure password',
      ),
      const SizedBox(height: 8),
      _PasswordRequirements(requirements: controller.passwordRequirements),
      SrErrorText(controller.passwordError),

      const SizedBox(height: 10),

      const SrLabel('Confirm password'),
      _PasswordField(
        controller: controller,
        fieldController: controller.confirmPasswordField,
        placeholder: 'Enter the same password again',
        semanticLabel: 'Confirm password',
        hasError: controller.confirmPasswordError != null,
        newPassword: true,
        onSubmitted: (_) =>
            controller.busy ? null : controller.createExternalGuestAccount(),
      ),
      SrErrorText(controller.confirmPasswordError),

      const SizedBox(height: 14),

      _submitButton(
        context,
        'Create renter account',
        'Creating account…',
        controller.createExternalGuestAccount,
      ),
      SrErrorText(controller.operationError),

      const SizedBox(height: 8),

      Text.rich(
        TextSpan(
          text: 'Already have an account? ',
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _InlineLink(
                label: 'Sign in',
                onTap: () => controller.goTo(AuthStep.signIn),
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        style: sans(11.5, height: 1.6, color: context.srColors.ink4),
      ),
    ],
  );

  Widget _initialPassword(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Set your account password'),
      _Lede(
        'Your Internal Admin issued temporary credentials. Create a private password before continuing.',
      ),
      const SizedBox(height: 16),
      const SrLabel('New password'),
      _PasswordField(
        controller: controller,
        newPassword: true,
        placeholder: 'Create a private password',
      ),
      const SizedBox(height: 8),
      _PasswordRequirements(requirements: controller.passwordRequirements),
      SrErrorText(controller.passwordError),
      const SizedBox(height: 10),
      const SrLabel('Confirm new password'),
      _PasswordField(
        controller: controller,
        fieldController: controller.confirmPasswordField,
        placeholder: 'Enter the new password again',
        semanticLabel: 'Confirm new password',
        hasError: controller.confirmPasswordError != null,
        onSubmitted: (_) =>
            controller.busy ? null : controller.submitInitialPassword(),
      ),
      SrErrorText(controller.confirmPasswordError),
      const SizedBox(height: 14),
      _submitButton(
        context,
        'Save password and continue',
        'Saving password…',
        controller.submitInitialPassword,
      ),
      SrErrorText(controller.operationError),
    ],
  );

  Widget _accessRequired(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('Organization assignment required'),
      _Lede(
        'This account can sign in, but it cannot reserve facilities until an Internal Admin assigns it to an authorized organization account or converts it to an external renter account.',
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: context.srColors.amberTint,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.srColors.amberLine),
        ),
        child: Text(
          'Campus students, faculty, and university staff now book through one named representative per organization or office.',
          style: sans(11.5, height: 1.6, color: context.srColors.amberTitle),
        ),
      ),
      const SizedBox(height: 14),
      SrButton(
        label: 'Sign out',
        expand: true,
        minHeight: 44,
        fontSize: 13,
        onPressed: controller.busy ? null : state.signOut,
      ),
    ],
  );

  Widget _question(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Title('How are you connected to CSU Aparri?'),
      _Lede(
        'Renter accounts can continue here. Campus reservations are now handled '
        'through one authorized representative account per organization or '
        'office; contact your Internal Admin for access.',
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
        context,
        'Continue',
        'Saving selection…',
        controller.continueFromQuestion,
      ),
    ],
  );

  Widget _details(BuildContext context) => Column(
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
        background: context.srColors.surfaceSubtle,
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Text(
              controller.claim.documentLabel,
              textAlign: TextAlign.center,
              style: sans(12, w: 500, color: context.srColors.ink2),
            ),
            const SizedBox(height: 3),
            Text(
              'JPG, PNG, or PDF · up to 10 MB · make sure your name and ID are readable',
              textAlign: TextAlign.center,
              style: sans(10.5, color: context.srColors.muted),
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
                  color: context.srColors.primaryTint,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        '$name · ${controller.documentSizeLabel}',
                        overflow: TextOverflow.ellipsis,
                        style: mono(11, color: SR.primaryHover),
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
                            color: hovered
                                ? SR.primaryHover
                                : context.srColors.primaryDeep,
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
        context,
        'Submit for verification',
        'Uploading document…',
        controller.submitVerification,
      ),
      SrErrorText(controller.operationError),
    ],
  );

  Widget _pending(BuildContext context) {
    final submission = controller.submission;
    final decision = submission?.decision ?? VerificationDecision.pending;

    return switch (decision) {
      VerificationDecision.approved => _Outcome(
        glyph: Icons.check_rounded,
        background: context.srColors.greenTint,
        foreground: context.srColors.greenDark,
        title: 'You are verified',
        body:
            'Your campus status is confirmed. New reservations use the '
            'internal-admin lane and the facility’s campus-member rate.',
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
        background: context.srColors.amberTint,
        foreground: context.srColors.amber,
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
        background: context.srColors.redTint,
        foreground: context.srColors.red,
        title: 'Verification was not approved',
        body: submission?.reason ?? '',
        quoteBody: true,
        footnote:
            'You may appeal once with a different document. Your account still '
            'works — new reservations use the external/unverified lane and the '
            'facility’s renter rate in the meantime.',
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
              label: 'Continue as a paying renter',
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
        background: context.srColors.amberTint,
        foreground: context.srColors.amber,
        title: 'Waiting for the registrar',
        body:
            'Campus documents are reviewed each morning — usually within one '
            'business day. Return here to see the decision.',
        panel:
            'Browse facilities, view them on the campus map, and prepare a '
            'reservation. A request submitted before verification stays in '
            'the external-admin lane; requests submitted after approval use '
            'the internal-admin lane.',
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

  Widget _guest(BuildContext context) => Column(
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
          color: context.srColors.primaryTint2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.srColors.primaryLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How payment works',
              style: sans(11.5, w: 600, color: SR.primaryHover),
            ),
            const SizedBox(height: 4),
            Text(
              'You see the facility’s renter rate before you request. After an '
              'assigned administrator approves it, pay by GCash or in cash at '
              'the campus cashier, then upload the reference number and proof '
              'before the displayed deadline. The slot is confirmed only after '
              'that payment is verified.',
              style: sans(
                11.5,
                height: 1.7,
                color: context.srColors.primaryDeep,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Text.rich(
        TextSpan(
          text: 'Campus members use the facility’s published campus rate. ',
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
        style: sans(11.5, height: 1.6, color: context.srColors.ink4),
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

  Widget _submitButton(
    BuildContext context,
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
        ? SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.srColors.muted,
            ),
          )
        : null,
    onPressed: controller.busy ? null : action,
  );
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SrLogo(size: 40, radius: SR.rMd),
      if (!compact) ...[
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SmartReserve', style: sans(15, w: 600, tracking: -.01)),
            Text(
              'CSU APARRI',
              style: mono(
                10,
                w: 500,
                tracking: .04,
                color: context.srColors.ink4,
              ),
            ),
          ],
        ),
      ],
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
      color: context.srColors.navBg,
      borderRadius: BorderRadius.circular(18),
      gradient: LinearGradient(
        colors: [context.srColors.heroStart, context.srColors.heroEnd],
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
                    style: mono(
                      10,
                      w: 500,
                      tracking: .06,
                      color: context.srColors.primarySoft,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Every campus space, easier to find and reserve.',
                    style: sans(
                      22,
                      w: 600,
                      height: 1.25,
                      color: context.srColors.surface,
                    ),
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
              color: SR.primaryBright,
            ),
          ),
          Positioned(
            right: 42,
            bottom: 3,
            child: Icon(Icons.apartment_rounded, size: 82, color: SR.onDarkDim),
          ),
          Positioned(
            right: 4,
            bottom: 0,
            child: Container(width: 122, height: 1, color: SR.onDarkDim),
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
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [context.srColors.heroStart, context.srColors.heroEnd],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, box) {
          final short = SR.isShort(box.maxHeight);
          final pad = EdgeInsets.symmetric(
            horizontal: box.maxWidth >= 560 ? SR.space48 : SR.space32,
            vertical: short ? SR.space24 : SR.space40,
          );
          return SrScrollView(
            padding: pad,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (box.maxHeight - pad.vertical).clamp(
                  0.0,
                  double.infinity,
                ),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: SR.contentWide),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _wordmark(),
                    _headline(short),
                    SizedBox(height: short ? SR.space16 : SR.space32),
                    _pillarsAndFootnote(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _wordmark() => Row(
    children: [
      const SrLogo(size: 32, radius: SR.rSm),
      const SizedBox(width: SR.space12),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SmartReserve',
            style: sans(15, w: 600, tracking: -.01, color: SR.onDark),
          ),
          Text(
            'CAGAYAN STATE UNIVERSITY — APARRI',
            style: mono(10, color: SR.onDarkFaint),
          ),
        ],
      ),
    ],
  );

  Widget _headline(bool short) => Padding(
    padding: EdgeInsets.symmetric(vertical: short ? SR.space16 : SR.space32),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reserve any room on campus, and know exactly where it is.',
            style: sans(
              short ? 24 : 30,
              w: 600,
              height: 1.18,
              tracking: -.03,
              color: SR.onDark,
            ),
          ),
          const SizedBox(height: SR.space12),
          Text(
            'Forty-six facilities across the Aparri campus, each pinned to '
            'its real coordinates.',
            style: sans(13, height: 1.7, color: SR.onDarkMuted),
          ),
        ],
      ),
    ),
  );

  Widget _pillarsAndFootnote() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (number, title, body) in _pillars) ...[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: SR.space16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  number,
                  style: mono(10, w: 500, color: SR.primaryBright),
                ),
              ),
              const SizedBox(width: SR.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: sans(12.5, w: 600, color: SR.onDark)),
                    const SizedBox(height: SR.space2),
                    Text(
                      body,
                      style: sans(11.5, height: 1.6, color: SR.onDarkFaint),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (number != _pillars.last.$1)
          const DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: SR.onDarkLine)),
            ),
            child: SizedBox(width: double.infinity),
          ),
      ],
      const SizedBox(height: SR.space24),
      const DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: SR.onDarkLine)),
        ),
        child: Padding(
          padding: EdgeInsets.only(top: SR.space16),
          child: Text(
            'Office of the Registrar · Cagayan State University, '
            'Aparri Campus',
            style: TextStyle(
              fontFamily: 'IBM Plex Mono',
              fontSize: 10,
              color: SR.onDarkDim,
            ),
          ),
        ),
      ),
    ],
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.framed = true});

  final Widget child;
  final bool framed;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(framed ? SR.space24 : 0),
    decoration: BoxDecoration(
      color: context.srColors.surface,
      borderRadius: SR.radius(SR.rMd),
      border: framed ? Border.all(color: context.srColors.border) : null,
      boxShadow: framed ? SR.cardShadow : null,
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
    child: Text(
      text,
      style: sans(12, height: 1.6, color: context.srColors.ink4),
    ),
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
              color: context.srColors.ink4,
            ),
            onPressed: () => setState(() => hidden = !hidden),
          ),
        ),
      ),
    );
  }
}

class _PasswordRequirements extends StatelessWidget {
  const _PasswordRequirements({required this.requirements});

  final List<PasswordRequirement> requirements;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 6,
    children: [
      for (final requirement in requirements)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              requirement.met
                  ? Icons.check_circle_rounded
                  : Icons.circle_outlined,
              size: 13,
              color: requirement.met ? SR.green : context.srColors.muted,
            ),
            const SizedBox(width: 5),
            Text(
              requirement.label,
              style: sans(
                11,
                color: requirement.met ? SR.green : context.srColors.muted,
              ),
            ),
          ],
        ),
    ],
  );
}

class _RecoveryCodeInput extends StatefulWidget {
  const _RecoveryCodeInput({
    required this.value,
    required this.onChanged,
    required this.hasError,
    required this.enabled,
    required this.onSubmitted,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool hasError;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  State<_RecoveryCodeInput> createState() => _RecoveryCodeInputState();
}

class _RecoveryCodeInputState extends State<_RecoveryCodeInput> {
  static const _length = 6;
  late final List<TextEditingController> _cells;
  late final List<FocusNode> _focusNodes;
  bool _synchronizing = false;

  @override
  void initState() {
    super.initState();
    _cells = List.generate(_length, (_) => TextEditingController());
    _focusNodes = List.generate(_length, (_) => FocusNode());
    for (final node in _focusNodes) {
      node.addListener(_handleFocusChange);
    }
    _setCells(widget.value);
  }

  @override
  void didUpdateWidget(covariant _RecoveryCodeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _value) _setCells(widget.value);
  }

  @override
  void dispose() {
    for (final controller in _cells) {
      controller.dispose();
    }
    for (final node in _focusNodes) {
      node
        ..removeListener(_handleFocusChange)
        ..dispose();
    }
    super.dispose();
  }

  String get _value => _cells.map((cell) => cell.text).join();

  void _handleFocusChange() => mounted ? setState(() {}) : null;

  void _setCells(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    _synchronizing = true;
    for (var index = 0; index < _length; index++) {
      final text = index < digits.length ? digits[index] : '';
      _cells[index].value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    _synchronizing = false;
  }

  void _emit() => widget.onChanged(_value);

  void _handleChanged(int index, String value) {
    if (_synchronizing) return;
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      _emit();
      if (index > 0) _focusNodes[index - 1].requestFocus();
      return;
    }
    if (digits.length > 1) {
      _synchronizing = true;
      for (var cell = index; cell < _length; cell++) {
        final digitIndex = cell - index;
        final text = digitIndex < digits.length ? digits[digitIndex] : '';
        _cells[cell].value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
      _synchronizing = false;
      _emit();
      final next = (index + digits.length).clamp(0, _length - 1).toInt();
      _focusNodes[next].requestFocus();
      return;
    }
    _cells[index].value = TextEditingValue(
      text: digits,
      selection: TextSelection.collapsed(offset: digits.length),
    );
    _emit();
    if (index < _length - 1) _focusNodes[index + 1].requestFocus();
  }

  KeyEventResult _handleKeyEvent(int index, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.backspace ||
        index == 0 ||
        _cells[index].text.isNotEmpty) {
      return KeyEventResult.ignored;
    }
    _cells[index - 1].clear();
    _focusNodes[index - 1].requestFocus();
    _emit();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final spacing = constraints.maxWidth < 350 ? 6.0 : 9.0;
      final width = ((constraints.maxWidth - spacing * (_length - 1)) / _length)
          .clamp(38.0, 52.0)
          .toDouble();
      return Semantics(
        label: 'Six-digit reset code',
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var index = 0; index < _length; index++) ...[
              if (index > 0) SizedBox(width: spacing),
              SizedBox(
                width: width,
                height: 54,
                child: Focus(
                  onKeyEvent: (node, event) => _handleKeyEvent(index, event),
                  child: AnimatedContainer(
                    duration: SR.stateChange,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.srColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: widget.hasError
                            ? context.srColors.error
                            : _focusNodes[index].hasFocus
                            ? SR.primary
                            : context.srColors.borderField,
                        width: _focusNodes[index].hasFocus ? 1.5 : 1,
                      ),
                    ),
                    child: TextField(
                      controller: _cells[index],
                      focusNode: _focusNodes[index],
                      enabled: widget.enabled,
                      keyboardType: TextInputType.number,
                      textInputAction: index == _length - 1
                          ? TextInputAction.done
                          : TextInputAction.next,
                      textAlign: TextAlign.center,
                      style: mono(21, w: 700, tracking: .04),
                      maxLines: 1,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: index == 0
                          ? const [AutofillHints.oneTimeCode]
                          : null,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        filled: true,
                        fillColor: Colors.transparent,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: (value) => _handleChanged(index, value),
                      onSubmitted: (_) {
                        if (index == _length - 1) {
                          widget.onSubmitted();
                        } else {
                          _focusNodes[index + 1].requestFocus();
                        }
                      },
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: context.srColors.successContainer,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: context.srColors.success.withValues(alpha: .3)),
    ),
    child: Row(
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 16,
          color: context.srColors.success,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: sans(11.5, height: 1.5, color: context.srColors.ink3),
          ),
        ),
      ],
    ),
  );
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
                color: selected
                    ? context.srColors.primaryTint
                    : context.srColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected
                      ? SR.primary
                      : (hovered
                            ? context.srColors.primarySoft
                            : context.srColors.border),
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
                        color: selected
                            ? SR.primary
                            : context.srColors.borderField,
                      ),
                    ),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: selected ? SR.primary : Colors.transparent,
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
                          style: sans(
                            11,
                            height: 1.5,
                            color: context.srColors.ink4,
                          ),
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
          child: Text(
            '“$body”',
            style: sans(12, height: 1.65, color: context.srColors.ink4),
          ),
        )
      else
        Text(
          body,
          textAlign: TextAlign.center,
          style: sans(12, height: 1.65, color: context.srColors.ink4),
        ),
      if (panel != null) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: context.srColors.surfaceSubtle,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: context.srColors.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                panelTitle ?? '',
                style: sans(11.5, w: 600, color: context.srColors.ink2),
              ),
              const SizedBox(height: 5),
              Text(
                panel!,
                style: sans(11.5, height: 1.7, color: context.srColors.ink4),
              ),
            ],
          ),
        ),
      ],
      if (footnote != null) ...[
        const SizedBox(height: 10),
        Text(
          footnote!,
          textAlign: TextAlign.center,
          style: sans(11.5, height: 1.6, color: context.srColors.muted),
        ),
      ],
      const SizedBox(height: 14),
      action,
    ],
  );
}

class _InlineLink extends StatelessWidget {
  const _InlineLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      foregroundColor: SR.primary,
      minimumSize: const Size(44, 44),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: sans(11.5, w: 500),
    ),
    child: Text(label),
  );
}
