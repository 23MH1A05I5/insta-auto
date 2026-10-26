import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../models/instagram_media.dart';
import '../../providers/auth_provider.dart';
import '../../providers/automation_provider.dart';
import '../../providers/comment_provider.dart';
import '../../widgets/common/common_widgets.dart';
import '../../widgets/common/app_bottom_nav_bar.dart';

class AllReelsScreen extends StatefulWidget {
  const AllReelsScreen({super.key});

  @override
  State<AllReelsScreen> createState() => _AllReelsScreenState();
}

class _AllReelsScreenState extends State<AllReelsScreen> {
  String _filter = 'all'; // 'all', 'reels', 'automated', 'not_automated'

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = context.read<AutomationProvider>();
      if (p.media.isEmpty) {
        p.fetchMedia(reset: true);
      }
      p.fetchAutomations(silent: true);
    });
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final autoP = context.watch<AutomationProvider>();
    final ig = auth.user?.instagram;
    final allMedia = autoP.media;

    List<InstagramMedia> filtered = allMedia;
    if (_filter == 'reels') {
      filtered = allMedia.where((m) => m.isVideo).toList();
    } else if (_filter == 'automated') {
      filtered = allMedia.where((m) => autoP.isMediaAutomated(m.id)).toList();
    } else if (_filter == 'not_automated') {
      filtered = allMedia.where((m) => !autoP.isMediaAutomated(m.id)).toList();
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Posts & Reels'),
        leading: context.canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
                onPressed: () => context.pop(),
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Posts',
            onPressed: () => autoP.fetchMedia(reset: true),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            autoP.fetchMedia(reset: true),
            autoP.fetchAutomations(silent: true),
          ]);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Account Banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: AppColors.surface,
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
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
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ig != null ? '@${ig.username}' : 'Instagram Posts',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        Text(
                          '${allMedia.length} posts loaded from Instagram',
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Horizontal Filter Chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _chip('all', 'All Posts (${allMedia.length})'),
                  const SizedBox(width: 8),
                  _chip('reels', 'Reels Only (${allMedia.where((m) => m.isVideo).length})'),
                  const SizedBox(width: 8),
                  _chip('automated', 'Automated (${allMedia.where((m) => autoP.isMediaAutomated(m.id)).length})'),
                  const SizedBox(width: 8),
                  _chip('not_automated', 'Not Automated (${allMedia.where((m) => !autoP.isMediaAutomated(m.id)).length})'),
                ],
              ),
            ),

            // Media Grid
            Expanded(
              child: autoP.loadingMedia && allMedia.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : filtered.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 60),
                            EmptyState(
                              icon: Icons.video_library_outlined,
                              title: _filter == 'all' ? 'No posts found' : 'No posts match this filter',
                              subtitle: _filter == 'all'
                                  ? 'Connect your Instagram account or post a Reel to see it here.'
                                  : 'Try selecting a different filter above.',
                            ),
                          ],
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(16),
                          physics: const AlwaysScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 0.68,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final m = filtered[index];
                            final isAutomated = autoP.isMediaAutomated(m.id);

                            return GestureDetector(
                              onTap: () {
                                context.read<CommentProvider>().reset();
                                context.push('/reels/${m.id}', extra: m);
                              },
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: AppColors.panelGray,
                                    border: Border.all(
                                      color: isAutomated ? AppColors.success : AppColors.border,
                                      width: isAutomated ? 1.5 : 1,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      // Image Thumbnail
                                      if (m.displayUrl.isNotEmpty)
                                        CachedNetworkImage(
                                          imageUrl: m.displayUrl,
                                          fit: BoxFit.cover,
                                          placeholder: (_, __) => Container(color: AppColors.panelGray),
                                          errorWidget: (_, __, ___) => Container(
                                            color: AppColors.panelGray,
                                            child: Icon(
                                              m.isVideo ? Icons.videocam : Icons.image,
                                              color: AppColors.textHint,
                                            ),
                                          ),
                                        )
                                      else
                                        Container(
                                          color: AppColors.panelGray,
                                          child: Icon(
                                            m.isVideo ? Icons.videocam : Icons.image,
                                            color: AppColors.textHint,
                                          ),
                                        ),

                                      // Top badges
                                      Positioned(
                                        top: 6,
                                        left: 6,
                                        right: 6,
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            if (m.isVideo)
                                              Container(
                                                padding: const EdgeInsets.all(3),
                                                decoration: BoxDecoration(
                                                  color: Colors.black.withValues(alpha: 0.6),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 12),
                                              )
                                            else
                                              const SizedBox.shrink(),
                                            if (isAutomated)
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: AppColors.success,
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: const Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(Icons.bolt, color: Colors.white, size: 10),
                                                    Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w800)),
                                                  ],
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),

                                      // Gradient overlay at bottom
                                      Positioned(
                                        bottom: 0,
                                        left: 0,
                                        right: 0,
                                        child: Container(
                                          padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.bottomCenter,
                                              end: Alignment.topCenter,
                                              colors: [
                                                Colors.black.withValues(alpha: 0.75),
                                                Colors.transparent,
                                              ],
                                            ),
                                          ),
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                Row(
                                                  children: [
                                                    const Icon(Icons.chat_bubble_outline_rounded, color: Colors.white, size: 10),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      _formatCount(m.commentsCount),
                                                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(width: 8),
                                                Row(
                                                  children: [
                                                    const Icon(Icons.favorite_border_rounded, color: Colors.white, size: 10),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      _formatCount(m.likeCount),
                                                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const AppBottomNavBar(currentIndex: 1),
    );
  }

  Widget _chip(String key, String label) {
    final selected = _filter == key;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      selected: selected,
      selectedColor: AppColors.primary.withValues(alpha: 0.15),
      labelStyle: TextStyle(color: selected ? AppColors.primary : AppColors.textSecondary),
      side: BorderSide(color: selected ? AppColors.primary : AppColors.border),
      onSelected: (_) => setState(() => _filter = key),
    );
  }
}
