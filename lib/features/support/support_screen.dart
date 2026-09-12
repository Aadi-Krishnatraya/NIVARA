import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/ui_theme.dart';

/// Confidential Support Bridge (PRD §3.1). The directory lives in the
/// encrypted local vault and is fully editable — welfare officers or units
/// maintain their own real numbers; nothing is hardcoded.
class ConfidentialSupportScreen extends StatelessWidget {
  const ConfidentialSupportScreen({super.key});

  Future<void> _showContactForm(BuildContext context, {Map<String, Object?>? existing}) async {
    final nameCtrl = TextEditingController(text: existing?['name'] as String? ?? '');
    final phoneCtrl = TextEditingController(text: existing?['phone'] as String? ?? '');
    var category = (existing?['category'] as String?) ?? 'peer';
    final id = existing?['id'] as int?;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: NivaraColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 20, 24, 24 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(id == null ? 'Add contact' : 'Edit contact',
                  style: TextStyle(
                      color: NivaraColors.textHi,
                      fontSize: 17,
                      fontWeight: FontWeight.w800)),
              SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                style: TextStyle(color: NivaraColors.textHi),
                decoration: InputDecoration(
                  labelText: 'Contact name',
                  prefixIcon: Icon(Icons.person_outline, size: 20, color: NivaraColors.accent),
                ),
              ),
              SizedBox(height: 12),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: NivaraColors.textHi),
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  prefixIcon: Icon(Icons.call_outlined, size: 20, color: NivaraColors.accent),
                ),
              ),
              const SizedBox(height: 14),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'peer', label: Text('Peer'), icon: Icon(Icons.headset_mic_outlined, size: 16)),
                  ButtonSegment(value: 'medical', label: Text('Medical'), icon: Icon(Icons.local_hospital_outlined, size: 16)),
                  ButtonSegment(value: 'family', label: Text('Family'), icon: Icon(Icons.family_restroom_outlined, size: 16)),
                ],
                selected: {category},
                onSelectionChanged: (s) => setSheet(() => category = s.first),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        if (nameCtrl.text.trim().isEmpty || phoneCtrl.text.trim().isEmpty) {
                          return;
                        }
                        await DatabaseHelper.instance.upsertContact(
                          id: id,
                          name: nameCtrl.text,
                          phone: phoneCtrl.text,
                          category: category,
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, int id, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NivaraColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete $name?',
            style: TextStyle(color: NivaraColors.textHi, fontSize: 17)),
        content: Text(
            'This removes the contact from the local encrypted directory.',
            style: TextStyle(color: NivaraColors.textMid, fontSize: 13, height: 1.4)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: NivaraColors.textMid))),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: NivaraColors.danger,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 18)),
            onPressed: () async {
              await DatabaseHelper.instance.deleteContact(id);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// PRD §3.1: the bridge must be actionable — tapping a contact dials it
  /// (opens the dialer pre-filled; the soldier confirms the call).
  Future<void> _callContact(BuildContext context, String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This contact has no dialable number.')),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: digits);
    final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the dialer for $digits.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      appBar: AppBar(title: const Text('Confidential Support Bridge')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: NivaraColors.accent,
        foregroundColor: const Color(0xFF04211D),
        elevation: 0,
        onPressed: () => _showContactForm(context),
        icon: const Icon(Icons.person_add_alt, size: 20),
        label: const Text('Add',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: DatabaseHelper.instance.getContacts(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: NivaraColors.accent));
          }
          final contacts = snap.data!;
          if (contacts.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: NivaraColors.surfaceAlt,
                      border: Border.all(color: NivaraColors.outline),
                    ),
                    child: Icon(Icons.contact_phone_outlined,
                        size: 40, color: NivaraColors.textLow),
                  ),
                  SizedBox(height: 18),
                  Text('Directory is empty.',
                      style: TextStyle(
                          color: NivaraColors.textHi,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  SizedBox(height: 8),
                  Text(
                    'Add your unit\'s confidential helplines.\nThey stay in the encrypted vault.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: NivaraColors.textMid, fontSize: 12.5, height: 1.45),
                  ),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
            children: [
              Container(
                padding: EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: NivaraColors.good.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: NivaraColors.good.withValues(alpha: 0.25)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.verified_user_outlined, color: NivaraColors.good, size: 22),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Zero-trace local directory. Contacts are stored only in '
                        'this device\'s encrypted vault — viewable by you alone.',
                        style: TextStyle(
                            fontSize: 12,
                            color: NivaraColors.textMid,
                            height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ...contacts.map((c) {
                final id = c['id'] as int;
                final name = c['name'] as String;
                final phone = c['phone'] as String;
                final category = c['category'] as String;
                final (icon, tag, tint) = switch (category) {
                  'medical' => (Icons.local_hospital_outlined, 'MEDICAL', NivaraColors.danger),
                  'family' => (Icons.family_restroom_outlined, 'FAMILY', NivaraColors.info),
                  _ => (Icons.headset_mic_outlined, 'PEER', NivaraColors.accent),
                };
                return Container(
                  margin: EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: NivaraColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: NivaraColors.outline),
                  ),
                  child: ListTile(
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    leading: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: tint.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: tint, size: 22),
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(name,
                              style: TextStyle(
                                  color: NivaraColors.textHi,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: tint.withValues(alpha: 0.12),
                            borderRadius:
                                BorderRadius.circular(NivaraRadius.pill),
                          ),
                          child: Text(tag,
                              style: TextStyle(
                                  color: tint,
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.6)),
                        ),
                      ],
                    ),
                    subtitle: Text(phone,
                        style: TextStyle(
                            color: NivaraColors.textMid, fontSize: 12.5)),
                    onTap: () => _callContact(context, phone),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.call, color: NivaraColors.accent),
                          tooltip: 'Call $name',
                          onPressed: () => _callContact(context, phone),
                        ),
                        PopupMenuButton<String>(
                          color: NivaraColors.surfaceAlt,
                          iconColor: NivaraColors.textLow,
                          onSelected: (action) {
                            if (action == 'edit') {
                              _showContactForm(context, existing: c);
                            } else if (action == 'delete') {
                              _confirmDelete(context, id, name);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
