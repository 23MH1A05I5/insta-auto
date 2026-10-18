import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../models/automation_model.dart';
import '../../models/instagram_media.dart';

// ── Instagram Post Card (grid item for post selection) ────────────────────────
class InstagramPostCard extends StatelessWidget {
  final InstagramMedia media;
  final bool isSelected;
  final VoidCallback onTap;

  const InstagramPostCard({super.key, required this.media, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.primary : Colors.transparent,
            width: 3,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: AppColors.primary.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 2))]
              : [],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Thumbnail
              media.displayUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: media.displayUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.panelGray,
                          child: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
                      errorWidget: (_, __, ___) => _placeholder(),
                    )
                  : _placeholder(),

              // Media type badge
              Positioned(
                top: 6, left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(media.isVideo ? Icons.videocam : (media.isCarousel ? Icons.collections : Icons.image),
                          color: Colors.white, size: 12),
                    ],
                  ),
                ),
              ),

              // Selected overlay
              if (isSelected)
                Positioned(
                  top: 6, right: 6,
                  child: Container(
                    width: 24, height: 24,
                    decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.check, color: Colors.white, size: 14),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
    color: AppColors.panelGray,
    child: const Icon(Icons.image_outlined, color: AppColors.textHint, size: 32),
  );
}

// ── Message Editor ────────────────────────────────────────────────────────────
class MessageEditor extends StatefulWidget {
  final String label;
  final String? hint;
  final String initialValue;
  final int maxLength;
  final int minLines;
  final ValueChanged<String> onChanged;
  final String? error;

  const MessageEditor({
    super.key, required this.label, required this.initialValue,
    required this.onChanged, this.hint, this.maxLength = 500,
    this.minLines = 4, this.error,
  });

  @override
  State<MessageEditor> createState() => _MessageEditorState();
}

class _MessageEditorState extends State<MessageEditor> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(MessageEditor old) {
    super.didUpdateWidget(old);
    if (old.initialValue != widget.initialValue && _ctrl.text != widget.initialValue) {
      _ctrl.text = widget.initialValue;
    }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          maxLines  : null,
          minLines  : widget.minLines,
          maxLength : widget.maxLength,
          onChanged : widget.onChanged,
          style     : const TextStyle(fontSize: 14, height: 1.5),
          decoration: InputDecoration(
            labelText   : widget.label,
            hintText    : widget.hint,
            errorText   : widget.error,
            alignLabelWithHint: true,
            counterStyle: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

// ── Keyword Input Field ───────────────────────────────────────────────────────
class KeywordInputField extends StatefulWidget {
  final List<String> keywords;
  final ValueChanged<List<String>> onChanged;

  const KeywordInputField({super.key, required this.keywords, required this.onChanged});

  @override
  State<KeywordInputField> createState() => _KeywordInputFieldState();
}

class _KeywordInputFieldState extends State<KeywordInputField> {
  final TextEditingController _ctrl = TextEditingController();
  String? _error;

  void _addKeyword(String raw) {
    final parts = raw.split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();
    final current = List<String>.from(widget.keywords);
    bool added = false;
    for (final kw in parts) {
      if (!current.contains(kw) && current.length < 20) {
        current.add(kw);
        added = true;
      }
    }
    if (added) { widget.onChanged(current); _ctrl.clear(); setState(() => _error = null); }
    else setState(() => _error = 'Keyword already added or limit reached');
  }

  void _remove(String kw) {
    final updated = widget.keywords.where((k) => k != kw).toList();
    widget.onChanged(updated);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Chips
        if (widget.keywords.isNotEmpty) ...[
          Wrap(
            spacing: 8, runSpacing: 8,
            children: widget.keywords.map((kw) => Chip(
              label      : Text(kw, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
              deleteIcon : const Icon(Icons.close, size: 14),
              onDeleted  : () => _remove(kw),
              backgroundColor: AppColors.primary.withOpacity(0.1),
              side       : BorderSide(color: AppColors.primary.withOpacity(0.3)),
              deleteIconColor: AppColors.primary,
              labelStyle : const TextStyle(color: AppColors.primary),
            )).toList(),
          ),
          const SizedBox(height: 12),
        ],
        // Input
        Row(
          children: [
            Expanded(
              child: TextField(
                controller : _ctrl,
                decoration : InputDecoration(
                  hintText  : 'Enter a word or multiple words',
                  errorText : _error,
                  helperText: 'Use commas to separate words',
                  helperStyle: const TextStyle(fontSize: 11),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.add_circle_outline, color: AppColors.primary),
                    onPressed: () => _ctrl.text.trim().isNotEmpty ? _addKeyword(_ctrl.text) : null,
                  ),
                ),
                onSubmitted: (v) => v.trim().isNotEmpty ? _addKeyword(v) : null,
                textInputAction: TextInputAction.done,
              ),
            ),
          ],
        ),
        // Suggestion chips
        const SizedBox(height: 10),
        Wrap(
          spacing: 6, runSpacing: 6,
          children: ['Price', 'Link', 'Shop', 'Buy', 'Discount', 'Available']
              .where((s) => !widget.keywords.contains(s.toLowerCase()))
              .map((s) => ActionChip(
                label: Text(s, style: const TextStyle(fontSize: 12)),
                onPressed: () => _addKeyword(s),
                backgroundColor: AppColors.panelGray,
                side: const BorderSide(color: AppColors.border),
              )).toList(),
        ),
      ],
    );
  }
}

// ── Automation Card (list item) ───────────────────────────────────────────────
class AutomationCard extends StatelessWidget {
  final Automation automation;
  final VoidCallback onEdit;
  final VoidCallback onToggleStatus;
  final VoidCallback onDelete;

  const AutomationCard({
    super.key, required this.automation,
    required this.onEdit, required this.onToggleStatus, required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = automation.isActive;
    final statusColor = isActive ? AppColors.success : AppColors.textSecondary;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 52, height: 52,
                    child: automation.mediaThumbnail != null
                        ? CachedNetworkImage(imageUrl: automation.mediaThumbnail!, fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => _thumbPlaceholder())
                        : _thumbPlaceholder(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        automation.name.isNotEmpty ? automation.name : 'Automation for post',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Container(
                              width: 6, height: 6,
                              decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 4),
                            Text(automation.status.toUpperCase(),
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: statusColor)),
                            const SizedBox(width: 12),
                            const Icon(Icons.chat_bubble_outline, size: 12, color: AppColors.textSecondary),
                            const SizedBox(width: 3),
                            Text('${automation.stats.commentsReceived}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                            const SizedBox(width: 8),
                            const Icon(Icons.reply, size: 12, color: AppColors.textSecondary),
                            const SizedBox(width: 3),
                            Text('${automation.stats.repliesSent}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                            const SizedBox(width: 8),
                            const Icon(Icons.send_outlined, size: 12, color: AppColors.textSecondary),
                            const SizedBox(width: 3),
                            Text('${automation.stats.dmsSent}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Actions
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
                  onSelected: (v) {
                    if (v == 'edit')   onEdit();
                    if (v == 'toggle') onToggleStatus();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'edit',   child: Row(children: [const Icon(Icons.edit_outlined, size: 16), const SizedBox(width: 8), const Text('Edit')])),
                    PopupMenuItem(value: 'toggle', child: Row(children: [Icon(isActive ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 16), const SizedBox(width: 8), Text(isActive ? 'Pause' : 'Activate')])),
                    PopupMenuItem(value: 'delete', child: Row(children: [const Icon(Icons.delete_outline, size: 16, color: AppColors.error), const SizedBox(width: 8), const Text('Delete', style: TextStyle(color: AppColors.error))])),
                  ],
                ),
              ],
            ),
            if (automation.trigger.keywords.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6, runSpacing: 4,
                children: automation.trigger.keywords.take(5).map((kw) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.primary.withOpacity(0.2)),
                  ),
                  child: Text(kw, style: const TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w500)),
                )).toList()
                  ..addAll(automation.trigger.keywords.length > 5
                      ? [Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: AppColors.panelGray, borderRadius: BorderRadius.circular(20)),
                          child: Text('+${automation.trigger.keywords.length - 5} more', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        )]
                      : []),
              ),
            ],
            if (automation.trigger.matchType == 'any') ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 8),
              const Row(children: [
                Icon(Icons.all_inclusive, size: 14, color: AppColors.primary),
                SizedBox(width: 4),
                Text('Triggers on any comment', style: TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w500)),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _thumbPlaceholder() => Container(
    color: AppColors.panelGray,
    child: const Icon(Icons.image_outlined, color: AppColors.textHint, size: 24),
  );
}

// ── Automation Preview Card ───────────────────────────────────────────────────
class AutomationPreviewCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final bool enabled;
  final Color? iconColor;

  const AutomationPreviewCard({
    super.key, required this.title, this.subtitle,
    required this.icon, required this.enabled, this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? (enabled ? AppColors.primary : AppColors.textSecondary);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: enabled ? color.withOpacity(0.05) : AppColors.panelGray,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: enabled ? color.withOpacity(0.2) : AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: enabled ? AppColors.textPrimary : AppColors.textSecondary)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: enabled ? AppColors.success.withOpacity(0.1) : AppColors.textSecondary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              enabled ? 'ON' : 'OFF',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: enabled ? AppColors.success : AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
