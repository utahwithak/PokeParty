#!/usr/bin/env python3
"""Behavioral-cloning trainer for the shield policy (RL milestone 1).

Learns to imitate the ShieldSearch oracle from the JSONL dataset produced by
rl/generate. The network is deliberately tiny (24 -> 64 -> 64 -> 1 MLP); it is
trained here in plain numpy (Adam + binary cross-entropy) and exported as raw
weights JSON for a hand-rolled Swift forward pass (no Core ML dependency).

Split discipline: train/validation are split by MATCHUP KEY (species pair), so
every decision from a held-out matchup is unseen — accuracy measures
generalization to new matchups, not memorization of replayed battles.

Usage: venv/bin/python train_shield.py [data/shield_dataset.jsonl]
Writes: data/shield_policy.json (weights + feature names + val metrics)
"""

import json
import sys
import zlib
from pathlib import Path

import numpy as np

DATA = Path(sys.argv[1] if len(sys.argv) > 1 else "data/shield_dataset.jsonl")
META = DATA.parent / "shield_meta.json"
OUT = DATA.parent / "shield_policy.json"

HIDDEN = 64
EPOCHS = 30
BATCH = 4096
LR = 1e-3
VAL_FRACTION = 10  # 1-in-10 matchups held out
SEED = 7

rng = np.random.default_rng(SEED)

# ---------------------------------------------------------------- data

meta = json.loads(META.read_text())
names = meta["featureNames"]

xs, ys, keys = [], [], []
with DATA.open() as f:
    for line in f:
        r = json.loads(line)
        xs.append(r["x"])
        ys.append(r["y"])
        keys.append(r["m"])

X = np.asarray(xs, dtype=np.float32)
y = np.asarray(ys, dtype=np.float32)
assert X.shape[1] == len(names), "feature count mismatch with shield_meta.json"

# Deterministic split by matchup key: hash the species pair, hold out 1 in N.
val_mask = np.asarray(
    [zlib.crc32(k.encode()) % VAL_FRACTION == 0 for k in keys], dtype=bool
)
Xtr, ytr = X[~val_mask], y[~val_mask]
Xva, yva = X[val_mask], y[val_mask]
print(f"{len(Xtr)} train / {len(Xva)} val samples "
      f"({len(set(keys))} matchups, {X.shape[1]} features)")
print(f"train shield rate {ytr.mean():.3f}, val shield rate {yva.mean():.3f}")

# Class imbalance (~75/25): weight the rare no-shield class up so the net
# can't cheat by always shielding.
pos_weight = (1 - ytr.mean()) / ytr.mean()

# ---------------------------------------------------------------- model

def init_layer(fan_in, fan_out):
    w = rng.normal(0, np.sqrt(2 / fan_in), (fan_in, fan_out)).astype(np.float32)
    return w, np.zeros(fan_out, dtype=np.float32)

W1, b1 = init_layer(X.shape[1], HIDDEN)
W2, b2 = init_layer(HIDDEN, HIDDEN)
W3, b3 = init_layer(HIDDEN, 1)
params = [W1, b1, W2, b2, W3, b3]

def forward(x):
    h1 = np.maximum(x @ W1 + b1, 0)
    h2 = np.maximum(h1 @ W2 + b2, 0)
    logit = (h2 @ W3 + b3).squeeze(-1)
    return h1, h2, logit

def bce_grads(x, target):
    h1, h2, logit = forward(x)
    p = 1 / (1 + np.exp(-logit))
    # Per-sample weight: shield examples get pos_weight (<1 here, since shield
    # is the majority class), no-shield examples weight 1.
    w = np.where(target == 1, pos_weight, 1.0).astype(np.float32)
    w /= w.mean()
    dlogit = (w * (p - target))[:, None] / len(x)
    gW3 = h2.T @ dlogit
    gb3 = dlogit.sum(0)
    dh2 = (dlogit @ W3.T) * (h2 > 0)
    gW2 = h1.T @ dh2
    gb2 = dh2.sum(0)
    dh1 = (dh2 @ W2.T) * (h1 > 0)
    gW1 = x.T @ dh1
    gb1 = dh1.sum(0)
    loss = -(w * (target * np.log(p + 1e-7) + (1 - target) * np.log(1 - p + 1e-7))).mean()
    return loss, [gW1, gb1, gW2, gb2, gW3, gb3]

# Adam
m = [np.zeros_like(p) for p in params]
v = [np.zeros_like(p) for p in params]
beta1, beta2, eps, t = 0.9, 0.999, 1e-8, 0

def metrics(x, target):
    _, _, logit = forward(x)
    pred = (logit > 0).astype(np.float32)
    acc = (pred == target).mean()
    shield_recall = pred[target == 1].mean() if (target == 1).any() else float("nan")
    noshield_recall = (1 - pred[target == 0]).mean() if (target == 0).any() else float("nan")
    return acc, shield_recall, noshield_recall

# ---------------------------------------------------------------- train

# Export the epoch with the best val accuracy, not whatever the last epoch
# happens to be (the tail of training visibly oscillates).
best_acc = -1.0
best_params = None

for epoch in range(1, EPOCHS + 1):
    order = rng.permutation(len(Xtr))
    total = 0.0
    for s in range(0, len(order), BATCH):
        idx = order[s:s + BATCH]
        loss, grads = bce_grads(Xtr[idx], ytr[idx])
        total += loss * len(idx)
        t += 1
        for i, (p, g) in enumerate(zip(params, grads)):
            m[i] = beta1 * m[i] + (1 - beta1) * g
            v[i] = beta2 * v[i] + (1 - beta2) * g * g
            p -= LR * (m[i] / (1 - beta1**t)) / (np.sqrt(v[i] / (1 - beta2**t)) + eps)
    acc, sr, nr = metrics(Xva, yva)
    if acc > best_acc:
        best_acc = acc
        best_params = [p.copy() for p in params]
    if epoch % 5 == 0 or epoch == 1:
        print(f"epoch {epoch:3d}  loss {total / len(Xtr):.4f}  "
              f"val acc {acc:.4f}  shield recall {sr:.4f}  no-shield recall {nr:.4f}")

W1, b1, W2, b2, W3, b3 = best_params
acc, sr, nr = metrics(Xva, yva)
tr_acc, _, _ = metrics(Xtr, ytr)
print(f"\nfinal: train acc {tr_acc:.4f} | val acc {acc:.4f} "
      f"(shield recall {sr:.4f}, no-shield recall {nr:.4f})")

# ---------------------------------------------------------------- export

out = {
    "featureNames": names,
    "hidden": HIDDEN,
    "valAccuracy": round(float(acc), 4),
    "W1": W1.tolist(), "b1": b1.tolist(),
    "W2": W2.tolist(), "b2": b2.tolist(),
    "W3": W3.squeeze(-1).tolist(), "b3": float(b3[0]),
}
OUT.write_text(json.dumps(out))
print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB)")
