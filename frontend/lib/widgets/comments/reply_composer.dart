import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../models/instagram_comment.dart';
import '../../providers/comment_provider.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Reply Composer Bottom Sheet
// ──────────────────────────────────────────────────────────────────────────────
class ReplyComposerSheet extends StatefulWidget {
  final InstagramComment comment;

  const ReplyComposerSheet({super.key, required this.comment});

  /// Opens the bottom sheet and returns true if a reply was sent.
  static Future<bool?> show(BuildContext context, InstagramComment comment) {
    // Pass parent context explicitly so Provider scope is inherited
    final parentContext = context;
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => ChangeNotifierProvider.value(
        value: Provider.of<CommentProvider>(parentContext, listen: false),
        child: ReplyComposerSheet(comment: comment),
      ),
    );
  }

  @override
  State<ReplyComposerSheet> createState() => _ReplyComposerSheetState();
}

class _ReplyComposerSheetState extends State<ReplyComposerSheet> {
  late final TextEditingController _replyCtrl;
  bool _sendingReply = false;
  bool _sendingDm    = false;
  String? _errorMsg;

  InstagramComment get comment => widget.comment;

  @override
  void initState() {
    super.initState();
    _replyCtrl = TextEditingController();
    // Fetch AI suggestions
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<CommentProvider>().fetchSuggestions(
        comment.text,
        username: comment.username,
      );
    });
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendReply() async {
    final msg = _replyCtrl.text.trim();
    if (msg.isEmpty) return;

    setState(() { _sendingReply = true; _errorMsg = null; });

    final err = await context.read<CommentProvider>().replyToComment(comment.id, msg);
    if (mounted) {
      setState(() => _sendingReply = false);
      if (err != null) {
        setState(() => _errorMsg = err);
      } else {
        if (mounted) Navigator.of(context).pop(true);
        // Show snack via root scaffold
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('Reply sent successfully ✓'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    }
  }

  Future<void> _sendDm() async {
    final msg = _replyCtrl.text.trim();
    if (msg.isEmpty) {
      setState(() => _errorMsg = 'Write a message first');
      return;
    }
    if (comment.isOlderThan7Days) {
      setState(() => _errorMsg = 'Meta Policy: Private replies cannot be sent to comments older than 7 days.');
      return;
    }
    setState(() { _sendingDm = true; _errorMsg = null; });

    final err = await context.read<CommentProvider>().sendDm(
      comment.commenterId,
      comment.username,
      msg,
    );
    if (mounted) {
      setState(() => _sendingDm = false);
      if (err != null) {
        setState(() => _errorMsg = 'DM failed: $err');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('DM sent ✓'), backgroundColor: AppColors.success),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CommentProvider>();
    final kb = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: kb),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Handle ──────────────────────────────────────────────────
            const SizedBox(height: 12),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),

            // ── Header ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _Avatar(username: comment.username, imageUrl: comment.profilePicUrl),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(comment.username,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                        Text(comment.text,
                            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context, false),
                  ),
                ],
              ),
            ),

            const Divider(height: 24),

            // ── Scrollable Content ───────────────────────────────────────
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Action Buttons (Reply / DM / Mark as handled) ────
                    const _QuickActionRow(),

                    const SizedBox(height: 20),

                    // ── AI Suggested Replies ─────────────────────────────
                    const Text('AI Suggested Replies',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),

                    if (provider.loadingSuggestions)
                      const Center(child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ))
                    else
                      ...provider.suggestions.map((s) => _SuggestionCard(
                        text: s,
                        onUse: () => _replyCtrl.text = s,
                        onCopy: () {
                          Clipboard.setData(ClipboardData(text: s));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Copied ✓')),
                          );
                        },
                      )),

                    const SizedBox(height: 20),

                    // ── Custom Reply ─────────────────────────────────────
                    const Text('Custom Reply',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),

                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _replyCtrl,
                      builder: (_, val, __) => TextField(
                        controller: _replyCtrl,
                        maxLines: 4,
                        maxLength: 2200,
                        decoration: InputDecoration(
                          hintText: 'Write your reply...',
                          counterText: '${val.text.length}/2200',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: AppColors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
                          ),
                        ),
                      ),
                    ),

                    if (_errorMsg != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.error.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.error.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: AppColors.error, size: 16),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_errorMsg!,
                                style: const TextStyle(color: AppColors.error, fontSize: 12))),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

            // ── Bottom Bar ───────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.border)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -4))],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_sendingDm || _sendingReply || comment.isOlderThan7Days) ? null : _sendDm,
                      icon: _sendingDm
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(comment.isOlderThan7Days ? Icons.lock_clock_outlined : Icons.send_outlined, size: 18),
                      label: Text(comment.isOlderThan7Days ? 'DM Expired' : 'Send DM'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        foregroundColor: comment.isOlderThan7Days ? AppColors.textSecondary : AppColors.info,
                        side: BorderSide(color: comment.isOlderThan7Days ? AppColors.border : AppColors.info),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: (_sendingReply || _sendingDm) ? null : _sendReply,
                      icon: _sendingReply
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.reply_rounded, size: 18),
                      label: const Text('Send Reply'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Quick Action Row ──────────────────────────────────────────────────────────
class _QuickActionRow extends StatelessWidget {
  const _QuickActionRow();
  @override
  Widget build(BuildContext context) {
    // These are informational chip labels; full actions are in the bottom bar
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: const [
        _QuickChip(label: 'Reply to Comment', icon: Icons.reply_rounded, color: AppColors.primary),
        _QuickChip(label: 'Send DM', icon: Icons.send_rounded, color: AppColors.info),
        _QuickChip(label: 'AI Suggested', icon: Icons.auto_awesome_rounded, color: AppColors.success),
      ],
    );
  }
}

class _QuickChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  const _QuickChip({required this.label, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

// ── Suggestion Card ───────────────────────────────────────────────────────────
class _SuggestionCard extends StatelessWidget {
  final String text;
  final VoidCallback onUse;
  final VoidCallback onCopy;
  const _SuggestionCard({required this.text, required this.onUse, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onUse,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(text, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onCopy,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: AppColors.panelGray, borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.copy_rounded, size: 16, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── DM Composer Sheet ─────────────────────────────────────────────────────────
class DmComposerSheet extends StatefulWidget {
  final String? igUserId;       // Numeric IGSID — required by Instagram DM API
  final String username;         // Display name only
  final String defaultMessage;

  const DmComposerSheet({
    super.key,
    required this.igUserId,
    required this.username,
    required this.defaultMessage,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String? igUserId,
    required String username,
    required String defaultMessage,
  }) {
    final parentContext = context;
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => ChangeNotifierProvider.value(
        value: Provider.of<CommentProvider>(parentContext, listen: false),
        child: DmComposerSheet(igUserId: igUserId, username: username, defaultMessage: defaultMessage),
      ),
    );
  }

  @override
  State<DmComposerSheet> createState() => _DmComposerSheetState();
}

class _DmComposerSheetState extends State<DmComposerSheet> {
  late final TextEditingController _ctrl;
  bool _sending = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.defaultMessage);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _send() async {
    final msg = _ctrl.text.trim();
    if (msg.isEmpty) return;
    setState(() { _sending = true; _errorMsg = null; });

    final err = await context.read<CommentProvider>().sendDm(
      widget.igUserId,
      widget.username,
      msg,
    );
    if (mounted) {
      setState(() => _sending = false);
      if (err != null) {
        setState(() => _errorMsg = err);
      } else {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('DM sent ✓'), backgroundColor: AppColors.success),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: kb),
      child: Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.send_rounded, color: AppColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Send DM to @${widget.username}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context, false)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              maxLines: 5,
              maxLength: 1000,
              decoration: InputDecoration(
                hintText: 'Type your DM...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            if (_errorMsg != null) ...[
              const SizedBox(height: 8),
              Text(_errorMsg!, style: const TextStyle(color: AppColors.error, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send_rounded, size: 18),
                label: const Text('Send DM'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Avatar Widget ─────────────────────────────────────────────────────────────
class _Avatar extends StatelessWidget {
  final String username;
  final String? imageUrl;
  static const double _size = 40;

  const _Avatar({required this.username, this.imageUrl});

  @override
  Widget build(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: imageUrl!,
          width: _size, height: _size,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => _Fallback(username: username),
        ),
      );
    }
    return _Fallback(username: username);
  }
}

class _Fallback extends StatelessWidget {
  final String username;
  static const double _size = 40;
  const _Fallback({required this.username});

  Color _colorForName(String name) {
    final colors = [
      const Color(0xFF7C3AED), const Color(0xFF3B82F6), const Color(0xFF10B981),
      const Color(0xFFF59E0B), const Color(0xFFEF4444), const Color(0xFF8B5CF6),
    ];
    int hash = 0;
    for (var c in name.codeUnits) hash += c;
    return colors[hash % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    return Container(
      width: _size, height: _size,
      decoration: BoxDecoration(color: _colorForName(username), shape: BoxShape.circle),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: _size * 0.4),
        ),
      ),
    );
  }
}
