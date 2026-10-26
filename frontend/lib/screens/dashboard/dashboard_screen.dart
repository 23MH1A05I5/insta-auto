import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/automation_provider.dart';
import '../../providers/comment_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/common/common_widgets.dart';
import '../../models/automation_model.dart';
import '../../models/user_model.dart';
import '../../models/instagram_media.dart';
import '../../services/app_updater.dart';
import '../../widgets/update/update_dialog.dart';
import '../../widgets/common/app_bottom_nav_bar.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Timer? _dashboardTimer;
  static bool _hasCheckedUpdateThisSession = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _checkInAppUpdate();
    });

    // Auto-refresh dashboard stats & recent activity every 30 seconds silently
    _dashboardTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        final auto = context.read<AutomationProvider>();
        auto.fetchAnalytics();
        auto.fetchActivity(reset: true, silent: true);
        auto.fetchAutomations(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _dashboardTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final auto = context.read<AutomationProvider>();
    await Future.wait([
      auto.fetchAutomations(),
      auto.fetchAnalytics(),
      auto.fetchActivity(reset: true),
      auto.fetchMedia(reset: true),
    ]);
  }

  Future<void> _checkInAppUpdate() async {
    if (_hasCheckedUpdateThisSession) return;
    _hasCheckedUpdateThisSession = true;

    try {
      final updater = context.read<AppUpdaterService>();
      final release = await updater.checkForUpdate(silent: true);
      if (!mounted) return;

      if (release != null && updater.isUpdateAvailable) {
        UpdateDialog.show(context, updater);
      }
    } catch (_) {}
  }

  Future<void> _disconnectInstagram() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
        await ApiService().disconnectInstagram();
        if (mounted) {
          await auth.refreshUser();
          messenger.showSnackBar(
            const SnackBar(content: Text('Instagram account disconnected'), backgroundColor: AppColors.warning),
          );
        }
      } catch (e) {
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text('Failed to disconnect: $e'), backgroundColor: AppColors.error),
          );
        }
      }
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
      context.read<AutomationProvider>().reset();
      context.read<CommentProvider>().reset();
      await context.read<AuthProvider>().logout();
      if (mounted) context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth      = context.watch<AuthProvider>();
    final autoP     = context.watch<AutomationProvider>();
    final user      = auth.user;
    final ig        = user?.instagram;
    final analytics = autoP.analytics;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: AppColors.primary,
        child: CustomScrollView(
          slivers: [
            // ── App Bar / Hero Header ────────────────────────────────────
            SliverAppBar(
              expandedHeight: 170,
              floating: false,
              pinned: true,
              backgroundColor: AppColors.primary,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: const BoxDecoration(gradient: AppColors.heroGradient),
                  padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44, height: 44,
                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                            child: const Icon(Icons.auto_awesome, color: Colors.white, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Hi, ${user?.name ?? 'Creator'} 👋',
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                                const Text(
                                  'Manage your Instagram engagement automatically',
                                  style: TextStyle(fontSize: 12, color: Colors.white70),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ],
                            ),
                          ),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, color: Colors.white),
                            color: AppColors.surface,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 8,
                            onSelected: (value) {
                              switch (value) {
                                case 'profile':        context.push('/profile'); break;
                                case 'disconnect_ig':  _disconnectInstagram(); break;
                                case 'logout':         _logout(); break;
                              }
                            },
                            itemBuilder: (ctx) => [
                              const PopupMenuItem(
                                value: 'profile',
                                child: Row(children: [
                                  Icon(Icons.person_outline, size: 20, color: AppColors.textPrimary),
                                  SizedBox(width: 12),
                                  Text('Account & Settings', style: TextStyle(fontSize: 14)),
                                ]),
                              ),
                              if (ig != null)
                                PopupMenuItem(
                                  value: 'disconnect_ig',
                                  child: Row(children: [
                                    const Icon(Icons.link_off, size: 20, color: AppColors.warning),
                                    const SizedBox(width: 12),
                                    Text('Disconnect @${ig.username}', style: const TextStyle(fontSize: 14)),
                                  ]),
                                ),
                              const PopupMenuDivider(),
                              const PopupMenuItem(
                                value: 'logout',
                                child: Row(children: [
                                  Icon(Icons.logout, size: 20, color: AppColors.error),
                                  SizedBox(width: 12),
                                  Text('Log Out', style: TextStyle(fontSize: 14, color: AppColors.error)),
                                ]),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              title: const Row(
                children: [
                  Icon(Icons.auto_awesome, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('InstaAuto', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                ],
              ),
              titleSpacing: 20,
              actions: [
                IconButton(
                  icon: const Icon(Icons.notifications_outlined, color: Colors.white),
                  onPressed: () {},
                ),
              ],
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Instagram Account Card ─────────────────────────
                    if (ig == null) ...[
                      _ConnectInstagramBanner(),
                      const SizedBox(height: 20),
                    ] else ...[
                      _ConnectedAccountCard(ig: ig),
                      const SizedBox(height: 12),
                      // Token expiry warning — required for Meta compliance
                      if (ig.tokenExpiry != null && ig.tokenExpiry!.difference(DateTime.now()).inDays <= 7)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFFCD34D)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, color: Color(0xFFB45309), size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Instagram Access Expiring Soon',
                                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF92400E))),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Your Instagram connection expires on ${ig.tokenExpiry != null ? "${ig.tokenExpiry!.day}/${ig.tokenExpiry!.month}/${ig.tokenExpiry!.year}" : "soon"}. Reconnect to keep automations running.',
                                      style: const TextStyle(fontSize: 12, color: Color(0xFFB45309), height: 1.4),
                                    ),
                                  ],
                                ),
                              ),
                              TextButton(
                                onPressed: () => context.push('/connect-instagram'),
                                style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFF92400E),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                child: const Text('Reconnect', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],

                    // ── Stats Grid ────────────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Overview', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        TextButton(
                          onPressed: () => context.push('/activity'),
                          child: const Text('View Activity', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1.25,
                      children: [
                        _ClickableStatCard(
                          label: 'Comments Processed',
                          value: '${analytics?.commentsReceived ?? 0}',
                          subtitle: 'Total inbound',
                          icon: Icons.chat_bubble_outline_rounded,
                          color: AppColors.info,
                          onTap: () => context.push('/activity'),
                        ),
                        _ClickableStatCard(
                          label: 'Active Automations',
                          value: '${analytics?.activeAutomations ?? autoP.automations.where((a) => a.isActive).length}',
                          subtitle: 'Running rules',
                          icon: Icons.auto_awesome_rounded,
                          color: AppColors.primary,
                          onTap: () => context.push('/automations'),
                        ),
                        _ClickableStatCard(
                          label: 'Confirmed Replies',
                          value: '${analytics?.confirmedReplies ?? analytics?.repliesSent ?? 0}',
                          subtitle: 'Public comments',
                          icon: Icons.reply_rounded,
                          color: AppColors.success,
                          onTap: () => context.push('/activity'),
                        ),
                        _ClickableStatCard(
                          label: 'Confirmed DMs',
                          value: '${analytics?.confirmedDms ?? analytics?.dmsSent ?? 0}',
                          subtitle: 'Delivered to inbox',
                          icon: Icons.send_outlined,
                          color: AppColors.secondary,
                          onTap: () => context.push('/activity'),
                        ),
                        _ClickableStatCard(
                          label: 'Failed Actions',
                          value: '${analytics?.failed ?? 0}',
                          subtitle: (analytics?.failed ?? 0) > 0 ? 'Action required' : 'All delivered',
                          icon: Icons.error_outline_rounded,
                          color: (analytics?.failed ?? 0) > 0 ? AppColors.error : AppColors.success,
                          onTap: () => context.push('/activity'),
                        ),
                        _ClickableStatCard(
                          label: 'Skipped & Pending',
                          value: '${(analytics?.skippedActions ?? 0) + (analytics?.pendingActions ?? 0)}',
                          subtitle: '${analytics?.skippedActions ?? 0} skipped • ${analytics?.pendingActions ?? 0} pending',
                          icon: Icons.hourglass_empty_rounded,
                          color: AppColors.warning,
                          onTap: () => context.push('/activity'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Primary Action Shortcuts ───────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.grid_view_rounded, size: 18),
                            label: const Text('View Posts', style: TextStyle(fontWeight: FontWeight.w700)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.primary,
                              side: const BorderSide(color: AppColors.primary, width: 1.5),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () => context.push('/reels'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.tune_rounded, size: 18),
                            label: const Text('Automations', style: TextStyle(fontWeight: FontWeight.w700)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.textPrimary,
                              side: const BorderSide(color: AppColors.border, width: 1.5),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () => context.push('/automations'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // ── Create Automation CTA ─────────────────────────
                    GradientButton(
                      label: 'Create New Automation',
                      icon: Icons.add_rounded,
                      onPressed: () {
                        context.read<AutomationProvider>().startNewAutomation();
                        context.push('/automation/select-post');
                      },
                    ),
                    const SizedBox(height: 28),

                    // ── Recent Reels ──────────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Recent Reels', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        TextButton(
                          onPressed: () => context.push('/reels'),
                          child: const Text('View all'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _RecentReelsList(media: autoP.media, loading: autoP.loadingMedia),

                    const SizedBox(height: 28),

                    // ── Recent Automations ────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Recent Automations', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        TextButton(onPressed: () => context.push('/automations'), child: const Text('See all')),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (autoP.loadingAutomations)
                      const Center(child: CircularProgressIndicator())
                    else if (autoP.automations.isEmpty)
                      const EmptyState(
                        icon: Icons.auto_awesome_outlined,
                        title: 'No automations yet',
                        subtitle: 'Create your first automation to start replying to comments automatically.',
                      )
                    else
                      ...autoP.automations.take(3).map((a) => _AutomationMiniCard(automation: a)),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 0),
    );
  }
}

// ── Connect Instagram Banner ───────────────────────────────────────────────────
class _ConnectInstagramBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [AppColors.warning.withValues(alpha: 0.1), AppColors.warning.withValues(alpha: 0.05)]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: AppColors.warning.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: const Icon(Icons.link_off, color: AppColors.warning),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No Instagram Connected',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                SizedBox(height: 2),
                Text(
                  'Connect your account to start automating',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: () => context.go('/connect-instagram'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              minimumSize: const Size(80, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('Connect', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

// ── Connected Account Card ────────────────────────────────────────────────────
class _ConnectedAccountCard extends StatelessWidget {
  final InstagramAccount ig;
  const _ConnectedAccountCard({required this.ig});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          // Instagram-style gradient avatar
          Container(
            width: 44, height: 44,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF833AB4), Color(0xFFFD1D1D), Color(0xFFFCB045)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: const Center(child: Icon(Icons.camera_alt_outlined, color: Colors.white, size: 22)),
          ),
          const SizedBox(width: 12),
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
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 7, height: 7,
                      decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 4),
                    const Text('Connected', style: TextStyle(fontSize: 12, color: AppColors.success, fontWeight: FontWeight.w500)),
                    if (ig.accountType != null) ...[
                      const SizedBox(width: 6),
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
          const Icon(Icons.chevron_right_rounded, color: AppColors.textHint),
        ],
      ),
    );
  }
}

// ── Clickable Stat Card ───────────────────────────────────────────────────────
class _ClickableStatCard extends StatelessWidget {
  final String label;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ClickableStatCard({
    required this.label,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                  child: Icon(icon, color: color, size: 16),
                ),
                const Spacer(),
                const Icon(Icons.arrow_forward_ios_rounded, size: 11, color: AppColors.textHint),
              ],
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Recent Reels List ─────────────────────────────────────────────────────────
class _RecentReelsList extends StatelessWidget {
  final List<InstagramMedia> media;
  final bool loading;
  const _RecentReelsList({required this.media, required this.loading});

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000)    return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    if (loading && media.isEmpty) {
      return SizedBox(
        height: 160,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: 3,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, __) => const ShimmerCard(height: 160, width: 120),
        ),
      );
    }

    if (media.isEmpty) {
      return Container(
        height: 140,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.video_library_outlined, color: AppColors.textHint, size: 32),
              SizedBox(height: 8),
              Text('No reels yet', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              Text('Connect Instagram to see your posts', style: TextStyle(color: AppColors.textHint, fontSize: 11)),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      height: 170,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: media.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final m = media[i];
          return GestureDetector(
            onTap: () {
              context.read<CommentProvider>().reset();
              context.push('/reels/${m.id}', extra: m);
            },
            child: Container(
              width: 120,
              decoration: BoxDecoration(
                color: AppColors.panelGray,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Thumbnail
                  ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: m.displayUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: m.displayUrl,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(color: AppColors.panelGray),
                            errorWidget: (_, __, ___) => _ReelPlaceholder(isVideo: m.isVideo),
                          )
                        : _ReelPlaceholder(isVideo: m.isVideo),
                  ),
                  // Gradient overlay
                  ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.65)],
                        ),
                      ),
                    ),
                  ),
                  // Video play icon
                  if (m.isVideo)
                    const Positioned(
                      top: 8, left: 8,
                      child: Icon(Icons.play_circle_filled_rounded, color: Colors.white70, size: 22),
                    ),
                  // Stats overlay at bottom
                  Positioned(
                    bottom: 8, left: 8, right: 8,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (m.viewsCount > 0)
                          Row(children: [
                            const Icon(Icons.remove_red_eye_outlined, color: Colors.white70, size: 11),
                            const SizedBox(width: 3),
                            Text(_formatCount(m.viewsCount), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                          ]),
                        if (m.likeCount > 0)
                          Row(children: [
                            const Icon(Icons.favorite_rounded, color: Colors.redAccent, size: 11),
                            const SizedBox(width: 3),
                            Text(_formatCount(m.likeCount), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                          ]),
                        if (m.commentsCount > 0)
                          Row(children: [
                            const Icon(Icons.chat_bubble_rounded, color: Colors.white70, size: 11),
                            const SizedBox(width: 3),
                            Text(_formatCount(m.commentsCount), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                          ]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ReelPlaceholder extends StatelessWidget {
  final bool isVideo;
  const _ReelPlaceholder({this.isVideo = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.panelGray,
      child: Icon(
        isVideo ? Icons.videocam_rounded : Icons.image_rounded,
        color: AppColors.textHint, size: 32,
      ),
    );
  }
}

// ── Automation Mini Card ──────────────────────────────────────────────────────
class _AutomationMiniCard extends StatelessWidget {
  final Automation automation;
  const _AutomationMiniCard({required this.automation});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/automations'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(
          children: [
            // Thumbnail
            if (automation.mediaThumbnail != null && automation.mediaThumbnail!.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: automation.mediaThumbnail!,
                  width: 40, height: 40, fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(width: 40, height: 40, color: AppColors.panelGray,
                      child: const Icon(Icons.image_rounded, color: AppColors.textHint, size: 18)),
                ),
              )
            else
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.auto_awesome, color: AppColors.primary, size: 18),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    automation.name.isNotEmpty ? automation.name : 'Post automation',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (automation.trigger.keywords.isNotEmpty)
                        Flexible(
                          child: Text(
                            automation.trigger.keywords.take(2).join(', '),
                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      const SizedBox(width: 4),
                      Text(
                        '• ${automation.stats.repliesSent} replies',
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: automation.isActive ? AppColors.success.withValues(alpha: 0.1) : AppColors.border,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                automation.isActive ? 'Active' : automation.status.toUpperCase(),
                style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  color: automation.isActive ? AppColors.success : AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


