import 'package:flutter/material.dart';

import 'package:nivara_app/core/ui_theme.dart';

class _Practice {
  final IconData icon;
  final String title;
  final String subtitle;
  final String description;
  final List<String> steps;
  final String duration;

  const _Practice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.steps,
    required this.duration,
  });
}

const _practices = <_Practice>[
  _Practice(
    icon: Icons.air,
    title: 'Tactical Box Breathing',
    subtitle: 'Inhale 4s • Hold 4s • Exhale 4s • Hold 4s',
    duration: '2 min',
    description:
        'Used by operational teams to quickly down-regulate the nervous system during high-stress scenarios.',
    steps: [
      'Inhale slowly through your nose for 4 seconds.',
      'Hold your breath for 4 seconds.',
      'Exhale slowly through your mouth for 4 seconds.',
      'Hold your lungs empty for 4 seconds.',
      'Repeat sequence for 4 full cycles.',
    ],
  ),
  _Practice(
    icon: Icons.psychology,
    title: '5-4-3-2-1 Sensory Grounding',
    subtitle: 'Focus exercise for high-intensity operational stress',
    duration: '3 min',
    description:
        'Anchors awareness back to the physical environment to prevent sensory overwhelm.',
    steps: [
      'Acknowledge 5 things you can see around you.',
      'Acknowledge 4 things you can physically touch.',
      'Acknowledge 3 distinct sounds you can hear.',
      'Acknowledge 2 distinct scents or smells.',
      'Acknowledge 1 emotion or physical sensation you feel.',
    ],
  ),
  _Practice(
    icon: Icons.bedtime,
    title: 'Post-Shift Decompression',
    subtitle: 'Progressive muscle relaxation protocol',
    duration: '10 min',
    description:
        'Accelerates physical recovery and improves sleep quality after demanding shifts.',
    steps: [
      'Find a quiet space and dim all screen lighting.',
      'Tense muscle groups in your legs for 5 seconds, then fully release.',
      'Progressively move up to arms, shoulder, and facial muscles.',
      'Focus on feeling muscle tension release completely with each exhale.',
    ],
  ),
];

class CopingLibraryScreen extends StatelessWidget {
  const CopingLibraryScreen({super.key});

  void _showDetailModal(BuildContext context, _Practice p) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: NivaraColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: NivaraColors.accentSoft,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(p.icon, size: 24, color: NivaraColors.accent),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      p.title,
                      style: TextStyle(
                          color: NivaraColors.textHi,
                          fontSize: 18,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: NivaraColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(NivaraRadius.pill),
                    ),
                    child: Text(p.duration,
                        style: TextStyle(
                            color: NivaraColors.textMid,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              SizedBox(height: 12),
              Text(
                p.description,
                style: TextStyle(
                    color: NivaraColors.textMid, fontSize: 13.5, height: 1.45),
              ),
              Divider(height: 28),
              Text(
                'Tactical Steps:',
                style: TextStyle(
                    color: NivaraColors.textHi,
                    fontWeight: FontWeight.w800,
                    fontSize: 15),
              ),
              const SizedBox(height: 12),
              ...p.steps.asMap().entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: NivaraColors.accentSoft,
                            shape: BoxShape.circle,
                          ),
                          child: Text('${e.key + 1}',
                              style: TextStyle(
                                  color: NivaraColors.accent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800)),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                            child: Text(e.value,
                                style: TextStyle(
                                    color: NivaraColors.textHi, fontSize: 14, height: 1.4))),
                      ],
                    ),
                  )),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close Practice'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      appBar: AppBar(title: Text('Tactical Coping Library')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Text(
            'Field-proven down-regulation drills. Work through one when the '
            'index runs high — no connection needed.',
            style: TextStyle(
                color: NivaraColors.textMid, fontSize: 12.5, height: 1.45),
          ),
          SizedBox(height: 14),
          ..._practices.map((p) => Container(
                margin: EdgeInsets.only(bottom: 10),
                child: Material(
                  color: NivaraColors.surface,
                  borderRadius: BorderRadius.circular(NivaraRadius.card),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(NivaraRadius.card),
                    onTap: () => _showDetailModal(context, p),
                    child: Container(
                      padding: EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(NivaraRadius.card),
                        border: Border.all(color: NivaraColors.outline),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: NivaraColors.accentSoft,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(p.icon, size: 26, color: NivaraColors.accent),
                          ),
                          SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(p.title,
                                    style: TextStyle(
                                        color: NivaraColors.textHi,
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w700)),
                                SizedBox(height: 3),
                                Text(p.subtitle,
                                    style: TextStyle(
                                        color: NivaraColors.textMid,
                                        fontSize: 11.5,
                                        height: 1.3)),
                              ],
                            ),
                          ),
                          SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(p.duration,
                                  style: TextStyle(
                                      color: NivaraColors.accent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700)),
                              SizedBox(height: 4),
                              Icon(Icons.chevron_right,
                                  size: 18, color: NivaraColors.textLow),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }
}
