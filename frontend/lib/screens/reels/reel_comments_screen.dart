import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../models/instagram_comment.dart';
import '../../models/instagram_media.dart';
import '../../providers/comment_provider.dart';
import '../../widgets/common/common_widgets.dart';
import '../../widgets/comments/reply_composer.dart';

class ReelCommentsScreen extends StatefulWidget {
  final String mediaId;
  final InstagramMedia? media;

  const ReelCommentsScreen({super.key, required this.mediaId, this.media});

  @override
  State<ReelCommentsScreen> createState() => _ReelCommentsScreenState();
}

class _ReelCommentsScreenState extends State<ReelCommentsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initialCount = widget.media?.commentsCount;
      if (initialCount != null && initialCount > 0) {
        context.read<CommentProvider>().setTotalCommentsCount(initialCount);
      }
      context.read<CommentProvider>().loadAllComments(
        widget.mediaId,
        reset: true,
        initialTotalCount: initialCount,
      );
    });
    _scrollCtrl.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 200) {
      final p = context.read<CommentProvider>();
      if (p.hasMore && !p.loading && !p.isLoadingAll) {
        p.fetchComments(widget.mediaId);
      }
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CommentProvider>();
    final media    = widget.media;

    final totalCount = (provider.totalCommentsCount != null && provider.totalCommentsCount! > 0)
        ? (provider.comments.length > provider.totalCommentsCount!
            ? provider.comments.length
            : provider.totalCommentsCount!)
        : (media != null && media.commentsCount > 0
            ? (provider.comments.length > media.commentsCount
                ? provider.comments.length
                : media.commentsCount)
            : provider.comments.length);

    final titleText = totalCount > 0
        ? 'Comments ($totalCount)'
        : (provider.loading ? 'Comments' : 'Comments (0)');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(titleText),
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
          if (provider.loading || provider.isLoadingAll)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                ),
              ),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.bolt_rounded, color: AppColors.primary),
              tooltip: 'Process Existing Comments',
              onPressed: () {
                context.push('/reels/${widget.mediaId}/backfill', extra: {
                  'media': widget.media,
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Refresh comments',
              onPressed: () => context.read<CommentProvider>().loadAllComments(
                widget.mediaId,
                reset: true,
                initialTotalCount: widget.media?.commentsCount,
              ),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // ── Media Header ───────────────────────────────────────────────
          if (media != null) _MediaHeader(media: media, totalCount: totalCount),

          // ── Filter Tabs ────────────────────────────────────────────────
          _FilterTabs(provider: provider, totalCount: totalCount),

          // ── Background Loading Indicator ───────────────────────────────
          if (provider.isLoadingAll)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: AppColors.primary.withValues(alpha: 0.08),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Loading all comments... (${provider.comments.length} of $totalCount loaded)',
                      style: const TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),

          // ── Search Bar ─────────────────────────────────────────────────
          _SearchBar(
            controller: _searchCtrl,
            onChanged: (q) => context.read<CommentProvider>().setSearchQuery(q),
          ),

          // ── Comments List ──────────────────────────────────────────────
          Expanded(child: _buildBody(provider)),
        ],
      ),
    );
  }

  Widget _buildBody(CommentProvider provider) {
    if (provider.loading && provider.comments.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (provider.error != null && provider.comments.isEmpty) {
      return EmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load comments',
        subtitle: provider.error,
        actionLabel: 'Retry',
        onAction: () => provider.loadAllComments(widget.mediaId, reset: true, initialTotalCount: widget.media?.commentsCount),
      );
    }

    final filtered = provider.filteredComments;

    if (filtered.isEmpty) {
      return EmptyState(
        icon: Icons.chat_bubble_outline_rounded,
        title: provider.searchQuery.isNotEmpty
            ? 'No comments match "${provider.searchQuery}"'
            : 'No ${provider.filter == CommentFilter.unreplied ? "unreplied " : provider.filter == CommentFilter.replied ? "replied " : ""}comments',
        subtitle: 'Try a different filter or refresh',
      );
    }

    return RefreshIndicator(
      onRefresh: () => provider.loadAllComments(widget.mediaId, reset: true, initialTotalCount: widget.media?.commentsCount),
      color: AppColors.primary,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.only(bottom: 20),
        itemCount: filtered.length + (provider.hasMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= filtered.length) {
            return const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _CommentCard(
            comment: filtered[i],
            onReply: () async {
              final sent = await ReplyComposerSheet.show(context, filtered[i]);
              if (sent == true) setState(() {});
            },
            onSendDm: () async {
              await DmComposerSheet.show(
                context,
                igUserId: filtered[i].commenterId,
                username: filtered[i].username,
                defaultMessage: 'Hi @${filtered[i].username}! Thanks for your comment 💜',
              );
            },
          );
        },
      ),
    );
  }
}

// ── Media Header ──────────────────────────────────────────────────────────────
class _MediaHeader extends StatelessWidget {
  final InstagramMedia media;
  final int totalCount;
  const _MediaHeader({required this.media, required this.totalCount});

  @override
  Widget build(BuildContext context) {
    final effectiveCommentsCount = totalCount > 0 ? totalCount : media.commentsCount;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: media.displayUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: media.displayUrl,
                    width: 48, height: 48, fit: BoxFit.cover,
                    placeholder: (_, __) => _PlaceholderThumb(),
                    errorWidget: (_, __, ___) => _PlaceholderThumb(),
                  )
                : _PlaceholderThumb(),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  media.caption?.isNotEmpty == true ? media.caption! : 'Instagram Post',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
                if (effectiveCommentsCount > 0)
                  Text('$effectiveCommentsCount total comments',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaceholderThumb extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48, height: 48, color: AppColors.panelGray,
      child: const Icon(Icons.image_rounded, color: AppColors.textHint, size: 20),
    );
  }
}

// ── Filter Tabs ───────────────────────────────────────────────────────────────
class _FilterTabs extends StatelessWidget {
  final CommentProvider provider;
  final int totalCount;
  const _FilterTabs({required this.provider, required this.totalCount});

  @override
  Widget build(BuildContext context) {
    final allCount = totalCount > provider.comments.length ? totalCount : provider.comments.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppColors.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _FilterChip(
              label: 'All ($allCount)',
              selected: provider.filter == CommentFilter.all,
              onTap: () => provider.setFilter(CommentFilter.all),
            ),
            const SizedBox(width: 8),
            _FilterChip(
              label: 'Unreplied (${provider.unrepliedCount})',
              selected: provider.filter == CommentFilter.unreplied,
              onTap: () => provider.setFilter(CommentFilter.unreplied),
            ),
            const SizedBox(width: 8),
            _FilterChip(
              label: 'Replied (${provider.repliedCount})',
              selected: provider.filter == CommentFilter.replied,
              onTap: () => provider.setFilter(CommentFilter.replied),
            ),
            const SizedBox(width: 8),
            _FilterChip(
              label: 'Failed (${provider.failedCount})',
              selected: provider.filter == CommentFilter.failed,
              onTap: () => provider.setFilter(CommentFilter.failed),
            ),
            const SizedBox(width: 8),
            _FilterChip(
              label: 'Skipped (${provider.skippedCount})',
              selected: provider.filter == CommentFilter.skipped,
              onTap: () => provider.setFilter(CommentFilter.skipped),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.panelGray,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ── Search Bar ────────────────────────────────────────────────────────────────
class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      color: AppColors.surface,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Search comments...',
          prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textHint, size: 20),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 18, color: AppColors.textHint),
                  onPressed: () { controller.clear(); onChanged(''); },
                )
              : null,
          filled: true,
          fillColor: AppColors.panelGray,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(25),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
          ),
        ),
      ),
    );
  }
}

// ── Comment Card ──────────────────────────────────────────────────────────────
class _CommentCard extends StatelessWidget {
  final InstagramComment comment;
  final VoidCallback onReply;
  final VoidCallback onSendDm;
  const _CommentCard({required this.comment, required this.onReply, required this.onSendDm});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────
          Row(
            children: [
              _CommentAvatar(username: comment.username, imageUrl: comment.profilePicUrl),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            comment.username,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                        if (comment.timeAgo.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            comment.timeAgo,
                            style: const TextStyle(fontSize: 11, color: AppColors.textHint),
                          ),
                        ],
                      ],
                    ),
                    Text(comment.text,
                        style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                        maxLines: 3, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              // Replied badge
              if (comment.isReplied)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('Replied',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.success)),
                ),
              // Options Menu
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: AppColors.textHint, size: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onSelected: (v) {
                  if (v == 'reply') onReply();
                  if (v == 'dm')    onSendDm();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'reply', child: Text('Reply to Comment')),
                  PopupMenuItem(
                    value: 'dm',
                    child: Text(comment.isEligibleForDm ? 'Send DM' : 'Send DM (Ineligible)'),
                  ),
                ],
              ),
            ],
          ),

          // ── Status Badges Row (Public Reply vs Private DM) ───────────
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _ActionStatusBadge(
                type: 'Public Reply',
                status: comment.publicReplyStatus ?? (comment.isReplied ? 'sent' : 'none'),
              ),
              _ActionStatusBadge(
                type: 'Private DM',
                status: comment.dmStatus ?? (comment.isEligibleForDm ? 'none' : 'ineligible'),
              ),
            ],
          ),

          // ── Ineligible Explanation Banner ────────────────────────────
          if (!comment.isEligibleForDm && comment.dmIneligibleReason != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFCD34D)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFFB45309)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      comment.dmIneligibleReason!,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF92400E)),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ── Actions Row ──────────────────────────────────────────────
          const SizedBox(height: 10),
          Row(
            children: [
              _CommentActionBtn(
                label: 'Reply',
                color: AppColors.primary,
                onTap: onReply,
                loading: comment.isSendingReply,
              ),
              const SizedBox(width: 10),
              _CommentActionBtn(
                label: comment.isEligibleForDm ? 'Send DM' : 'DM Ineligible',
                color: comment.isEligibleForDm ? AppColors.info : AppColors.textHint,
                onTap: () {
                  if (comment.isEligibleForDm) {
                    onSendDm();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(comment.dmIneligibleReason ?? 'This comment is ineligible for a private DM.'),
                        backgroundColor: AppColors.warning,
                      ),
                    );
                  }
                },
                loading: comment.isSendingDm,
              ),
            ],
          ),

          // ── Nested Replies Section ───────────────────────────────────
          if (comment.replies.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.panelGray,
                borderRadius: BorderRadius.circular(10),
                border: Border(
                  left: BorderSide(color: AppColors.primary.withValues(alpha: 0.5), width: 3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.subdirectory_arrow_right_rounded, size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        comment.replies.length == 1
                            ? '1 Reply'
                            : '${comment.replies.length} Replies',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ...comment.replies.map((reply) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _CommentAvatar(username: reply.username ?? 'User', size: 26),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      reply.username ?? 'User',
                                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (reply.timeAgo.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Text(
                                      reply.timeAgo,
                                      style: const TextStyle(fontSize: 10, color: AppColors.textHint),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                reply.text,
                                style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CommentAvatar extends StatelessWidget {
  final String username;
  final String? imageUrl;
  final double size;
  const _CommentAvatar({required this.username, this.imageUrl, this.size = 38});

  Color _colorForName(String name) {
    final colors = [
      const Color(0xFF7C3AED), const Color(0xFF3B82F6), const Color(0xFF10B981),
      const Color(0xFFF59E0B), const Color(0xFFEF4444), const Color(0xFF8B5CF6),
    ];
    int hash = 0;
    for (var c in name.codeUnits) {
      hash += c;
    }
    return colors[hash % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: imageUrl!,
          width: size, height: size, fit: BoxFit.cover,
          placeholder: (_, __) => _fallback(initial),
          errorWidget: (_, __, ___) => _fallback(initial),
        ),
      );
    }
    return _fallback(initial);
  }

  Widget _fallback(String initial) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(color: _colorForName(username), shape: BoxShape.circle),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: (size * 0.4).clamp(9.0, 15.0),
          ),
        ),
      ),
    );
  }
}

class _CommentActionBtn extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool loading;
  const _CommentActionBtn({required this.label, required this.color, required this.onTap, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: loading
            ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: color))
            : Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      ),
    );
  }
}

class _ActionStatusBadge extends StatelessWidget {
  final String type;
  final String status;

  const _ActionStatusBadge({required this.type, required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    IconData icon;
    String label;

    switch (status.toLowerCase()) {
      case 'sent':
      case 'success':
        bg = AppColors.success.withValues(alpha: 0.12);
        fg = AppColors.success;
        icon = Icons.check_circle_outline_rounded;
        label = '$type: Sent';
        break;
      case 'failed':
      case 'error':
        bg = AppColors.error.withValues(alpha: 0.12);
        fg = AppColors.error;
        icon = Icons.error_outline_rounded;
        label = '$type: Failed';
        break;
      case 'ineligible':
        bg = AppColors.warning.withValues(alpha: 0.12);
        fg = AppColors.warning;
        icon = Icons.block_rounded;
        label = '$type: Ineligible';
        break;
      case 'skipped':
        bg = AppColors.warning.withValues(alpha: 0.12);
        fg = AppColors.warning;
        icon = Icons.skip_next_rounded;
        label = '$type: Skipped';
        break;
      case 'pending':
      case 'processing':
        bg = AppColors.info.withValues(alpha: 0.12);
        fg = AppColors.info;
        icon = Icons.hourglass_top_rounded;
        label = '$type: Processing';
        break;
      default:
        bg = AppColors.panelGray;
        fg = AppColors.textSecondary;
        icon = Icons.remove_circle_outline_rounded;
        label = '$type: None';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg),
          ),
        ],
      ),
    );
  }
}

