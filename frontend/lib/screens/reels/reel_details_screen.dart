import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../models/instagram_media.dart';
import '../../providers/automation_provider.dart';
import '../../providers/comment_provider.dart';

class ReelDetailsScreen extends StatefulWidget {
  final InstagramMedia media;
  const ReelDetailsScreen({super.key, required this.media});

  @override
  State<ReelDetailsScreen> createState() => _ReelDetailsScreenState();
}

class _ReelDetailsScreenState extends State<ReelDetailsScreen> {
  InstagramMedia get media => widget.media;

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000)    return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  String _formatDate(String? ts) {
    if (ts == null) return '';
    final d = DateTime.tryParse(ts);
    if (d == null) return '';
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final autoP = context.watch<AutomationProvider>();
    final existingAuto = autoP.getAutomationForMedia(media.id);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Reel Details'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/dashboard');
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: _showOptionsMenu,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Thumbnail ───────────────────────────────────────────────
            _MediaThumbnail(media: media),

            // ── Caption & Date ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (media.caption != null && media.caption!.isNotEmpty) ...[
                    Text(media.caption!,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                  ],
                  if (media.timestamp != null)
                    Text(
                      _formatDate(media.timestamp),
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Stats Row ───────────────────────────────────────────────
            if (media.likeCount > 0 || media.commentsCount > 0 || media.viewsCount > 0)
              _StatsRow(media: media, formatCount: _formatCount),

            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 8),

            // ── Action Tiles ────────────────────────────────────────────
            _ActionTile(
              icon: Icons.chat_bubble_outline_rounded,
              iconColor: AppColors.primary,
              title: 'View Comments',
              subtitle: media.commentsCount > 0
                  ? '${media.commentsCount} comments'
                  : 'See all comments',
              trailing: media.commentsCount > 0
                  ? _CountBadge(count: media.commentsCount)
                  : null,
              onTap: () {
                context.read<CommentProvider>().reset();
                context.push('/reels/${media.id}/comments', extra: media);
              },
            ),
            if (existingAuto != null)
              _ActionTile(
                icon: Icons.check_circle_rounded,
                iconColor: AppColors.success,
                title: 'Manage Automation',
                subtitle: 'Status: ${existingAuto.status.toUpperCase()} (already automated)',
                trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textHint),
                onTap: () {
                  autoP.loadForEditing(existingAuto);
                  context.push('/automations');
                },
              )
            else ...[
              _ActionTile(
                icon: Icons.auto_awesome_rounded,
                iconColor: AppColors.primaryLight,
                title: 'Create Automation',
                subtitle: 'Auto reply to comments',
                onTap: () {
                  autoP.startNewAutomation();
                  autoP.selectMedia(media);
                  context.push('/automation/configure-trigger');
                },
              ),
              _ActionTile(
                icon: Icons.send_rounded,
                iconColor: AppColors.info,
                title: 'DM Automation',
                subtitle: 'Send DMs based on keywords',
                onTap: () {
                  autoP.startNewAutomation();
                  autoP.selectMedia(media);
                  context.push('/automation/configure-dm');
                },
              ),
            ],
            _ActionTile(
              icon: Icons.bar_chart_rounded,
              iconColor: AppColors.success,
              title: 'View Analytics',
              subtitle: 'Activity for this post',
              onTap: () => context.push('/activity'),
            ),
            if (media.permalink != null)
              _ActionTile(
                icon: Icons.link_rounded,
                iconColor: AppColors.warning,
                title: 'Copy Link',
                subtitle: media.permalink ?? '',
                onTap: _copyLink,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyLink() async {
    if (media.permalink != null) {
      await Clipboard.setData(ClipboardData(text: media.permalink!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard ✓')),
        );
      }
    }
  }

  void _showOptionsMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(width: 36, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            if (media.permalink != null)
              ListTile(
                leading: const Icon(Icons.open_in_browser_rounded),
                title: const Text('Open on Instagram'),
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri.parse(media.permalink!);
                  if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy Link'),
              onTap: () { Navigator.pop(context); _copyLink(); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Media Thumbnail ───────────────────────────────────────────────────────────
class _MediaThumbnail extends StatelessWidget {
  final InstagramMedia media;
  const _MediaThumbnail({required this.media});

  @override
  Widget build(BuildContext context) {
    final url = media.displayUrl;
    return Container(
      width: double.infinity,
      height: 280,
      color: AppColors.panelGray,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (url.isNotEmpty)
            CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: AppColors.panelGray),
              errorWidget: (_, __, ___) => _PlaceholderImage(isVideo: media.isVideo),
            )
          else
            _PlaceholderImage(isVideo: media.isVideo),
          if (media.isVideo)
            Center(
              child: Container(
                width: 60, height: 60,
                decoration: BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlaceholderImage extends StatelessWidget {
  final bool isVideo;
  const _PlaceholderImage({this.isVideo = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.panelGray,
      child: Icon(
        isVideo ? Icons.videocam_rounded : Icons.image_rounded,
        size: 64, color: AppColors.textHint,
      ),
    );
  }
}

// ── Stats Row ─────────────────────────────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  final InstagramMedia media;
  final String Function(int) formatCount;
  const _StatsRow({required this.media, required this.formatCount});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            if (media.viewsCount > 0) ...[
              _StatItem(icon: Icons.remove_red_eye_outlined, label: 'Views', value: formatCount(media.viewsCount)),
              const SizedBox(width: 24),
            ],
            if (media.likeCount > 0) ...[
              _StatItem(icon: Icons.favorite_outline_rounded, label: 'Likes', value: formatCount(media.likeCount), color: Colors.redAccent),
              const SizedBox(width: 24),
            ],
            if (media.commentsCount > 0)
              _StatItem(icon: Icons.chat_bubble_outline_rounded, label: 'Comments', value: formatCount(media.commentsCount), color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  const _StatItem({required this.icon, required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textSecondary;
    return Column(
      children: [
        Icon(icon, color: c, size: 22),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c)),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
    );
  }
}

// ── Action Tile ───────────────────────────────────────────────────────────────
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        width: 42, height: 42,
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing ?? const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
    );
  }
}

// ── Count Badge ───────────────────────────────────────────────────────────────
class _CountBadge extends StatelessWidget {
  final int count;
  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text('$count', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
    );
  }
}
