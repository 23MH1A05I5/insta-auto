import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../models/automation_model.dart';
import '../../providers/automation_provider.dart';
import '../../widgets/common/common_widgets.dart';

class DmConfigScreen extends StatefulWidget {
  const DmConfigScreen({super.key});

  @override
  State<DmConfigScreen> createState() => _DmConfigScreenState();
}

class _DmConfigScreenState extends State<DmConfigScreen> {
  late bool _dmEnabled;
  late bool _buttonEnabled;
  late TextEditingController _openingMsgCtrl;
  late TextEditingController _buttonTextCtrl;
  late TextEditingController _linkCtrl;
  late TextEditingController _finalMsgCtrl;

  @override
  void initState() {
    super.initState();
    final provider = context.read<AutomationProvider>();
    final opening  = provider.draftOpeningDm;
    final finalDm  = provider.draftFinalDm;

    _dmEnabled       = opening.enabled;
    _buttonEnabled   = opening.buttonEnabled &&
        (provider.editingAutomationId == null || opening.buttonText.isNotEmpty || opening.link.isNotEmpty);
    _openingMsgCtrl  = TextEditingController(
      text: opening.message.isNotEmpty
          ? opening.message
          : "Hey there! I'm so happy you're here, thanks so much for your interest 😊\n\nClick below and I'll send you the link in just a sec ✨",
    );
    _buttonTextCtrl  = TextEditingController(
      text: opening.buttonText.isNotEmpty ? opening.buttonText : 'Send me the link',
    );
    _linkCtrl        = TextEditingController(
      text: finalDm.link.isNotEmpty
          ? finalDm.link
          : (opening.link.isNotEmpty ? opening.link : 'https://yourwebsite.com/offer'),
    );
    _finalMsgCtrl    = TextEditingController(
      text: finalDm.message.isNotEmpty
          ? finalDm.message
          : 'Here is your direct access link! Tap below to open:',
    );
  }

  @override
  void dispose() {
    _openingMsgCtrl.dispose();
    _buttonTextCtrl.dispose();
    _linkCtrl.dispose();
    _finalMsgCtrl.dispose();
    super.dispose();
  }

  void _saveToDraft() {
    final provider = context.read<AutomationProvider>();

    provider.updateOpeningDm(
      DmConfig(
        enabled       : _dmEnabled,
        message       : _openingMsgCtrl.text.trim(),
        buttonEnabled : _buttonEnabled,
        buttonText    : _buttonEnabled ? _buttonTextCtrl.text.trim() : '',
        link          : _buttonEnabled ? _linkCtrl.text.trim() : '',
      ),
    );

    provider.updateFinalDm(
      DmConfig(
        enabled       : _dmEnabled,
        message       : _finalMsgCtrl.text.trim(),
        buttonEnabled : _buttonEnabled,
        buttonText    : _buttonEnabled ? 'Open Link' : '',
        link          : _buttonEnabled ? _linkCtrl.text.trim() : '',
      ),
    );
  }

  void _onNext() {
    if (_dmEnabled && _openingMsgCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an opening DM message'), backgroundColor: AppColors.warning),
      );
      return;
    }

    // Validate button text and link URL only if DM and CTA button are both enabled
    if (_dmEnabled && _buttonEnabled) {
      final btnText = _buttonTextCtrl.text.trim();
      if (btnText.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter text for the interactive button or toggle it off'),
            backgroundColor: AppColors.warning,
          ),
        );
        return;
      }

      final link = _linkCtrl.text.trim();
      if (link.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a destination URL or toggle off the button'),
            backgroundColor: AppColors.warning,
          ),
        );
        return;
      }

      final uri = Uri.tryParse(link);
      if (uri == null || (!link.startsWith('http://') && !link.startsWith('https://'))) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a valid URL starting with https://'),
            backgroundColor: AppColors.warning,
          ),
        );
        return;
      }
    }

    _saveToDraft();
    context.push('/automation/preview');
  }

  void _onBack() {
    _saveToDraft();
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/automation/configure-replies');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = context.watch<AutomationProvider>().editingAutomationId != null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Direct Message' : 'Direct Message (DM)'),
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
                color: isEditing ? AppColors.warning.withValues(alpha: 0.12) : AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: isEditing ? Border.all(color: AppColors.warning.withValues(alpha: 0.4)) : null,
              ),
              child: Text(
                isEditing ? 'Editing Mode' : 'Step 4 of 5',
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
                // Instagram Rules Compliance Card
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF833AB4).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF833AB4).withValues(alpha: 0.25)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.verified_user_outlined, color: Color(0xFF833AB4), size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Instagram Messaging Rules Compliant',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF833AB4)),
                            ),
                            SizedBox(height: 3),
                            Text(
                              '• Meta restricts private replies to within 7 days of the comment.\n• Only 1 automated DM is permitted per commenter.\n• Button text limited to 20 characters per Meta specs.\n• Toggle the button on/off based on whether you want a tap-able link.',
                              style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary, height: 1.4),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // DM Toggle Card
                SectionCard(
                  title: 'Send Direct Message',
                  subtitle: 'Automatically send a private DM when the comment trigger matches',
                  action: Switch(
                    value: _dmEnabled,
                    activeThumbColor: AppColors.primary,
                    onChanged: (v) => setState(() => _dmEnabled = v),
                  ),
                  child: !_dmEnabled
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Direct messaging is disabled for this automation. Only comments will be handled.',
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary.withValues(alpha: 0.8)),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Opening DM Message',
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${_openingMsgCtrl.text.length}/640 (Meta limit)',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _openingMsgCtrl.text.length > 640 ? AppColors.error : AppColors.textSecondary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'The first private message sent directly to the commenter:',
                              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _openingMsgCtrl,
                              maxLines: 4,
                              maxLength: 640,
                              onChanged: (_) => setState(() {}),
                              style: const TextStyle(fontSize: 14),
                              decoration: InputDecoration(
                                hintText: 'Enter DM message...',
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                fillColor: Colors.white,
                                filled: true,
                              ),
                            ),
                            const SizedBox(height: 18),

                            // ── Interactive CTA Button Card with Toggle ─────────────────
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: _buttonEnabled
                                    ? AppColors.primary.withValues(alpha: 0.03)
                                    : AppColors.panelGray.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _buttonEnabled
                                      ? AppColors.primary.withValues(alpha: 0.35)
                                      : AppColors.border,
                                  width: _buttonEnabled ? 1.5 : 1,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Toggle Header
                                  Row(
                                    children: [
                                      Container(
                                        width: 36,
                                        height: 36,
                                        decoration: BoxDecoration(
                                          color: (_buttonEnabled ? AppColors.primary : AppColors.textSecondary)
                                              .withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Icon(
                                          Icons.touch_app_outlined,
                                          color: _buttonEnabled ? AppColors.primary : AppColors.textSecondary,
                                          size: 19,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                const Flexible(
                                                  child: Text(
                                                    'Interactive CTA Button',
                                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: _buttonEnabled
                                                        ? AppColors.primary.withValues(alpha: 0.12)
                                                        : AppColors.textSecondary.withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(6),
                                                  ),
                                                  child: Text(
                                                    _buttonEnabled ? 'Active' : 'Disabled',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.w700,
                                                      color: _buttonEnabled ? AppColors.primary : AppColors.textSecondary,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              _buttonEnabled
                                                  ? 'Tap-able button attached to Instagram DM'
                                                  : 'Plain text DM only (no button attached)',
                                              style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Switch(
                                        value: _buttonEnabled,
                                        activeThumbColor: AppColors.primary,
                                        onChanged: (v) => setState(() => _buttonEnabled = v),
                                      ),
                                    ],
                                  ),

                                  // If Button is Enabled: show fields & remove button
                                  if (_buttonEnabled) ...[
                                    const SizedBox(height: 12),
                                    const Divider(height: 1, color: AppColors.border),
                                    const SizedBox(height: 12),

                                    // Button Label Title & Remove Button
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text(
                                          'Button Label',
                                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                                        ),
                                        Row(
                                          children: [
                                            Text(
                                              '${_buttonTextCtrl.text.length}/20 (Meta max)',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: _buttonTextCtrl.text.length > 20
                                                    ? AppColors.error
                                                    : AppColors.textSecondary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            InkWell(
                                              onTap: () => setState(() => _buttonEnabled = false),
                                              borderRadius: BorderRadius.circular(6),
                                              child: const Padding(
                                                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.remove_circle_outline, size: 13, color: AppColors.error),
                                                    SizedBox(width: 3),
                                                    Text(
                                                      'Remove',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        color: AppColors.error,
                                                        fontWeight: FontWeight.w600,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Text on the tap-able button inside the Instagram DM:',
                                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                    ),
                                    const SizedBox(height: 8),
                                    TextField(
                                      controller: _buttonTextCtrl,
                                      maxLength: 20,
                                      onChanged: (_) => setState(() {}),
                                      style: const TextStyle(fontSize: 14),
                                      decoration: InputDecoration(
                                        prefixIcon: const Icon(Icons.touch_app_outlined, color: AppColors.primary),
                                        hintText: 'e.g. Send me the link',
                                        counterText: '',
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                        fillColor: Colors.white,
                                        filled: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                      ),
                                    ),
                                    const SizedBox(height: 14),

                                    // Website / Delivery Link
                                    const Text(
                                      'Website / Delivery Link',
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Destination URL delivered to the user:',
                                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                    ),
                                    const SizedBox(height: 8),
                                    TextField(
                                      controller: _linkCtrl,
                                      onChanged: (_) => setState(() {}),
                                      style: const TextStyle(fontSize: 14),
                                      keyboardType: TextInputType.url,
                                      decoration: InputDecoration(
                                        prefixIcon: const Icon(Icons.link, color: AppColors.primary),
                                        hintText: 'https://yourwebsite.com/offer',
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                        fillColor: Colors.white,
                                        filled: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                      ),
                                    ),
                                  ] else ...[
                                    // Button is Disabled: helper callout with Add Button action
                                    const SizedBox(height: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: AppColors.border),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.info_outline, size: 16, color: AppColors.textSecondary),
                                          const SizedBox(width: 8),
                                          const Expanded(
                                            child: Text(
                                              'No button attached. Message will be sent as a text DM.',
                                              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                            ),
                                          ),
                                          OutlinedButton.icon(
                                            onPressed: () => setState(() => _buttonEnabled = true),
                                            icon: const Icon(Icons.add, size: 14),
                                            label: const Text('Add Button', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: AppColors.primary,
                                              side: const BorderSide(color: AppColors.primary),
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              minimumSize: Size.zero,
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
                const SizedBox(height: 20),

                // DM Preview
                if (_dmEnabled) ...[
                  const Text('Instagram Direct Message Preview', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E2D), // Instagram dark DM style
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: const BoxDecoration(gradient: AppColors.primaryGradient, shape: BoxShape.circle),
                              child: const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
                            ),
                            const SizedBox(width: 8),
                            const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Your Instagram Account', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                                Text('Active now', style: TextStyle(fontSize: 10, color: Colors.white60)),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Bubble
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 280),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2E2E3E),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _openingMsgCtrl.text.isNotEmpty
                                      ? _openingMsgCtrl.text
                                      : 'Tap below to receive the link!',
                                  style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.4),
                                ),
                                if (_buttonEnabled && _buttonTextCtrl.text.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Center(
                                      child: Text(
                                        _buttonTextCtrl.text,
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        if (!_buttonEnabled) ...[
                          const SizedBox(height: 8),
                          const Row(
                            children: [
                              Icon(Icons.check_circle_outline, size: 13, color: Colors.white54),
                              SizedBox(width: 5),
                              Text(
                                'Text-only DM preview (No button attached)',
                                style: TextStyle(fontSize: 11, color: Colors.white60, fontStyle: FontStyle.italic),
                              ),
                            ],
                          ),
                        ],
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
                    label: isEditing ? 'Save & Preview' : 'Preview & Launch',
                    icon: Icons.rocket_launch,
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
