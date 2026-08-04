#!/usr/bin/env python3
"""Trainer for the 3v3 switch policy (RL milestone 2).

Imitates the rollout-search teacher from rl/generate --switch-gen: a tiny MLP
(features -> 64 -> 64 -> 3 action logits) trained with softmax cross-entropy.
Illegal actions are masked to -inf at evaluation; labels are always legal.

Split discipline: train/validation split by GAME KEY (team pair), matching the
--switch-eval holdout (crc32(key) % 10 == 0).

Usage: venv/bin/python train_switch.py [data/switch_dataset.jsonl]
Writes: data/switch_policy.json
"""

import json
import sys
import zlib
from pathlib import Path

import numpy as np

DATA = Path(sys.argv[1] if len(sys.argv) > 1 else "data/switch_dataset.jsonl")
META = DATA.parent / "switch_meta.json"
OUT = DATA.parent / "switch_policy.json"

HIDDEN = 64
ACTIONS = 3
EPOCHS = 40
BATCH = 4096
LR = 1e-3
SEED = 7

rng = np.random.default_rng(SEED)

# ---------------------------------------------------------------- data

meta = json.loads(META.read_text())
names = meta["featureNames"]

xs, ys, masks, vals, keys = [], [], [], [], []
with DATA.open() as f:
    for line in f:
        r = json.loads(line)
        xs.append(r["x"])
        ys.append(r["y"])
        m = np.zeros(ACTIONS, dtype=np.float32)
        m[r["legal"]] = 1
        masks.append(m)
        # Rollout value of every action (illegal = very poor), for regret metrics
        # and decision-importance weighting.
        v = np.full(ACTIONS, -1e9, dtype=np.float32)
        for a, val in zip(r["legal"], r["v"]):
            v[a] = val
        vals.append(v)
        keys.append(r["g"])

X = np.asarray(xs, dtype=np.float32)
y = np.asarray(ys, dtype=np.int64)
M = np.asarray(masks, dtype=np.float32)   # 1 = legal
V = np.asarray(vals, dtype=np.float32)    # rollout value per action
assert X.shape[1] == len(names), "feature count mismatch with switch_meta.json"

# Decision importance: how much rating the best action gains over the runner-up.
# Near-ties get almost no weight — being "wrong" there costs nothing.
sortedV = np.sort(np.where(M > 0, V, -np.inf), axis=1)
margin = (sortedV[:, -1] - sortedV[:, -2]) / 1000.0
weight = np.clip(margin, 0.005, 1.0).astype(np.float32)

val_mask = np.asarray([zlib.crc32(k.encode()) % 10 == 0 for k in keys], dtype=bool)
Xtr, ytr, Mtr, Wtr = X[~val_mask], y[~val_mask], M[~val_mask], weight[~val_mask]
Xva, yva, Mva, Vva = X[val_mask], y[val_mask], M[val_mask], V[val_mask]
print(f"{len(Xtr)} train / {len(Xva)} val samples "
      f"({len(set(keys))} games, {X.shape[1]} features)")

counts = np.bincount(ytr, minlength=ACTIONS).astype(np.float64)
print(f"label counts (train): stay {counts[0]:.0f}, backup1 {counts[1]:.0f}, backup2 {counts[2]:.0f}")
print(f"decisions with real stakes (margin > 25 rating): {(margin > 0.025).mean():.1%}")

# ---------------------------------------------------------------- model

def init_layer(fan_in, fan_out):
    w = rng.normal(0, np.sqrt(2 / fan_in), (fan_in, fan_out)).astype(np.float32)
    return w, np.zeros(fan_out, dtype=np.float32)

W1, b1 = init_layer(X.shape[1], HIDDEN)
W2, b2 = init_layer(HIDDEN, HIDDEN)
W3, b3 = init_layer(HIDDEN, ACTIONS)
params = [W1, b1, W2, b2, W3, b3]

def forward(x):
    h1 = np.maximum(x @ W1 + b1, 0)
    h2 = np.maximum(h1 @ W2 + b2, 0)
    return h1, h2, h2 @ W3 + b3

def ce_grads(x, target, mask, w):
    h1, h2, z = forward(x)
    z = np.where(mask > 0, z, -1e9)           # illegal actions can't take probability
    z -= z.max(axis=1, keepdims=True)
    e = np.exp(z)
    p = e / e.sum(axis=1, keepdims=True)
    w = w / w.mean()
    onehot = np.eye(ACTIONS, dtype=np.float32)[target]
    dz = (p - onehot) * w[:, None] / len(x)
    gW3 = h2.T @ dz
    gb3 = dz.sum(0)
    dh2 = (dz @ W3.T) * (h2 > 0)
    gW2 = h1.T @ dh2
    gb2 = dh2.sum(0)
    dh1 = (dh2 @ W2.T) * (h1 > 0)
    gW1 = x.T @ dh1
    gb1 = dh1.sum(0)
    loss = -(w * np.log(p[np.arange(len(x)), target] + 1e-9)).mean()
    return loss, [gW1, gb1, gW2, gb2, gW3, gb3]

m = [np.zeros_like(p) for p in params]
v = [np.zeros_like(p) for p in params]
beta1, beta2, eps, t = 0.9, 0.999, 1e-8, 0

def metrics(x, target, mask, values):
    """Regret = rating the policy leaves on the table vs the rollout-best action.
    The number that matters — accuracy over-penalizes harmless near-tie 'errors'."""
    _, _, z = forward(x)
    z = np.where(mask > 0, z, -1e9)
    pred = z.argmax(axis=1)
    acc = (pred == target).mean()
    best_v = np.where(mask > 0, values, -np.inf).max(axis=1)
    picked_v = values[np.arange(len(x)), pred]
    regret = (best_v - picked_v).mean()
    recalls = [(pred[target == c] == c).mean() if (target == c).any() else float("nan")
               for c in range(ACTIONS)]
    return acc, regret, recalls

# ---------------------------------------------------------------- train

best_regret = np.inf
best_params = None

for epoch in range(1, EPOCHS + 1):
    order = rng.permutation(len(Xtr))
    total = 0.0
    for s in range(0, len(order), BATCH):
        idx = order[s:s + BATCH]
        loss, grads = ce_grads(Xtr[idx], ytr[idx], Mtr[idx], Wtr[idx])
        total += loss * len(idx)
        t += 1
        for i, (p, g) in enumerate(zip(params, grads)):
            m[i] = beta1 * m[i] + (1 - beta1) * g
            v[i] = beta2 * v[i] + (1 - beta2) * g * g
            p -= LR * (m[i] / (1 - beta1**t)) / (np.sqrt(v[i] / (1 - beta2**t)) + eps)
    acc, regret, recalls = metrics(Xva, yva, Mva, Vva)
    if regret < best_regret:
        best_regret = regret
        best_params = [p.copy() for p in params]
    if epoch % 5 == 0 or epoch == 1:
        r = " ".join(f"{x:.3f}" for x in recalls)
        print(f"epoch {epoch:3d}  loss {total / len(Xtr):.4f}  "
              f"val regret {regret:6.2f}  acc {acc:.4f}  recalls [{r}]")

W1, b1, W2, b2, W3, b3 = best_params
acc, regret, recalls = metrics(Xva, yva, Mva, Vva)
r = " ".join(f"{x:.3f}" for x in recalls)
print(f"\nfinal (best ckpt): val regret {regret:.2f} rating | acc {acc:.4f} recalls [{r}]")
print("(reference: picking uniformly at random would have much higher regret;"
      " the teacher itself has regret 0 by construction)")

# ---------------------------------------------------------------- export

out = {
    "featureNames": names,
    "hidden": HIDDEN,
    "valAccuracy": round(float(acc), 4),
    "W1": W1.tolist(), "b1": b1.tolist(),
    "W2": W2.tolist(), "b2": b2.tolist(),
    "W3": W3.tolist(), "b3": b3.tolist(),
}
OUT.write_text(json.dumps(out))
print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB)")
