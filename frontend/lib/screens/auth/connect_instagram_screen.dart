import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/common/common_widgets.dart';

class ConnectInstagramScreen extends StatefulWidget {
  const ConnectInstagramScreen({super.key});
  @override
  State<ConnectInstagramScreen> createState() => _ConnectInstagramScreenState();
}

class _ConnectInstagramScreenState extends State<ConnectInstagramScreen> with WidgetsBindingObserver {
  final ApiService _api = ApiService();
  bool _connecting = false;
  bool _waitingForReturn = false;
  String? _error;
  String? _oauthUrl;
  StreamSubscription? _linkSub;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenDeepLink();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  // When app resumes from browser, poll for Instagram connection
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForReturn) {
      _waitingForReturn = false;
      _startContinuousPolling();
    }
  }

  void _listenDeepLink() {
    final appLinks = AppLinks();
    _linkSub = appLinks.uriLinkStream.listen((uri) {
      if (uri.scheme == 'instauto' && uri.host == 'oauth-callback') {
        _pollTimer?.cancel();
        final success = uri.queryParameters['success'];
        final err     = uri.queryParameters['error'];
        if (success == '1') {
          _onOAuthSuccess();
        } else {
          setState(() { _connecting = false; _error = err ?? 'Authorization failed'; });
        }
      }
    });
  }

  Future<bool> _launchUrlRobust(Uri uri) async {
    // 1. Try LaunchMode.externalApplication (system browser: Chrome, Safari, etc.)
    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
      if (ok) return true;
    } catch (e) {
      debugPrint('LaunchMode.externalApplication error: $e');
    }

    // 2. Try LaunchMode.platformDefault
    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_blank',
      );
      if (ok) return true;
    } catch (e) {
      debugPrint('LaunchMode.platformDefault error: $e');
    }

    // 3. Try inAppBrowserView (Android Custom Tabs / SFSafariViewController)
    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      );
      if (ok) return true;
    } catch (e) {
      debugPrint('LaunchMode.inAppBrowserView error: $e');
    }

    // 4. Try canLaunchUrl check
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri);
      }
    } catch (e) {
      debugPrint('canLaunchUrl error: $e');
    }

    return false;
  }

  Future<void> _startOAuth() async {
    setState(() { _connecting = true; _error = null; });
    try {
      final res = await _api.startInstagramOAuth();
      final urlStr = res['url'] as String?;
      if (urlStr == null || urlStr.isEmpty) {
        throw Exception('Server did not return authorization URL');
      }

      setState(() => _oauthUrl = urlStr);
      final uri = Uri.parse(urlStr);

      _waitingForReturn = true;
      _startContinuousPolling();

      final launched = await _launchUrlRobust(uri);
      if (!launched) {
        setState(() {
          _error = 'Could not open browser automatically on this mobile device.';
        });
      }
    } catch (e) {
      _pollTimer?.cancel();
      setState(() { _error = 'Failed to start authorization: $e'; _connecting = false; });
    }
  }

  /// Copy authorization link to clipboard
  Future<void> _copyOAuthLink() async {
    if (_oauthUrl != null) {
      await Clipboard.setData(ClipboardData(text: _oauthUrl!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authorization link copied! Open Chrome or Safari and paste to connect ✓'),
            backgroundColor: AppColors.primary,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Continuously poll server every 2s so the app automatically detects when
  /// Instagram authorization is completed in the browser.
  void _startContinuousPolling() {
    _pollTimer?.cancel();
    int attempts = 0;
    const maxAttempts = 60; // 2 minutes

    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      attempts++;
      if (!mounted) { timer.cancel(); return; }

      try {
        final auth = context.read<AuthProvider>();
        await auth.refreshUser();
        if (!mounted) { timer.cancel(); return; }
        final user = auth.user;
        if (user?.hasInstagram == true) {
          timer.cancel();
          _onOAuthSuccess();
          return;
        }
      } catch (_) {}

      if (attempts >= maxAttempts) {
        timer.cancel();
        if (mounted) {
          setState(() {
            _connecting = false;
            _error = 'Authorization timed out. If you authorized, tap "Check Status" below or tap "Connect" again.';
          });
        }
      }
    });
  }

  Future<void> _retryCheck() async {
    setState(() { _connecting = true; _error = null; });
    try {
      final auth = context.read<AuthProvider>();
      await auth.refreshUser();
      if (!mounted) return;
      final user = auth.user;
      if (user?.hasInstagram == true) {
        _onOAuthSuccess();
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _connecting = false;
        _error = 'Instagram not connected yet. Try the authorization again.';
      });
    }
  }

  Future<void> _onOAuthSuccess() async {
    _pollTimer?.cancel();
    await context.read<AuthProvider>().refreshUser();
    if (mounted) {
      setState(() => _connecting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Instagram connected successfully! ✅'), backgroundColor: AppColors.success),
      );
      context.go('/dashboard');
    }
  }

  /// Show explicit permissions review modal before opening browser
  void _showPermissionConsentModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF833AB4), Color(0xFFFD1D1D), Color(0xFFFCB045)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.security, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Instagram Permissions',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        'Official Meta Graph API Permissions',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'InstaAuto requests only the permissions necessary to automate comments and DMs:',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),

            _permissionRow(
              code: 'instagram_business_basic',
              title: 'Account Profile & Posts',
              desc: 'Reads your Instagram handle, profile ID, and posts so you can select posts for automation.',
              icon: Icons.person_outline,
            ),
            const SizedBox(height: 10),
            _permissionRow(
              code: 'instagram_business_manage_comments',
              title: 'Comment Management',
              desc: 'Listens for incoming comments and posts instant public replies configured in your rules.',
              icon: Icons.chat_bubble_outline_rounded,
            ),
            const SizedBox(height: 10),
            _permissionRow(
              code: 'instagram_business_manage_messages',
              title: 'Direct Messaging (DMs)',
              desc: 'Sends private direct messages with links and answers to commenters who trigger your keywords.',
              icon: Icons.send_outlined,
            ),

            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.success.withValues(alpha: 0.2)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_outline, color: AppColors.success, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'We never read personal chats, delete posts, or post photos on your feed.',
                      style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: GradientButton(
                    label: 'Allow & Open Browser',
                    icon: Icons.open_in_browser_rounded,
                    onPressed: () {
                      Navigator.pop(ctx);
                      _startOAuth();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionRow({
    required String code,
    required String title,
    required String desc,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panelGray.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: AppColors.primary, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.success.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                      child: const Text('Required', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.success)),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(desc, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect Instagram'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () {
            _pollTimer?.cancel();
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/dashboard');
            }
          },
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Illustration Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                gradient: AppColors.heroGradient,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Container(
                    width: 80, height: 80,
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                    child: const Icon(Icons.link, size: 44, color: Colors.white),
                  ),
                  const SizedBox(height: 20),
                  const Text('Connect Your Instagram', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
                  const SizedBox(height: 8),
                  Text(
                    'Authorize InstaAuto to manage your Instagram comments and DMs.',
                    style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.85)),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Requirements Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Requirements', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  ...[
                    ('Instagram Professional / Creator account', Icons.business_center_outlined),
                    ('Meta App with Instagram Login', Icons.apps_outlined),
                    ('Comment & message permissions', Icons.message_outlined),
                  ].map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(children: [
                      Container(
                        width: 28, height: 28,
                        decoration: BoxDecoration(color: AppColors.success.withValues(alpha: 0.1), shape: BoxShape.circle),
                        child: Icon(e.$2, color: AppColors.success, size: 16),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(e.$1, style: const TextStyle(fontSize: 13))),
                    ]),
                  )),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Permissions Card (User requested explicit permissions disclosure)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.shield_outlined, color: AppColors.primary, size: 18),
                          SizedBox(width: 8),
                          Text('Requested Permissions', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                        ],
                      ),
                      TextButton(
                        onPressed: _showPermissionConsentModal,
                        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(50, 30)),
                        child: const Text('Review', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'InstaAuto will ask Meta for 3 standard business permissions:',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6, runSpacing: 6,
                    children: [
                      _permChip('Basic Profile', Icons.person_outline),
                      _permChip('Comment Management', Icons.chat_bubble_outline),
                      _permChip('Send DMs', Icons.send_outlined),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Helpful Tip Banner for Mobile Browsers
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFCD34D)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline, color: Color(0xFFB45309), size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Mobile Browser Tip',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF92400E)),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'If your mobile browser does not open automatically or takes you to your Instagram feed, use the "Copy Link" option below and open it directly in Chrome or Safari.',
                          style: TextStyle(fontSize: 12, color: Color(0xFFB45309), height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            if (_error != null) ...[
              ErrorBanner(message: _error!, onRetry: _retryCheck),
              const SizedBox(height: 12),
            ],

            // If OAuth URL is generated or if browser couldn't open automatically
            if (_oauthUrl != null && !_connecting) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.phonelink_setup_rounded, color: AppColors.primary, size: 20),
                        SizedBox(width: 8),
                        Text('Mobile Direct Access', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.primary)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'If the browser did not pop up, tap below to launch directly or copy the URL to paste into Chrome/Safari:',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              _waitingForReturn = true;
                              _startContinuousPolling();
                              _launchUrlRobust(Uri.parse(_oauthUrl!));
                            },
                            icon: const Icon(Icons.open_in_browser_rounded, size: 16),
                            label: const Text('Open in Browser', style: TextStyle(fontSize: 12)),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _copyOAuthLink,
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('Copy Link', style: TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            if (_connecting) ...[
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
                ),
                child: Column(
                  children: [
                    const SizedBox(
                      width: 36, height: 36,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Waiting for Instagram authorization…',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Complete authorization in your browser tab. We will automatically detect your connection!',
                      style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _retryCheck,
                      icon: const Icon(Icons.sync, size: 18),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('I\'ve Approved — Check Connection'),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: const BorderSide(color: AppColors.primary),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    if (_oauthUrl != null) ...[
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: _copyOAuthLink,
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: const Text('Copy Link Again', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  _pollTimer?.cancel();
                  setState(() => _connecting = false);
                },
                child: const Text('Cancel', style: TextStyle(color: AppColors.error)),
              ),
            ] else ...[
              GradientButton(
                label   : 'Connect with Instagram',
                icon    : Icons.link,
                loading : false,
                onPressed: _showPermissionConsentModal,
              ),
            ],
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                _pollTimer?.cancel();
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/dashboard');
                }
              },
              child: const Text('Skip for now', style: TextStyle(color: AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permChip(String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.panelGray,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}
