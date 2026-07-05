import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';

enum AuthMode {
  signIn,
  signUp,
  forgotPassword,
  phone,
  verifyPhone,
  resetPassword,
  checkEmail,
}

class AuthPage extends StatefulWidget {
  const AuthPage({
    super.key,
    required this.authService,
    this.initialMode = AuthMode.signIn,
    this.bannerMessage,
    this.onPasswordResetComplete,
  });

  final ChatAuthService authService;
  final AuthMode initialMode;
  final String? bannerMessage;
  final VoidCallback? onPasswordResetComplete;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _displayNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmNewPasswordController = TextEditingController();

  late AuthMode _mode;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureNewPassword = true;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _phoneController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmNewPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 880;

            if (isWide) {
              return Row(
                children: [
                  const _AuthBrandPanel(),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(32),
                        child: _buildAuthCard(),
                      ),
                    ),
                  ),
                ],
              );
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              children: [
                const _CompactBrandHeader(),
                const SizedBox(height: 22),
                _buildAuthCard(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildAuthCard() {
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
          child: Form(
            key: _formKey,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _title,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _AuthNotice(
                    message: _error ?? widget.bannerMessage ?? _message,
                    isError: _error != null || widget.bannerMessage != null,
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(
                      key: ValueKey(_mode),
                      child: _buildModeFields(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeFields() {
    return switch (_mode) {
      AuthMode.signIn => _buildSignIn(),
      AuthMode.signUp => _buildSignUp(),
      AuthMode.forgotPassword => _buildForgotPassword(),
      AuthMode.phone => _buildPhone(),
      AuthMode.verifyPhone => _buildVerifyPhone(),
      AuthMode.resetPassword => _buildResetPassword(),
      AuthMode.checkEmail => _buildCheckEmail(),
    };
  }

  Widget _buildSignIn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EmailField(controller: _emailController),
        const SizedBox(height: 12),
        _PasswordField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          onToggleVisibility: _togglePasswordVisibility,
          validator: _validateRequiredPassword,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _isLoading
                ? null
                : () => _switchMode(AuthMode.forgotPassword),
            child: const Text('Forgot password?'),
          ),
        ),
        _PrimaryAuthButton(
          isLoading: _isLoading,
          label: 'Sign in',
          icon: Icons.login,
          onPressed: _submitSignIn,
        ),
        const SizedBox(height: 12),
        _GoogleButton(isLoading: _isLoading, onPressed: _submitGoogleSignIn),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _isLoading ? null : () => _switchMode(AuthMode.phone),
          icon: const Icon(Icons.phone_iphone),
          label: const Text('Use phone number'),
        ),
        const SizedBox(height: 16),
        _AuthTextAction(
          text: 'New here?',
          actionText: 'Create account',
          onPressed: _isLoading ? null : () => _switchMode(AuthMode.signUp),
        ),
      ],
    );
  }

  Widget _buildSignUp() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const Key('auth-display-name'),
          controller: _displayNameController,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.name],
          validator: _validateDisplayName,
          decoration: const InputDecoration(
            labelText: 'Display name',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 12),
        _EmailField(controller: _emailController),
        const SizedBox(height: 12),
        _PasswordField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          onToggleVisibility: _togglePasswordVisibility,
          validator: _validateNewPassword,
        ),
        const SizedBox(height: 12),
        _PasswordField(
          key: const Key('auth-confirm-password'),
          controller: _confirmPasswordController,
          labelText: 'Confirm password',
          obscureText: _obscurePassword,
          onToggleVisibility: _togglePasswordVisibility,
          validator: _validatePasswordConfirmation,
        ),
        const SizedBox(height: 16),
        _PrimaryAuthButton(
          isLoading: _isLoading,
          label: 'Create account',
          icon: Icons.person_add_alt,
          onPressed: _submitSignUp,
        ),
        const SizedBox(height: 12),
        _GoogleButton(isLoading: _isLoading, onPressed: _submitGoogleSignIn),
        const SizedBox(height: 16),
        _AuthTextAction(
          text: 'Already have an account?',
          actionText: 'Sign in',
          onPressed: _isLoading ? null : () => _switchMode(AuthMode.signIn),
        ),
      ],
    );
  }

  Widget _buildForgotPassword() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EmailField(controller: _emailController),
        const SizedBox(height: 16),
        _PrimaryAuthButton(
          isLoading: _isLoading,
          label: 'Send reset link',
          icon: Icons.mark_email_read_outlined,
          onPressed: _submitPasswordResetEmail,
        ),
        const SizedBox(height: 16),
        _AuthTextAction(
          text: 'Remembered it?',
          actionText: 'Sign in',
          onPressed: _isLoading ? null : () => _switchMode(AuthMode.signIn),
        ),
      ],
    );
  }

  Widget _buildPhone() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const Key('auth-phone'),
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.telephoneNumber],
          validator: _validatePhone,
          decoration: const InputDecoration(
            labelText: 'Phone number',
            hintText: '+15551234567',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
          onFieldSubmitted: (_) => _submitPhoneOtp(),
        ),
        const SizedBox(height: 16),
        _PrimaryAuthButton(
          isLoading: _isLoading,
          label: 'Send code',
          icon: Icons.sms_outlined,
          onPressed: _submitPhoneOtp,
        ),
        const SizedBox(height: 16),
        _AuthTextAction(
          text: 'Prefer email?',
          actionText: 'Sign in',
          onPressed: _isLoading ? null : () => _switchMode(AuthMode.signIn),
        ),
      ],
    );
  }

  Widget _buildVerifyPhone() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const Key('auth-otp'),
          controller: _otpController,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.oneTimeCode],
          validator: _validateOtp,
          decoration: const InputDecoration(
            labelText: 'Verification code',
            prefixIcon: Icon(Icons.pin_outlined),
          ),
          onFieldSubmitted: (_) => _submitPhoneVerification(),
        ),
        const SizedBox(height: 16),
        _PrimaryAuthButton(
          isLoading: _isLoading,
          label: 'Verify phone',
          icon: Icons.verified_user_outlined,
          onPressed: _submitPhoneVerification,
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _isLoading ? null : _resendPhoneOtp,
          child: const Text('Resend code'),
        ),
        _AuthTextAction(
          text: 'Wrong number?',
          actionText: 'Edit phone',
          onPressed: _isLoading ? null : () => _switchMode(AuthMode.phone),
        ),
      ],
    );
  }

  Widget _buildResetPassword() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PasswordField(
          key: const Key('auth-new-password'),
          controller: _newPasswordController,
          labelText: 'New password',
          obscureText: _obscureNewPassword,
          onToggleVisibility: _toggleNewPasswordVisibility,
          validator: _validateResetPassword,
        ),
        const SizedBox(height: 12),
        _PasswordField(
          key: const Key('auth-confirm-new-password'),
          controller: _confirmNewPasswordController,
          labelText: 'Confirm new password',
          obscureText: _obscureNewPassword,
          onToggleVisibility: _toggleNewPasswordVisibility,
          validator: _validateResetPasswordConfirmation,
        ),
        const SizedBox(height: 16),
        _PrimaryAuthButton(
          isLoading: _isLoading,
          label: 'Update password',
          icon: Icons.password,
          onPressed: _submitNewPassword,
        ),
      ],
    );
  }

  Widget _buildCheckEmail() {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.mark_email_read_outlined,
            size: 42,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => _switchMode(AuthMode.signIn),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Back to sign in'),
        ),
      ],
    );
  }

  Future<void> _submitSignIn() async {
    final response = await _runValidated(
      () => widget.authService.signInWithEmail(
        email: _emailController.text,
        password: _passwordController.text,
      ),
    );

    if (response == null || !mounted) {
      return;
    }

    _setMessage('Signed in.');
  }

  Future<void> _submitSignUp() async {
    final response = await _runValidated(
      () => widget.authService.signUpWithEmail(
        displayName: _displayNameController.text,
        email: _emailController.text,
        password: _passwordController.text,
      ),
    );

    if (response == null || !mounted) {
      return;
    }

    if (response.session == null) {
      _switchMode(
        AuthMode.checkEmail,
        message: 'Confirm your email to finish creating your account.',
      );
      return;
    }

    _setMessage('Account created.');
  }

  Future<void> _submitPasswordResetEmail() async {
    final didSend = await _runValidatedAction(
      () => widget.authService.sendPasswordReset(_emailController.text),
    );

    if (!didSend || !mounted) {
      return;
    }

    _switchMode(
      AuthMode.checkEmail,
      message: 'Use the reset link in your email to choose a new password.',
    );
  }

  Future<void> _submitPhoneOtp() async {
    final didSend = await _runValidatedAction(
      () => widget.authService.sendPhoneOtp(_phoneController.text),
    );

    if (!didSend || !mounted) {
      return;
    }

    _switchMode(
      AuthMode.verifyPhone,
      message: 'Enter the SMS code sent to ${_phoneController.text.trim()}.',
    );
  }

  Future<void> _submitPhoneVerification() async {
    await _runValidated(
      () => widget.authService.verifyPhoneOtp(
        phone: _phoneController.text,
        token: _otpController.text,
      ),
    );
  }

  Future<void> _resendPhoneOtp() async {
    if (_validatePhone(_phoneController.text) != null) {
      _switchMode(AuthMode.phone);
      return;
    }

    final didSend = await _runAction(
      () => widget.authService.sendPhoneOtp(_phoneController.text),
    );

    if (didSend && mounted) {
      _setMessage('We sent another SMS code.');
    }
  }

  Future<void> _submitGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _message = null;
    });

    try {
      final didOpen = await widget.authService.signInWithGoogle();
      if (!mounted) {
        return;
      }

      if (!didOpen) {
        _setError('Could not open Google sign in.');
      } else {
        _setMessage('Complete Google sign in to continue.');
      }
    } on AuthException catch (error) {
      if (mounted) {
        _setError(error.message);
      }
    } catch (_) {
      if (mounted) {
        _setError('Google sign in failed. Please try again.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _submitNewPassword() async {
    final result = await _runValidated(
      () => widget.authService.updatePassword(_newPasswordController.text),
    );

    if (result == null || !mounted) {
      return;
    }

    widget.onPasswordResetComplete?.call();
  }

  Future<bool> _runValidatedAction(Future<void> Function() operation) async {
    final didComplete = await _runValidated(() async {
      await operation();
      return true;
    });

    return didComplete ?? false;
  }

  Future<T?> _runValidated<T>(Future<T> Function() operation) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return null;
    }

    return _runOperation(operation);
  }

  Future<bool> _runAction(Future<void> Function() operation) async {
    final didComplete = await _runOperation(() async {
      await operation();
      return true;
    });

    return didComplete ?? false;
  }

  Future<T?> _runOperation<T>(Future<T> Function() operation) async {
    setState(() {
      _isLoading = true;
      _error = null;
      _message = null;
    });

    try {
      return await operation();
    } on AuthException catch (error) {
      if (mounted) {
        _setError(error.message);
      }
    } catch (_) {
      if (mounted) {
        _setError('Something went wrong. Please try again.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }

    return null;
  }

  void _switchMode(AuthMode mode, {String? message}) {
    _formKey.currentState?.reset();
    setState(() {
      _mode = mode;
      _error = null;
      _message = message;
    });
  }

  void _setMessage(String message) {
    setState(() {
      _error = null;
      _message = message;
    });
  }

  void _setError(String message) {
    setState(() {
      _error = message;
      _message = null;
    });
  }

  void _togglePasswordVisibility() {
    setState(() {
      _obscurePassword = !_obscurePassword;
    });
  }

  void _toggleNewPasswordVisibility() {
    setState(() {
      _obscureNewPassword = !_obscureNewPassword;
    });
  }

  String get _title {
    return switch (_mode) {
      AuthMode.signIn => 'Welcome back',
      AuthMode.signUp => 'Create your account',
      AuthMode.forgotPassword => 'Reset your password',
      AuthMode.phone => 'Continue with phone',
      AuthMode.verifyPhone => 'Enter verification code',
      AuthMode.resetPassword => 'Choose a new password',
      AuthMode.checkEmail => 'Check your email',
    };
  }

  String get _subtitle {
    return switch (_mode) {
      AuthMode.signIn => 'Sign in to open your realtime chats.',
      AuthMode.signUp => 'Use email, phone, or Google to get started.',
      AuthMode.forgotPassword => 'We will send a secure reset link.',
      AuthMode.phone => 'Use an international number to receive an SMS code.',
      AuthMode.verifyPhone => 'Finish phone verification to enter chat.',
      AuthMode.resetPassword => 'Set a password you have not used here before.',
      AuthMode.checkEmail => 'Follow the link we sent you.',
    };
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    final isValid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
    if (!isValid) {
      return 'Enter a valid email';
    }

    return null;
  }

  String? _validateDisplayName(String? value) {
    if ((value?.trim() ?? '').length < 2) {
      return 'Enter your display name';
    }

    return null;
  }

  String? _validateRequiredPassword(String? value) {
    if ((value ?? '').isEmpty) {
      return 'Password is required';
    }

    return null;
  }

  String? _validateNewPassword(String? value) {
    if ((value ?? '').length < 8) {
      return 'Use at least 8 characters';
    }

    return null;
  }

  String? _validatePasswordConfirmation(String? value) {
    if (value != _passwordController.text) {
      return 'Passwords do not match';
    }

    return null;
  }

  String? _validatePhone(String? value) {
    final phone = (value ?? '').replaceAll(RegExp(r'[\s()-]'), '');
    final isValid = RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone);
    if (!isValid) {
      return 'Use international format, like +15551234567';
    }

    return null;
  }

  String? _validateOtp(String? value) {
    final code = value?.trim() ?? '';
    if (!RegExp(r'^\d{4,8}$').hasMatch(code)) {
      return 'Enter the SMS code';
    }

    return null;
  }

  String? _validateResetPassword(String? value) => _validateNewPassword(value);

  String? _validateResetPasswordConfirmation(String? value) {
    if (value != _newPasswordController.text) {
      return 'Passwords do not match';
    }

    return null;
  }
}

class _AuthBrandPanel extends StatelessWidget {
  const _AuthBrandPanel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 360,
      color: const Color(0xFF123432),
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BrandMark(color: theme.colorScheme.primary),
          const Spacer(),
          Text(
            'Chat App',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Realtime conversations after secure sign in.',
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.78),
              height: 1.3,
            ),
          ),
          const SizedBox(height: 30),
          const _AuthPanelStat(icon: Icons.bolt, label: 'Realtime'),
          const SizedBox(height: 10),
          const _AuthPanelStat(icon: Icons.lock_outline, label: 'Protected'),
          const SizedBox(height: 10),
          const _AuthPanelStat(
            icon: Icons.groups_outlined,
            label: 'Team ready',
          ),
        ],
      ),
    );
  }
}

class _CompactBrandHeader extends StatelessWidget {
  const _CompactBrandHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        _BrandMark(color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Chat App',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.forum, color: Colors.white),
    );
  }
}

class _AuthPanelStat extends StatelessWidget {
  const _AuthPanelStat({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFFFFB06B), size: 19),
        const SizedBox(width: 10),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _AuthNotice extends StatelessWidget {
  const _AuthNotice({required this.message, required this.isError});

  final String? message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (text == null || text.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : const Color(0xFF127A74);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailField extends StatelessWidget {
  const _EmailField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_AuthPageState>();

    return TextFormField(
      key: const Key('auth-email'),
      controller: controller,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.email],
      validator: state?._validateEmail,
      decoration: const InputDecoration(
        labelText: 'Email',
        prefixIcon: Icon(Icons.alternate_email),
      ),
    );
  }
}

class _PasswordField extends StatelessWidget {
  const _PasswordField({
    super.key,
    required this.controller,
    required this.obscureText,
    required this.onToggleVisibility,
    required this.validator,
    this.labelText = 'Password',
  });

  final TextEditingController controller;
  final bool obscureText;
  final VoidCallback onToggleVisibility;
  final FormFieldValidator<String> validator;
  final String labelText;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: key ?? const Key('auth-password'),
      controller: controller,
      obscureText: obscureText,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.password],
      validator: validator,
      decoration: InputDecoration(
        labelText: labelText,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          tooltip: obscureText ? 'Show password' : 'Hide password',
          onPressed: onToggleVisibility,
          icon: Icon(obscureText ? Icons.visibility : Icons.visibility_off),
        ),
      ),
    );
  }
}

class _PrimaryAuthButton extends StatelessWidget {
  const _PrimaryAuthButton({
    required this.isLoading,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final bool isLoading;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: isLoading ? null : onPressed,
      icon: isLoading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
    );
  }
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.isLoading, required this.onPressed});

  final bool isLoading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: isLoading ? null : onPressed,
      icon: const Icon(Icons.g_mobiledata, size: 28),
      label: const Text('Continue with Google'),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
    );
  }
}

class _AuthTextAction extends StatelessWidget {
  const _AuthTextAction({
    required this.text,
    required this.actionText,
    required this.onPressed,
  });

  final String text;
  final String actionText;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        TextButton(onPressed: onPressed, child: Text(actionText)),
      ],
    );
  }
}
