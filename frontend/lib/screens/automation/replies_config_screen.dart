import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../models/automation_model.dart';
import '../../providers/automation_provider.dart';
import '../../widgets/common/common_widgets.dart';

class RepliesConfigScreen extends StatefulWidget {
  const RepliesConfigScreen({super.key});

  @override
  State<RepliesConfigScreen> createState() => _RepliesConfigScreenState();
}

class _RepliesConfigScreenState extends State<RepliesConfigScreen> {
  late bool _enabled;
  late List<TextEditingController> _controllers;

  static const List<String> kSuggestedReplies = [
    '@{username} Sent you the details in DMs! 📩',
    '@{username} Just sent you a private message with everything! ✨',
    '@{username} Check your DM for the direct link 💜',
  ];

  @override
  void initState() {
    super.initState();
    final draft = context.read<AutomationProvider>().draftPublicReply;
    _enabled = draft.enabled;
    final msgs = (draft.messages.isNotEmpty && draft.messages.any((m) => m.trim().isNotEmpty))
        ? draft.messages.where((m) => m.trim().isNotEmpty).toList()
        : kSuggestedReplies;
    _controllers = msgs.map((m) => TextEditingController(text: m)).toList();
  }

  void _applyAllThreeSuggestions() {
    setState(() {
      for (final c in _controllers) {
        c.dispose();
      }
      _controllers = kSuggestedReplies.map((s) => TextEditingController(text: s)).toList();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Applied 3 anti-spam reply variations ✓'),
        backgroundColor: AppColors.success,
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _addSuggestionText(String text) {
    if (_controllers.length >= 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 6 reply variations allowed')),
      );
      return;
    }
    setState(() {
      _controllers.add(TextEditingController(text: text));
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _saveToDraft() {
    final messages = _controllers
        .map((c) => c.text.trim())
        .where((text) => text.isNotEmpty)
        .toList();

    context.read<AutomationProvider>().updatePublicReply(
      ReplyConfig(
        enabled: _enabled,
        messages: messages.isNotEmpty ? messages : ['@{username} Check your DMs! 📩'],
      ),
    );
  }

  void _addVariation() {
    if (_controllers.length >= 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 6 reply variations allowed')),
      );
      return;
    }
    setState(() {
      _controllers.add(TextEditingController(text: '@{username} Just sent you a DM! ✨'));
    });
  }

  void _removeVariation(int index) {
    if (_controllers.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('At least one reply message is required')),
      );
      return;
    }
    setState(() {
      _controllers[index].dispose();
      _controllers.removeAt(index);
    });
  }

  void _insertTag(int index, String tag) {
    final ctrl = _controllers[index];
    final text = ctrl.text;
    final pos  = ctrl.selection.baseOffset;
    if (pos >= 0 && pos <= text.length) {
      final newText = text.substring(0, pos) + tag + text.substring(pos);
      ctrl.text = newText;
      ctrl.selection = TextSelection.collapsed(offset: pos + tag.length);
    } else {
      ctrl.text = '$text $tag';
    }
    setState(() {});
  }

  void _onNext() {
    _saveToDraft();
    context.push('/automation/configure-dm');
  }

  void _onBack() {
    _saveToDraft();
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/automation/configure-trigger');
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AutomationProvider>();
    final isEditing = provider.editingAutomationId != null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Public Reply' : 'Public Comment Reply'),
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
                isEditing ? 'Editing Mode' : 'Step 3 of 5',
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
                // Main toggle card
                SectionCard(
                  title: 'Reply in Comments',
                  subtitle: 'Post a public reply under the comment on Instagram',
                  action: Switch(
                    value: _enabled,
                    activeColor: AppColors.primary,
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!_enabled) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Public reply is currently disabled. Only direct messages will be sent.',
                          style: TextStyle(fontSize: 13, color: AppColors.textSecondary.withOpacity(0.8)),
                        ),
                      ] else ...[
                        const SizedBox(height: 12),
                        // Instagram Anti-Spam Badge
                        Container(
                          margin: const EdgeInsets.only(bottom: 14),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _controllers.length >= 3
                                ? AppColors.success.withOpacity(0.08)
                                : AppColors.warning.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _controllers.length >= 3
                                  ? AppColors.success.withOpacity(0.3)
                                  : AppColors.warning.withOpacity(0.4),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _controllers.length >= 3 ? Icons.shield_outlined : Icons.info_outline,
                                color: _controllers.length >= 3 ? AppColors.success : AppColors.warning,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _controllers.length >= 3
                                      ? 'Instagram Anti-Spam Compliant: ${_controllers.length} variations active'
                                      : 'Meta Guidelines: Add at least 3 variations to prevent bot detection',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: _controllers.length >= 3 ? AppColors.success : AppColors.warning,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // ── 3 Quick Suggestions Box ─────────────────────────
                        Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.primary.withOpacity(0.25)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Expanded(
                                    child: Row(
                                      children: [
                                        Icon(Icons.auto_awesome, color: AppColors.primary, size: 16),
                                        SizedBox(width: 6),
                                        Flexible(
                                          child: Text(
                                            '3 Ready-Made Suggestions',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.primary,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  InkWell(
                                    onTap: _applyAllThreeSuggestions,
                                    borderRadius: BorderRadius.circular(20),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: AppColors.primary,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.flash_on_rounded, size: 13, color: Colors.white),
                                          SizedBox(width: 4),
                                          Text(
                                            'Apply All 3',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Tap "Apply All 3" to immediately meet Meta rules, or tap a suggestion to add it:',
                                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                              ),
                              const SizedBox(height: 10),
                              ...kSuggestedReplies.asMap().entries.map((e) {
                                final i = e.key + 1;
                                final s = e.value;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: InkWell(
                                    onTap: () => _addSuggestionText(s),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: AppColors.border),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 20,
                                            height: 20,
                                            decoration: BoxDecoration(
                                              color: AppColors.primary.withOpacity(0.1),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Center(
                                              child: Text(
                                                '$i',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color: AppColors.primary,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              s,
                                              style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          const Icon(Icons.add_circle_outline_rounded, size: 16, color: AppColors.primary),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),

                        const Text(
                          'Reply variations (chosen randomly to keep replies natural & prevent spam blocks):',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 16),

                        // List of message inputs
                        ..._controllers.asMap().entries.map((entry) {
                          final idx  = entry.key;
                          final ctrl = entry.value;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppColors.panelGray.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Variation ${idx + 1}',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.primary),
                                    ),
                                    if (_controllers.length > 1)
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.error),
                                        onPressed: () => _removeVariation(idx),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: ctrl,
                                  maxLines: 2,
                                  maxLength: 300,
                                  style: const TextStyle(fontSize: 14),
                                  decoration: InputDecoration(
                                    hintText: 'Enter reply message...',
                                    counterStyle: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: AppColors.border),
                                    ),
                                    fillColor: Colors.white,
                                    filled: true,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  children: [
                                    ActionChip(
                                      label: const Text('+ @{username}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                                      backgroundColor: AppColors.primary.withOpacity(0.08),
                                      side: BorderSide(color: AppColors.primary.withOpacity(0.3)),
                                      labelStyle: const TextStyle(color: AppColors.primary),
                                      onPressed: () => _insertTag(idx, '@{username}'),
                                    ),
                                    ActionChip(
                                      label: const Text('+ 📩 DMs', style: TextStyle(fontSize: 11)),
                                      backgroundColor: AppColors.panelGray,
                                      side: const BorderSide(color: AppColors.border),
                                      onPressed: () => _insertTag(idx, '📩 Check your DMs!'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        }),

                        // Add Variation Button
                        OutlinedButton.icon(
                          onPressed: _addVariation,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add Another Variation'),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppColors.primary),
                            foregroundColor: AppColors.primary,
                            minimumSize: const Size.fromHeight(44),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Preview Box
                if (_enabled && _controllers.isNotEmpty) ...[
                  const Text('Live Preview in Instagram Comments', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 2)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Commenter
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const CircleAvatar(
                              radius: 14,
                              backgroundColor: AppColors.panelGray,
                              child: Icon(Icons.person, size: 16, color: AppColors.textSecondary),
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('alex_miller', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                                  SizedBox(height: 2),
                                  Text('Can I get the price and link please?', style: TextStyle(fontSize: 12)),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Bot Reply
                        Padding(
                          padding: const EdgeInsets.only(left: 24),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: const BoxDecoration(
                                  gradient: AppColors.primaryGradient,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.auto_awesome, size: 14, color: Colors.white),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Row(
                                      children: [
                                        Text('Your Bot', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                                        SizedBox(width: 4),
                                        Icon(Icons.verified, size: 12, color: AppColors.primary),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _controllers.first.text.replaceAll('@{username}', '@alex_miller'),
                                      style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
                    label: isEditing ? 'Save & Continue' : 'Continue to DM',
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
