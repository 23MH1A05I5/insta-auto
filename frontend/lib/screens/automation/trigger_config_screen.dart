import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../models/automation_model.dart';
import '../../providers/automation_provider.dart';
import '../../widgets/automation/automation_widgets.dart';
import '../../widgets/common/common_widgets.dart';

class TriggerConfigScreen extends StatefulWidget {
  const TriggerConfigScreen({super.key});

  @override
  State<TriggerConfigScreen> createState() => _TriggerConfigScreenState();
}

class _TriggerConfigScreenState extends State<TriggerConfigScreen> {
  late String _matchType;
  late List<String> _keywords;
  late bool _wholeWord;

  @override
  void initState() {
    super.initState();
    final draft = context.read<AutomationProvider>().draftTrigger;
    _matchType = draft.matchType;
    _keywords  = List<String>.from(draft.keywords);
    _wholeWord = draft.wholeWord;
  }

  void _saveToDraft() {
    context.read<AutomationProvider>().updateTrigger(
      TriggerRule(
        matchType: _matchType,
        keywords : _keywords,
        wholeWord: _wholeWord,
      ),
    );
  }

  void _onNext() {
    if (_matchType == 'keywords' && _keywords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add at least one trigger keyword or select "All comments"'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }
    _saveToDraft();
    context.push('/automation/configure-replies');
  }

  void _onBack() {
    _saveToDraft();
    final provider = context.read<AutomationProvider>();
    if (provider.editingAutomationId != null) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/automations');
      }
    } else {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/automation/select-post');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AutomationProvider>();
    final media    = provider.selectedMedia;
    final isEditing = provider.editingAutomationId != null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Trigger' : 'Comment Trigger'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: _onBack,
        ),
        actions: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isEditing ? AppColors.warning.withOpacity(0.12) : AppColors.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: isEditing ? Border.all(color: AppColors.warning.withOpacity(0.4)) : null,
              ),
              child: Text(
                isEditing ? 'Editing Mode' : 'Step 2 of 5',
                style: TextStyle(
                  fontSize: 12,
                  color: isEditing ? AppColors.warning : AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Selected post banner
                if (media != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: media.displayUrl.isNotEmpty
                                ? CachedNetworkImage(
                                    imageUrl: media.displayUrl,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, __, ___) => const Icon(Icons.image, color: AppColors.textSecondary),
                                  )
                                : const Icon(Icons.image, color: AppColors.textSecondary),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                media.caption?.isNotEmpty == true ? media.caption! : 'Selected Instagram Post',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Type: ${media.mediaType}',
                                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        if (isEditing)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.panelGray,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.lock_outline, size: 12, color: AppColors.textSecondary),
                                SizedBox(width: 4),
                                Text('Post Fixed', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
                              ],
                            ),
                          )
                        else
                          TextButton(
                            onPressed: () {
                              _saveToDraft();
                              context.go('/automation/select-post');
                            },
                            child: const Text('Change', style: TextStyle(fontSize: 12)),
                          ),
                      ],
                    ),
                  ),

                // Question Title
                const Text(
                  'When should this trigger?',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Choose whether to respond to specific keywords or every comment.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),

                // Radio: Specific Keywords
                _OptionCard(
                  title: 'Specific keywords',
                  subtitle: 'Respond only when a comment contains specific words or phrases',
                  icon: Icons.tag,
                  selected: _matchType == 'keywords',
                  onTap: () => setState(() => _matchType = 'keywords'),
                ),
                const SizedBox(height: 12),

                // Radio: Any comment
                _OptionCard(
                  title: 'All comments',
                  subtitle: 'Respond to every new comment left on this post or Reel',
                  icon: Icons.all_inclusive,
                  selected: _matchType == 'any',
                  onTap: () => setState(() => _matchType = 'any'),
                ),
                const SizedBox(height: 24),

                // Keyword input (if keywords selected)
                if (_matchType == 'keywords') ...[
                  SectionCard(
                    title: 'Trigger Keywords',
                    subtitle: 'Add words or phrases that activate the reply and DM',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        KeywordInputField(
                          keywords: _keywords,
                          onChanged: (updated) => setState(() => _keywords = updated),
                        ),
                        const SizedBox(height: 16),
                        const Divider(height: 1),
                        const SizedBox(height: 12),
                        ToggleRow(
                          title: 'Match whole words only',
                          subtitle: 'If off, "link" will also match "blink" or "linking"',
                          value: _wholeWord,
                          onChanged: (v) => setState(() => _wholeWord = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Helpful Info Card
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.info.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.info.withOpacity(0.2)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: AppColors.info, size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Keywords are case-insensitive. Self-reply protection prevents your account from triggering its own bot.',
                          style: TextStyle(fontSize: 12, color: AppColors.textPrimary, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Bottom Bar
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _onBack,
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: GradientButton(
                    label: isEditing ? 'Save & Continue' : 'Continue to Replies',
                    icon: Icons.arrow_forward,
                    onPressed: _onNext,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _OptionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: AppColors.primary.withOpacity(0.12), blurRadius: 8, offset: const Offset(0, 2))]
              : [],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: selected ? AppColors.primary.withOpacity(0.12) : AppColors.panelGray,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: selected ? AppColors.primary : AppColors.textSecondary, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? AppColors.primary : AppColors.border,
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
