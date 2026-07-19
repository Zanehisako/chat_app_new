import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_models.dart';
import 'chat_repository.dart';
import 'notification_registration.dart';
import 'notification_service.dart';
import 'motion/chat_motion_widgets.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.repository});

  final ChatRepository repository;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const _settingsChannel = MethodChannel('chat_app/settings');

  final _formKey = GlobalKey<FormState>();
  final _displayNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();

  late Future<CurrentUserProfile> _profileFuture;
  CurrentUserProfile? _profile;
  bool _didFillForm = false;
  bool _isSaving = false;
  NotificationRegistrationStatus _notificationStatus =
      const NotificationRegistrationStatus.disabled();

  @override
  void initState() {
    super.initState();
    _profileFuture = _loadProfile();
    final notifications = NotificationService.instance;
    _notificationStatus = notifications.registrationStatus.value;
    notifications.registrationStatus.addListener(_handleNotificationStatus);
    unawaited(
      notifications.refreshRegistration(client: widget.repository.client),
    );
  }

  @override
  void dispose() {
    NotificationService.instance.registrationStatus.removeListener(
      _handleNotificationStatus,
    );
    _displayNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SafeArea(
        child: FutureBuilder<CurrentUserProfile>(
          future: _profileFuture,
          builder: (context, snapshot) {
            final profile = _profile ?? snapshot.data;

            if (profile != null && !_didFillForm) {
              _fillForm(profile);
            }

            late final Widget content;
            if (snapshot.connectionState == ConnectionState.waiting &&
                profile == null) {
              content = const Center(
                key: ValueKey<String>('profile-loading'),
                child: CircularProgressIndicator(),
              );
            } else if (snapshot.hasError && profile == null) {
              content = _ProfileError(
                key: const ValueKey<String>('profile-error'),
                onRetry: _retryLoad,
              );
            } else {
              content = ChatEntrance(
                key: const ValueKey<String>('profile-form'),
                beginOffset: const Offset(0, 8),
                child: _ProfileForm(
                  formKey: _formKey,
                  profile: profile!,
                  displayNameController: _displayNameController,
                  emailController: _emailController,
                  phoneController: _phoneController,
                  isSaving: _isSaving,
                  notificationStatus: _notificationStatus,
                  notificationsAvailable: widget.repository.client != null,
                  onNotificationsChanged: _setNotificationsEnabled,
                  onSave: _saveProfile,
                ),
              );
            }

            return ChatStateSwitcher(child: content);
          },
        ),
      ),
    );
  }

  Future<CurrentUserProfile> _loadProfile() async {
    final profile = await widget.repository.currentProfile();
    if (mounted) {
      _profile = profile;
    }
    return profile;
  }

  void _fillForm(CurrentUserProfile profile) {
    _displayNameController.text = profile.displayName;
    _emailController.text = profile.email ?? '';
    _phoneController.text = profile.phone ?? '';
    _didFillForm = true;
  }

  void _retryLoad() {
    setState(() {
      _didFillForm = false;
      _profile = null;
      _profileFuture = _loadProfile();
    });
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate() || _isSaving) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isSaving = true;
    });

    try {
      final profile = await widget.repository.updateCurrentProfile(
        displayName: _displayNameController.text,
        email: _emailController.text,
        phone: _phoneController.text,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _profile = profile;
        _profileFuture = Future.value(profile);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update profile.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _handleNotificationStatus() {
    if (!mounted) return;
    setState(() {
      _notificationStatus =
          NotificationService.instance.registrationStatus.value;
    });
  }

  Future<void> _setNotificationsEnabled(bool enabled) async {
    final client = widget.repository.client;
    if (client == null || _notificationStatus.isBusy) return;
    if (enabled &&
        _notificationStatus.state == NotificationRegistrationState.denied) {
      await _openNotificationSettings();
      return;
    }
    if (enabled) {
      await NotificationService.instance.enableNotifications(client: client);
    } else {
      await NotificationService.instance.disableNotifications(client: client);
    }
    if (!mounted) return;
    final status = NotificationService.instance.registrationStatus.value;
    final message = status.message;
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          action:
              status.state == NotificationRegistrationState.denied && !kIsWeb
              ? SnackBarAction(
                  label: 'Settings',
                  onPressed: () => unawaited(_openNotificationSettings()),
                )
              : null,
        ),
      );
    }
  }

  Future<void> _openNotificationSettings() async {
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Allow notifications for this site in browser settings.',
          ),
        ),
      );
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Open this app in system notification settings.'),
        ),
      );
      return;
    }
    try {
      await _settingsChannel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open notification settings.')),
      );
    }
  }
}

class _ProfileForm extends StatelessWidget {
  const _ProfileForm({
    required this.formKey,
    required this.profile,
    required this.displayNameController,
    required this.emailController,
    required this.phoneController,
    required this.isSaving,
    required this.notificationStatus,
    required this.notificationsAvailable,
    required this.onNotificationsChanged,
    required this.onSave,
  });

  final GlobalKey<FormState> formKey;
  final CurrentUserProfile profile;
  final TextEditingController displayNameController;
  final TextEditingController emailController;
  final TextEditingController phoneController;
  final bool isSaving;
  final NotificationRegistrationStatus notificationStatus;
  final bool notificationsAvailable;
  final ValueChanged<bool> onNotificationsChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      key: const Key('profile-page'),
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _ProfileAvatar(profile: profile),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            profile.id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                TextFormField(
                  key: const Key('profile-display-name'),
                  controller: displayNameController,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Display name is required';
                    }
                    return null;
                  },
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('profile-email'),
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  validator: (value) {
                    final email = value?.trim();
                    if (email == null || email.isEmpty) {
                      return null;
                    }
                    if (!RegExp(
                      r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                    ).hasMatch(email)) {
                      return 'Enter a valid email';
                    }
                    return null;
                  },
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.mail_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('profile-phone'),
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  decoration: const InputDecoration(
                    labelText: 'Phone',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  onFieldSubmitted: (_) => onSave(),
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  key: const Key('profile-notifications-toggle'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('Notifications'),
                  subtitle: ChatStateSwitcher(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _notificationStatusLabel(notificationStatus),
                      key: ValueKey<NotificationRegistrationState>(
                        notificationStatus.state,
                      ),
                    ),
                  ),
                  value: notificationStatus.isEnabled,
                  onChanged:
                      !notificationsAvailable ||
                          notificationStatus.isBusy ||
                          notificationStatus.state ==
                              NotificationRegistrationState.unsupported
                      ? null
                      : onNotificationsChanged,
                ),
                const SizedBox(height: 22),
                ChatPressScale(
                  enabled: !isSaving,
                  child: FilledButton.icon(
                    key: const Key('profile-save'),
                    onPressed: isSaving ? null : onSave,
                    icon: ChatStateSwitcher(
                      child: isSaving
                          ? const SizedBox(
                              key: ValueKey<String>('profile-saving'),
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.save_outlined,
                              key: ValueKey<String>('profile-save-icon'),
                            ),
                    ),
                    label: ChatStateSwitcher(
                      child: Text(
                        isSaving ? 'Saving' : 'Save changes',
                        key: ValueKey<bool>(isSaving),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _notificationStatusLabel(NotificationRegistrationStatus status) {
  return switch (status.state) {
    NotificationRegistrationState.disabled => 'Off',
    NotificationRegistrationState.enabling => 'Enabling...',
    NotificationRegistrationState.enabled => 'On',
    NotificationRegistrationState.denied => 'Blocked in device settings',
    NotificationRegistrationState.unsupported => 'Unavailable on this device',
    NotificationRegistrationState.failed => 'Registration failed',
  };
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.profile});

  final CurrentUserProfile profile;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: 72,
      height: 72,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        profile.avatarLabel,
        style: TextStyle(
          color: colorScheme.onPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ProfileError extends StatelessWidget {
  const _ProfileError({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 36),
            const SizedBox(height: 10),
            Text(
              'Could not load profile.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
