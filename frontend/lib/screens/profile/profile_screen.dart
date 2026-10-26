import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../core/constants/app_constants.dart';
import '../../widgets/common/common_widgets.dart';
import '../../services/app_updater.dart';
import '../../widgets/update/update_dialog.dart';
import '../../widgets/common/app_bottom_nav_bar.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final ApiService _api = ApiService();
  bool _testingServer = false;
  Map<String, dynamic>? _serverStatus;
  String? _statusError;

  // User preferences with default values
  bool _antiSpamJitter = true;
  bool _commentAlerts = true;
  bool _dmDeliveryAlerts = true;
  bool _autoRefresh = true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AuthProvider>().refreshUser();
      }
    });
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _antiSpamJitter   = prefs.getBool('pref_anti_spam') ?? true;
          _commentAlerts    = prefs.getBool('pref_comment_alerts') ?? true;
          _dmDeliveryAlerts = prefs.getBool('pref_dm_alerts') ?? true;
          _autoRefresh      = prefs.getBool('pref_auto_refresh') ?? true;
        });
      }
    } catch (_) {}
  }

  Future<void> _savePreference(String key, bool val) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, val);
    } catch (_) {}
  }

  Future<void> _checkServer({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      setState(() {
        _testingServer = true;
        _statusError = null;
      });
    }

    try {
      final res = await _api.dio
          .get('/status')
          .timeout(
            const Duration(seconds: 4),
            onTimeout: () => throw Exception('Server request timed out'),
          );
      if (mounted) {
        final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : null;
        setState(() => _serverStatus = data);
      }
    } catch (e) {
      if (mounted && !silent) {
        setState(() => _statusError = 'Status check offline: ${e.toString().replaceAll('Exception: ', '')}');
      }
    } finally {
      if (mounted && !silent) {
        setState(() => _testingServer = false);
      }
    }
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return 'N/A';
    try {
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      final monthIdx = (dt.month >= 1 && dt.month <= 12) ? dt.month - 1 : 0;
      return '${months[monthIdx]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return 'Connected';
    }
  }

  String _formatExpiry(DateTime? dt) {
    if (dt == null) return 'Token Active';
    try {
      final days = dt.difference(DateTime.now()).inDays;
      if (days < 0) return 'Token Expired';
      if (days == 0) return 'Expires today';
      return 'Expires in $days days';
    } catch (_) {
      return 'Token Active';
    }
  }

  // ── Change Password Modal ───────────────────────────────────────────────────
  void _showChangePasswordModal() {
    final formKey = GlobalKey<FormState>();
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;
    bool isSubmitting = false;
    String? localError;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Container(
          padding: EdgeInsets.fromLTRB(20, 24, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.lock_reset, color: AppColors.primary, size: 20),
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Change Password',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Update your account password. Use at least 6 characters.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),

                  if (localError != null)
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: AppColors.error.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: AppColors.error, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text(localError!, style: const TextStyle(fontSize: 12, color: AppColors.error))),
                        ],
                      ),
                    ),

                  // Current Password
                  TextFormField(
                    controller: currentCtrl,
                    obscureText: obscureCurrent,
                    decoration: InputDecoration(
                      labelText: 'Current Password',
                      prefixIcon: const Icon(Icons.lock_outline, size: 18),
                      suffixIcon: IconButton(
                        icon: Icon(obscureCurrent ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                        onPressed: () => setModalState(() => obscureCurrent = !obscureCurrent),
                      ),
                    ),
                    validator: (v) => (v == null || v.isEmpty) ? 'Please enter your current password' : null,
                  ),
                  const SizedBox(height: 14),

                  // New Password
                  TextFormField(
                    controller: newCtrl,
                    obscureText: obscureNew,
                    decoration: InputDecoration(
                      labelText: 'New Password',
                      prefixIcon: const Icon(Icons.vpn_key_outlined, size: 18),
                      suffixIcon: IconButton(
                        icon: Icon(obscureNew ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                        onPressed: () => setModalState(() => obscureNew = !obscureNew),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Please enter a new password';
                      if (v.length < 6) return 'Password must be at least 6 characters';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),

                  // Confirm Password
                  TextFormField(
                    controller: confirmCtrl,
                    obscureText: obscureConfirm,
                    decoration: InputDecoration(
                      labelText: 'Confirm New Password',
                      prefixIcon: const Icon(Icons.check_circle_outline, size: 18),
                      suffixIcon: IconButton(
                        icon: Icon(obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                        onPressed: () => setModalState(() => obscureConfirm = !obscureConfirm),
                      ),
                    ),
                    validator: (v) {
                      if (v != newCtrl.text) return 'Passwords do not match';
                      return null;
                    },
                  ),

                  const SizedBox(height: 12),
                  // Suggestion tip
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.panelGray,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.lightbulb_outline, size: 16, color: AppColors.textSecondary),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Suggestion: Use a mix of letters, numbers, and symbols for high security.',
                            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Submit Button
                  GradientButton(
                    label: isSubmitting ? 'Updating Password...' : 'Save New Password',
                    icon: Icons.check,
                    loading: isSubmitting,
                    onPressed: isSubmitting ? null : () async {
                      if (!formKey.currentState!.validate()) return;
                      setModalState(() {
                        isSubmitting = true;
                        localError = null;
                      });

                      final auth = context.read<AuthProvider>();
                      final navigator = Navigator.of(ctx);
                      final messenger = ScaffoldMessenger.of(context);

                      final success = await auth.changePassword(
                        currentCtrl.text.trim(),
                        newCtrl.text.trim(),
                      );

                      if (success) {
                        navigator.pop();
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('Password updated successfully! 🔒'),
                            backgroundColor: AppColors.success,
                          ),
                        );
                      } else {
                        setModalState(() {
                          isSubmitting = false;
                          localError = auth.error ?? 'Failed to update password. Please check your current password.';
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Edit Profile Name Modal ─────────────────────────────────────────────────
  void _showEditProfileModal(String currentName) {
    final nameCtrl = TextEditingController(text: currentName);
    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Container(
          padding: EdgeInsets.fromLTRB(20, 24, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Edit Profile Name',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Full Name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 20),
              GradientButton(
                label: isSaving ? 'Saving...' : 'Update Name',
                icon: Icons.check,
                loading: isSaving,
                onPressed: isSaving ? null : () async {
                  final text = nameCtrl.text.trim();
                  if (text.isEmpty) return;
                  setModalState(() => isSaving = true);
                  final navigator = Navigator.of(ctx);
                  final messenger = ScaffoldMessenger.of(context);
                  final ok = await context.read<AuthProvider>().updateProfile(text);
                  if (ok) {
                    navigator.pop();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Profile name updated! ✨'), backgroundColor: AppColors.success),
                    );
                  } else {
                    setModalState(() => isSaving = false);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Meta Compliance Rules Dialog ────────────────────────────────────────────
  void _showComplianceModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.75,
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.verified_outlined, color: AppColors.primary, size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Meta Guidelines & Limits',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Built-in safety rules keeping your Instagram account 100% compliant with Meta Platform Terms.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  _ruleItem('⏱️ 7-Day Comment Private Reply Window', 'Meta only allows automated private DMs to comments posted within the last 7 days. InstaAuto automatically validates timestamp before sending.'),
                  _ruleItem('🛡️ 1-DM Per Comment Enforcement', 'Instagram strict policy limits automated private replies to 1 per comment to protect users from duplicate spam.'),
                  _ruleItem('🎲 Anti-Spam Jitter (2 - 4.5s Delay)', 'Bot-like instant replies risk account restriction. Our built-in randomized delay makes automation mimic human interaction.'),
                  _ruleItem('📝 Anti-Spam Reply Variations', 'Using identical text repeatedly triggers spam filters. InstaAuto supports rotating template variations with random selection.'),
                  _ruleItem('🔐 Webhook Signature Security', 'All incoming comment webhooks are cryptographically validated against Meta X-Hub-Signature-256 HMAC-SHA256 signature.'),
                  _ruleItem('🗑️ User Data Deletion Guarantee', 'In compliance with Meta developer policies, users can disconnect Instagram or delete their entire account and all associated data at any time.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ruleItem(String title, String desc) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panelGray,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text(desc, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4)),
        ],
      ),
    );
  }

  // ── FAQ Modal ───────────────────────────────────────────────────────────────
  void _showFaqModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.75,
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: AppColors.info.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.help_outline, color: AppColors.info, size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Help & Troubleshooting',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  _ruleItem('Why didn\'t a comment trigger my automation?', 'Ensure the automation status is ACTIVE (not paused or draft). If using specific keywords, comments must contain that keyword. If replying via DM, the comment must be under 7 days old.'),
                  _ruleItem('What account type is required?', 'Meta APIs require an Instagram Professional (Creator or Business) account connected to a Facebook Page. Personal accounts do not support webhook automation.'),
                  _ruleItem('How do I reconnect my Instagram account?', 'Click "Disconnect" on your Instagram card, then click "Connect Instagram Account" to initiate a fresh Meta permission handshake.'),
                  _ruleItem('Are comment replies instantaneous?', 'Public comment replies and private DMs include a subtle 2 to 4.5 second delay intentionally to respect Instagram anti-spam thresholds.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkForUpdatesManual() async {
    final updater = context.read<AppUpdaterService>();
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Checking for app updates...'),
          ],
        ),
        duration: Duration(seconds: 2),
      ),
    );

    final release = await updater.checkForUpdate(silent: false);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();

    if (release != null && updater.isUpdateAvailable) {
      UpdateDialog.show(context, updater);
    } else if (updater.status == UpdateStatus.upToDate) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text("You're using the latest version of InstaAuto! 🎉"),
          backgroundColor: AppColors.success,
        ),
      );
    } else if (updater.errorMessage != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(updater.errorMessage!),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Future<void> _clearCache() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('App cache cleared successfully! 🚀'),
          backgroundColor: AppColors.success,
        ),
      );
    }
  }

  Future<void> _disconnectInstagram() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Instagram?'),
        content: const Text(
          'Automations connected to this account will stop receiving comment webhooks until reconnected.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final messenger = ScaffoldMessenger.of(context);
      final auth = context.read<AuthProvider>();
      try {
        await _api.disconnectInstagram();
        await auth.refreshUser();
        messenger.showSnackBar(
          const SnackBar(content: Text('Instagram account disconnected')),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to disconnect: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _deleteAccount() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Account & All Data?'),
        content: const Text(
          'This will permanently delete your InstaAuto account, all automations, activity logs, and revoke Instagram access.\n\nThis action cannot be undone.',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete Everything', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final messenger = ScaffoldMessenger.of(context);
      final auth = context.read<AuthProvider>();
      try {
        await _api.deleteAccount();
        await auth.logout();
        if (mounted) context.go('/login');
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to delete account: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log Out'),
        content: const Text('Are you sure you want to log out of InstaAuto?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log Out', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await context.read<AuthProvider>().logout();
      if (mounted) context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;
    final ig   = user?.instagram;
    final initialLetter = (user != null && user.name.trim().isNotEmpty)
        ? user.name.trim()[0].toUpperCase()
        : 'U';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Profile & Settings'),
        leading: context.canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
                color: AppColors.textPrimary,
                onPressed: () => context.pop(),
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            color: AppColors.textPrimary,
            tooltip: 'Help & FAQ',
            onPressed: _showFaqModal,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await auth.refreshUser();
          await _checkServer(silent: false);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            // ── User Card ───────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 8, offset: const Offset(0, 2)),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        initialLetter,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.name ?? 'InstaAuto User',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          user?.email ?? '',
                          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20, color: AppColors.primary),
                    tooltip: 'Edit Name',
                    onPressed: () => _showEditProfileModal(user?.name ?? ''),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Instagram Account Card ──────────────────────────────────────
            SectionCard(
              title: 'Instagram Account',
              subtitle: 'Meta Professional or Creator connection',
              child: ig != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [Color(0xFF833AB4), Color(0xFFFD1D1D), Color(0xFFFCB045)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: const Center(
                                child: Icon(Icons.camera_alt_outlined, color: Colors.white, size: 20),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '@${ig.username}',
                                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      Container(
                                        width: 7,
                                        height: 7,
                                        decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
                                      ),
                                      const SizedBox(width: 5),
                                      const Text(
                                        'Connected',
                                        style: TextStyle(fontSize: 12, color: AppColors.success, fontWeight: FontWeight.w600),
                                      ),
                                      if (ig.accountType != null) ...[
                                        const SizedBox(width: 5),
                                        Flexible(
                                          child: Text(
                                            '• ${ig.accountType}',
                                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: _disconnectInstagram,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.error,
                                side: const BorderSide(color: AppColors.error),
                                minimumSize: const Size(76, 32),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('Disconnect', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                        if (ig.connectedAt != null || ig.tokenExpiry != null) ...[
                          const SizedBox(height: 12),
                          const Divider(height: 1),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (ig.connectedAt != null)
                                Flexible(
                                  child: Text(
                                    'Connected: ${_formatDate(ig.connectedAt)}',
                                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              if (ig.connectedAt != null && ig.tokenExpiry != null)
                                const SizedBox(width: 8),
                              if (ig.tokenExpiry != null)
                                Text(
                                  _formatExpiry(ig.tokenExpiry),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: (ig.tokenExpiry!.difference(DateTime.now()).inDays <= 7)
                                        ? AppColors.warning
                                        : AppColors.textSecondary,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'No Instagram account connected. Connect your Professional or Creator account to start receiving webhooks.',
                          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.link),
                            label: const Text('Connect Instagram Account'),
                            onPressed: () => context.push('/connect-instagram'),
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size.fromHeight(42),
                              backgroundColor: AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 20),

            // ── Security & Login Card ───────────────────────────────────────
            SectionCard(
              title: 'Security & Login',
              subtitle: 'Manage credentials and Meta safety protection',
              child: Column(
                children: [
                  _SettingsActionTile(
                    icon: Icons.key_outlined,
                    iconColor: AppColors.primary,
                    title: 'Change Password',
                    subtitle: 'Update account password & security credentials',
                    onTap: _showChangePasswordModal,
                  ),
                  const Divider(height: 1),
                  _SettingsActionTile(
                    icon: Icons.verified_user_outlined,
                    iconColor: AppColors.success,
                    title: 'Meta Guidelines & Safety Rules',
                    subtitle: 'Review built-in anti-spam & rate limits',
                    onTap: _showComplianceModal,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Automation & App Preferences ────────────────────────────────
            SectionCard(
              title: 'Automation & Preferences',
              subtitle: 'Customize notification and safety behavior',
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: AppColors.primary,
                    title: const Text('Anti-Spam Delay (Jitter)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: const Text('Random 2-4.5s delay to keep automations 100% Meta compliant',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    value: _antiSpamJitter,
                    onChanged: (val) {
                      setState(() => _antiSpamJitter = val);
                      _savePreference('pref_anti_spam', val);
                    },
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: AppColors.primary,
                    title: const Text('Comment Activity Alerts', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: const Text('Notify when incoming comments trigger an automated reply',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    value: _commentAlerts,
                    onChanged: (val) {
                      setState(() => _commentAlerts = val);
                      _savePreference('pref_comment_alerts', val);
                    },
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: AppColors.primary,
                    title: const Text('DM Delivery Confirmations', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: const Text('Alert when a private link message is delivered to user',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    value: _dmDeliveryAlerts,
                    onChanged: (val) {
                      setState(() => _dmDeliveryAlerts = val);
                      _savePreference('pref_dm_alerts', val);
                    },
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: AppColors.primary,
                    title: const Text('Auto-Refresh Metrics', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: const Text('Keep recent automations and comments synced periodically',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    value: _autoRefresh,
                    onChanged: (val) {
                      setState(() => _autoRefresh = val);
                      _savePreference('pref_auto_refresh', val);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Storage & Maintenance Card ──────────────────────────────────
            SectionCard(
              title: 'Storage & Maintenance',
              subtitle: 'Free memory and manage cached assets',
              child: Column(
                children: [
                  _SettingsActionTile(
                    icon: Icons.system_update_alt_rounded,
                    iconColor: AppColors.primary,
                    title: 'Check for Updates',
                    subtitle: 'Check for new releases and install directly in-app',
                    onTap: _checkForUpdatesManual,
                  ),
                  const Divider(height: 1),
                  _SettingsActionTile(
                    icon: Icons.cleaning_services_outlined,
                    iconColor: AppColors.warning,
                    title: 'Clear Media Cache',
                    subtitle: 'Clean cached images and thumbnail storage',
                    onTap: _clearCache,
                  ),
                  const Divider(height: 1),
                  _SettingsActionTile(
                    icon: Icons.help_center_outlined,
                    iconColor: AppColors.info,
                    title: 'Troubleshooting & FAQ',
                    subtitle: 'Solutions for common automation questions',
                    onTap: _showFaqModal,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Backend Diagnostics ─────────────────────────────────────────
            SectionCard(
              title: 'Server Diagnostics',
              subtitle: 'Real-time status of Node.js and Meta API webhooks',
              action: IconButton(
                icon: _testingServer
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, size: 18),
                onPressed: _testingServer ? null : () => _checkServer(silent: false),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_statusError != null)
                    Text(_statusError!, style: const TextStyle(fontSize: 12, color: AppColors.error))
                  else if (_serverStatus != null) ...[
                    _diagRow('Express Server', _serverStatus!['server'] == 'running' ? 'Online ✅' : 'Offline', AppColors.success),
                    _diagRow('Automation Mode', '${_serverStatus!['mode'] ?? "LIVE"}', AppColors.primary),
                    _diagRow('Public Comments', '${_serverStatus!['public_reply'] ?? "enabled"}', AppColors.textPrimary),
                    _diagRow('Private DMs', '${_serverStatus!['private_reply'] ?? "enabled"}', AppColors.textPrimary),
                    _diagRow('Meta Token', _serverStatus!['token_set'] == true ? 'Configured ✅' : 'Not Set ⚠️', AppColors.warning),
                  ] else
                    const Text('Tap refresh above to verify live server status.',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Legal & Compliance Links ────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Legal & Compliance (Meta Review)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                  const SizedBox(height: 12),
                  _legalLink('Privacy Policy', Icons.privacy_tip_outlined, () => _openUrl('${AppConstants.baseUrl}/privacy')),
                  const Divider(height: 16),
                  _legalLink('Terms of Service', Icons.gavel_outlined, () => _openUrl('${AppConstants.baseUrl}/terms')),
                  const Divider(height: 16),
                  _legalLink('Data Deletion Instructions', Icons.delete_sweep_outlined, () => _openUrl('${AppConstants.baseUrl}/data-deletion')),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── Logout Button ───────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _logout,
                icon: const Icon(Icons.logout, color: AppColors.error),
                label: const Text('Log Out', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  side: const BorderSide(color: AppColors.error),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── Delete Account ──────────────────────────────────────────────
            Center(
              child: TextButton.icon(
                onPressed: _deleteAccount,
                icon: const Icon(Icons.delete_forever_outlined, color: AppColors.error, size: 18),
                label: const Text('Delete My Account & All Data', style: TextStyle(color: AppColors.error, fontSize: 13)),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Deleting your account permanently removes all automations, activity logs, and revokes Instagram access in compliance with Meta\'s data deletion requirements.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: AppColors.textHint, height: 1.4),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 4),
    );
  }

  Widget _diagRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
          const SizedBox(width: 8),
          Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  Widget _legalLink(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary))),
            const Icon(Icons.open_in_new_rounded, size: 14, color: AppColors.textHint),
          ],
        ),
      ),
    );
  }
}

class _SettingsActionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsActionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textHint),
          ],
        ),
      ),
    );
  }
}
