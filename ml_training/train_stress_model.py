#!/usr/bin/env python3
"""NIVARA on-device stress model — training + TFLite export pipeline.

Stage 1 (pre-deployment base training, PRD section 7):
  * Generates a synthetic operational dataset (SDV-style: statistical shapes
    sampled per soldier archetype, no real personnel data).
  * Ground-truth labels encode welfare heuristics from psychometric practice:
    sleep-debt curves, mood deficit weight, operational strain accumulators
    (consecutive night patrols, deployment duration, cancelled leaves),
    plus interaction terms. A small amount of label noise mimics human
    reporting variance.
  * Trains a compact MLP regressor (output 0-100 stress index).
  * Validates MAE / band accuracy against the heuristic baseline.
  * Exports a FULL-INT8 quantized TFLite model (CPU-only edge inference).

Output: assets/models/stress_model.tflite (+ metadata printed to stdout).
"""
import json
import os
import numpy as np
import tensorflow as tf

RNG = np.random.default_rng(26186)
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "models")
os.makedirs(OUT_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# 1. Synthetic operational dataset (SDV-style archetype sampling)
# ---------------------------------------------------------------------------
ARCHETYPES = {
    #                     mood_mu  sleep_mu  readiness  night_prob  deploy  leaves
    "resilient":        (4.2,      7.4,      4.0,       0.15,       40,     0.05),
    "average":          (3.4,      6.8,      3.2,       0.30,       90,     0.15),
    "sleep_deprived":   (2.7,      4.6,      2.6,       0.55,       120,    0.30),
    "burnout_risk":     (2.1,      4.0,      2.0,       0.75,       180,    0.55),
    "deployment_worn":  (2.5,      5.2,      2.4,       0.45,       270,    0.35),
}

N_SOLDIERS = 1200
DAYS = 14
NOISE_STD = 4.0


def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def generate_dataset():
    rows, labels = [], []
    names = list(ARCHETYPES)
    probs = [0.30, 0.35, 0.18, 0.09, 0.08]

    for _ in range(N_SOLDIERS):
        arch = RNG.choice(names, p=probs)
        mood_mu, sleep_mu, ready_mu, night_p, deploy_mu, cancel_p = ARCHETYPES[arch]
        night_streak = 0
        for _ in range(DAYS):
            night = RNG.random() < night_p
            night_streak = night_streak + 1 if night else 0

            mood = float(np.clip(RNG.normal(mood_mu, 0.55), 1, 5))
            sleep = float(np.clip(RNG.normal(sleep_mu, 1.0), 0, 12))
            readiness = float(np.clip(RNG.normal(ready_mu, 0.6), 1, 5))
            deploy_days = int(np.clip(RNG.normal(deploy_mu, 45), 1, 365))
            cancelled = float(RNG.random() < cancel_p)

            # Welfare-heuristic ground truth (psychometric practice):
            label = (
                (5.0 - mood) * 11.0                       # mood deficit weight
                + min(max(8.0 - sleep, 0), 8.0) * 3.6     # sleep-debt curve
                + (5.0 - readiness) * 7.0                 # physical capacity
                + 6.0 * sigmoid((night_streak - 3) * 0.9) # strain accumulator
                + 4.5 * sigmoid((deploy_days - 120) / 60) # deployment duration
                + 3.5 * cancelled
                + RNG.normal(0, NOISE_STD)                # human variance
            )
            rows.append([mood, sleep, readiness, night_streak, deploy_days, cancelled])
            labels.append(float(np.clip(label, 0, 100)))
    return np.array(rows, np.float32), np.array(labels, np.float32)


X, y = generate_dataset()
split = int(0.9 * len(X))
X_tr, X_va, y_tr, y_va = X[:split], X[split:], y[:split], y[split:]

# Feature normalization stats (baked into the exported graph).
FEATURE_MIN = X_tr.min(axis=0)
FEATURE_MAX = X_tr.max(axis=0)
SPAN = np.maximum(FEATURE_MAX - FEATURE_MIN, 1e-6)


# ---------------------------------------------------------------------------
# 2. Model: normalization inside the graph -> raw inputs at the edge
# ---------------------------------------------------------------------------
norm = tf.keras.layers.Normalization(axis=-1)
norm.adapt(X_tr)

model = tf.keras.Sequential(
    [
        tf.keras.Input(shape=(6,)),
        norm,
        tf.keras.layers.Dense(24, activation="relu"),
        tf.keras.layers.Dense(16, activation="relu"),
        tf.keras.layers.Dense(1, activation="linear"),
    ],
    name="nivara_stress_net",
)
model.compile(optimizer=tf.keras.optimizers.Adam(1e-2), loss="mae", metrics=["mae"])
model.fit(
    X_tr, y_tr,
    validation_data=(X_va, y_va),
    epochs=120,
    batch_size=128,
    verbose=0,
    callbacks=[tf.keras.callbacks.EarlyStopping(patience=20, restore_best_weights=True)],
)


# ---------------------------------------------------------------------------
# 3. Validation: NN vs heuristic baseline
# ---------------------------------------------------------------------------
def heuristic_baseline(x):
    mood, sleep, ready, streak, deploy, cancelled = x.T
    return np.clip(
        (5.0 - mood) * 12.0
        + np.minimum(np.maximum(8.0 - sleep, 0), 8.0) * 4.5
        + (5.0 - ready) * 8.0,
        0, 100,
    )


nn_pred = model.predict(X_va, verbose=0).ravel()
heu_pred = heuristic_baseline(X_va)
nn_mae = float(np.abs(nn_pred - y_va).mean())
heu_mae = float(np.abs(heu_pred - y_va).mean())


def band_accuracy(pred):
    true_band = np.select([y_va >= 67, y_va >= 34], [2, 1], default=0)
    pred_band = np.select([pred >= 67, pred >= 34], [2, 1], default=0)
    return float((true_band == pred_band).mean())


print(f"NN      MAE {nn_mae:6.2f}  band-acc {band_accuracy(nn_pred)*100:5.1f}%")
print(f"Heuristic MAE {heu_mae:6.2f}  band-acc {band_accuracy(heu_pred)*100:5.1f}%")


# ---------------------------------------------------------------------------
# 4. Full-int8 quantized TFLite export (CPU edge inference)
# ---------------------------------------------------------------------------
@tf.function(
    input_signature=[tf.TensorSpec([None, 6], tf.float32, name="features")]
)
def serving_fn(x):
    # Dynamic batch: the edge engine evaluates one check-in at a time AND
    # whole Shapley-coalition batches (64 rows) in a single inference call.
    return {"stress_index": model(x)}


concrete = serving_fn.get_concrete_function()

converter = tf.lite.TFLiteConverter.from_concrete_functions([concrete])
converter.optimizations = [tf.lite.Optimize.DEFAULT]
converter.representative_dataset = lambda: (
    [np.reshape(row, [1, 6]).astype(np.float32)] for row in X_tr[:500]
)
converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
converter.inference_input_type = tf.int8
converter.inference_output_type = tf.int8
tflite_model = converter.convert()

out_path = os.path.join(OUT_DIR, "stress_model.tflite")
with open(out_path, "wb") as f:
    f.write(tflite_model)

# ---------------------------------------------------------------------------
# 5. Explainability metadata (feeds on-device exact Shapley attribution)
# ---------------------------------------------------------------------------
# The Dart engine explains every prediction with EXACT Shapley values over
# all 2^6 coalitions. Coalitions replace a feature with a neutral reference
# point (the dataset median soldier) — exported here so edge and training
# distributions stay aligned.
reference_point = np.median(X_tr, axis=0).astype(np.float32)
reference_score = float(model.predict(reference_point.reshape(1, -1), verbose=0).ravel()[0])

with open(os.path.join(OUT_DIR, "model_meta.json"), "w") as f:
    json.dump(
        {
            "features": [
                "mood_1to5", "sleep_hours", "readiness_1to5",
                "night_patrol_streak", "deployment_days", "cancelled_leaves_flag",
            ],
            "output": "stress_index_0_100",
            "quantization": "full-int8",
            "val_mae": round(nn_mae, 3),
            "val_band_accuracy": round(band_accuracy(nn_pred), 4),
            "trained_on": "synthetic operational dataset (archetype sampling, n=%d)" % len(X),
            "framework": "tensorflow %s" % tf.__version__,
            "explainability": {
                "method": "exact_shapley_all_coalitions",
                "reference_point": [round(float(v), 4) for v in reference_point],
                "reference_score": round(reference_score, 3),
                "feature_min": [round(float(v), 4) for v in FEATURE_MIN],
                "feature_max": [round(float(v), 4) for v in FEATURE_MAX],
            },
            "trained_at": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
        },
        f,
        indent=2,
    )

print(f"wrote {out_path} ({len(tflite_model)/1024:.1f} KB)")
print(f"reference point: {reference_point.tolist()}")
print(f"reference score : {reference_score:.2f}")
