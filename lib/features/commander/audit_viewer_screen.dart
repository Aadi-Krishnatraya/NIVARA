import 'package:flutter/material.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/ui_theme.dart';

/// Read-only view of the append-only audit trail (PRD §3.3). Every query,
/// view, and blocked access on the command portal is recorded here.
class AuditViewerScreen extends StatelessWidget {
  const AuditViewerScreen({super.key});

  Color _actionColor(String action) {
    if (action.contains('BLOCKED') || action.contains('FAIL')) {
      return NivaraColors.danger;
    }
    if (action == 'UNIT_VIEW') return NivaraColors.warn;
    return NivaraColors.accent;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      appBar: AppBar(
        title: const Text('Immutable Audit Trail'),
      ),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: DatabaseHelper.instance.getAuditLog(limit: 200),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: NivaraColors.accent));
          }
          final entries = snap.data!;
          if (entries.isEmpty) {
            return Center(
              child: Text('No entries yet.',
                  style: TextStyle(color: NivaraColors.textLow)),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final e = entries[i];
              final action = (e['action'] ?? '') as String;
              final ts = DateTime.tryParse((e['timestamp'] ?? '') as String);
              final tsText = ts == null
                  ? ''
                  : '${ts.day}/${ts.month} ${ts.hour.toString().padLeft(2, '0')}:'
                      '${ts.minute.toString().padLeft(2, '0')}:'
                      '${ts.second.toString().padLeft(2, '0')}';
              final color = _actionColor(action);
              return Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: NivaraColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: NivaraColors.outline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(action,
                              style: TextStyle(
                                  color: color,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4)),
                        ),
                        Spacer(),
                        Text(tsText,
                            style: TextStyle(
                                color: NivaraColors.textLow, fontSize: 11)),
                      ],
                    ),
                    SizedBox(height: 7),
                    Text((e['detail'] ?? '') as String,
                        style: TextStyle(
                            color: NivaraColors.textHi,
                            fontSize: 12.5,
                            height: 1.4)),
                    SizedBox(height: 3),
                    Text('actor: ${e['actor_id']}',
                        style: TextStyle(
                            color: NivaraColors.textLow, fontSize: 10.5)),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
