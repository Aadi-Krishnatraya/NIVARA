# NIVARA — Preventive Welfare Engine (PRD 26186)

Team Astravore — *Build with Bharat 2.0* hackathon build.

Offline-first Flutter app implementing the **Confidential Troop Portal** and the
**Command Action Portal** from the Project 26186 PRD: proactive stress/burnout
prevention for uniformed personnel, with privacy enforced by design.

**Every intelligence runs on-device (Edge AI), every explanation is real
game-theoretic XAI, and nothing is hardcoded — no seed users, no fixed PINs,
no canned scores.**

---

## Edge AI — a real model, on the phone

| | |
|---|---|
| Model | 6→24→12→1 MLP, **int8-quantized TFLite**, **4.4 KB** in the APK |
| Training | `ml_training/train_stress_model.py` (TensorFlow 2.20) on a synthetic SDV-style operational dataset — no real personnel data |
| Inputs | mood, sleep hours, self-readiness, night-patrol streak, deployment days, cancelled-leave flag |
| Accuracy | **MAE 3.18** vs 3.90 for the heuristic baseline · **91.1%** severity-band accuracy |
| Runtime | `tflite_flutter` **isolate interpreter** — inference + full Shapley analysis off the UI thread, zero network |

Retrain any time: `python3 ml_training/train_stress_model.py` regenerates
`assets/models/stress_model.tflite` + `model_meta.json` (feature reference
point for the XAI baseline is exported with the model).

## XAI — exact Shapley values, not heuristics

`lib/core/shapley.dart` computes **exact Shapley attributions** (game-theoretic,
additive decomposition of the score into per-feature contributions) by
evaluating **all 2⁶ = 64 coalitions** of the 6-feature model in a *single
batched TFLite call* — milliseconds on-device.

* **Soldier check-in** shows per-feature contribution bars: *"Why this score"*
  explains the number the model just produced.
* **Commander dashboard** pools soldiers' own attributions (anonymized) into
  ranked **Explainable Risk Drivers** and an **Automated Action Playbook** whose
  recommendation follows the data.
* **Trends** shows the top model-explained driver behind each historical entry.
* Correctness is **unit-tested against the linear-model closed form**
  (`φᵢ = wᵢ·(xᵢ − refᵢ)`) — see `test/widget_test.dart`.

## What is implemented (PRD mapping)

| PRD section | Feature | Where |
|---|---|---|
| §3.1 | 15-second check-in (mood / sleep / readiness + operational context) | `features/checkin/` |
| §3.1 | On-device Edge-AI stress index (0–100 + LOW/MODERATE/HIGH band) | `core/ml_engine.dart` |
| §3.1 | Real-time per-feature XAI contribution bars | `core/shapley.dart` |
| §3.1 | Offline coping library (box breathing, grounding, decompression) | `features/coping/` |
| §3.1 | Confidential support bridge (zero-trace directory + tap-to-call) | `features/support/` |
| §4 / §6 | SQLCipher AES-256 encrypted local vault, fully offline | `core/database_helper.dart` |
| §5.1 | Salted SHA-256 credential gateway (per-user salt) | `core/auth_service.dart` |
| §5.2 | Squad threshold: aggregates hard-blocked under 5 contributors | `DatabaseHelper.squadPrivacyThreshold` |
| §5.2 | Laplace differential noise on all command aggregates (ε = 1.5) | `DatabaseHelper.differentiallyPrivateAverage` |
| §3.2 | Pooled Shapley risk drivers + data-driven action playbook | `commander_screen.dart` |
| §3.3 | Append-only audit trail of every command view / blocked view | `audit_log` table |
| §1 | Personal trends visible only to the owning soldier | `features/analytics/` |
| §6 | 2-soldier observation-post edge case (privacy block demo) | `commander_screen.dart` |

## Architecture

```
nivara_app/
├── assets/models/             # int8 TFLite model + SHAP reference metadata
├── ml_training/
│   └── train_stress_model.py  # TF training pipeline: data gen → train →
│                              #   beat-heuristic check → int8 export + metadata
├── e2e_demo.py                # full adb/uiautomator demo driver (see below)
└── lib/
    ├── main.dart              # bootstrap: engine load, soldier shell (4 tabs)
    ├── core/
    │   ├── ml_engine.dart     # TFLite inference + one-batch exact Shapley
    │   ├── shapley.dart       # pure-Dart exact Shapley (64 coalitions)
    │   ├── auth_service.dart  # salted SHA-256 credential hashing
    │   ├── database_helper.dart # SQLCipher vault v4 (users, check-ins+attributions, audit)
    │   ├── ui_theme.dart      # NIVARA design system (tactical dark, teal)
    │   └── user_session.dart  # RBAC session (soldier/commander)
    └── features/
        ├── auth/              # registration + PIN login (created through UI)
        ├── checkin/           # 15-second check-in + live XAI panel
        ├── analytics/         # personal stress trends + per-entry drivers
        ├── commander/         # anonymized unit dashboard (DP + Shapley + playbook)
        ├── coping/            # offline coping library
        └── support/           # confidential support bridge (tap-to-call)
```

## No hardcoding — the demo path

Accounts are created **through the registration UI** on first run; the per-device
DB key is generated at first boot; every stress score is produced by the model;
every explanation is computed from the model's own coalitions. To present:

1. **Register a soldier** (any name / unit / 4-digit PIN of your choosing) → land in Soldier View.
2. **Check-in** → set sliders + operational context → **Run evaluation** → the
   Edge-AI index appears in ~50–80 ms with per-feature Shapley bars → **Log this check-in**.
3. **Trends** → your history with the top explained driver per entry.
4. **Support Bridge** → editable zero-trace directory; contacts place real calls.
5. **Log out → register a Commander** for the same unit. With < 5 contributors the
   dashboard is **hard-blocked** (PRD §5.2) and the block is audited.
6. Register / log 5+ soldiers into the unit, log in as commander → aggregate
   dashboard: DP-noised average, 7-day trend, **pooled Shapley drivers**,
   playbook, audit trail.

## Automated end-to-end verification

`e2e_demo.py` drives a real device/emulator over adb through the *entire* demo
path above — 6 real registrations through the UI, Edge-AI check-ins, trends,
support CRUD, privacy block, aggregate + Shapley dashboard, audit trail — and
asserts every screen. Run it with a device attached:

```bash
python3 e2e_demo.py
```

`flutter analyze` is clean and `flutter test` covers the Shapley math
(closed-form verification), severity bands, and the app boot shell.

## Running

```bash
flutter pub get
flutter run            # or: flutter build apk --release
```

PRD non-functional targets: APK ≤ 25 MB ✓ (model adds 4.4 KB), inference well
under the 150 MB RAM budget (isolate + int8), 100% offline operation ✓.

## Privacy model

- Raw check-ins (mood/sleep/readiness/stress) are **never** visible to commanders;
  the commander dashboard can only query aggregate SQL over the vault.
- Small units (fewer than 5 active contributors) are **hard-blocked** at the UI
  with the PRD §6 message, and the blocked attempt is audited.
- Every displayed aggregate carries Laplace noise (ε = 1.5) so precise
  triangulation is mathematically infeasible.
- Shapley attributions are pooled **without identity** — the commander sees
  which stressors drive the unit, never which soldier.
- The audit log has no update or delete code path.

## Roadmap alignment

- **Phase 1 (done):** MVP core — Flutter UI, SQLCipher, stress engine, command
  dashboard with DP guardrails.
- **Phase 2 (done in this build):** real int8 TFLite model, exact Shapley XAI,
  salted SHA-256 gateway, operational-context ingestion, tap-to-call bridge.
- **Phase 3 (next):** Flower federated learning across devices, hardware
  keystore salt storage.
