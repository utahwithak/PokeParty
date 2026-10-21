#!/usr/bin/env python3
"""Trainer for the farm-vs-switch policy.

Imitates the rollout-search teacher from rl/generate --farm-gen: a tiny MLP
(features -> 64 -> 64 -> 2 logits: 0 = switch now, 1 = farm) trained with
softmax cross-entropy, weighted by how much the better option actually wins.

Split discipline: train/validation split by GAME KEY (team pair), matching the
--farm-eval holdout (crc32(key) % 10 == 0).

Usage: venv/bin/python train_farm.py [data/farm_dataset.jsonl]
Writes: data/farm_policy.json
"""

import json
import sys
import zlib
from pathlib import Path

import numpy as np

DATA = Path(sys.argv[1] if len(sys.argv) > 1 else "data/farm_dataset.jsonl")
META = DATA.parent / "farm_meta.json"
OUT = DATA.parent / "farm_policy.json"

HIDDEN = 64
ACTIONS = 2
EPOCHS = 40
BATCH = 1024
LR = 1e-3
SEED = 7

rng = np.random.default_rng(SEED)

# ---------------------------------------------------------------- data

names = json.loads(META.read_text())["featureNames"]

xs, ys, vals, keys = [], [], [], []
with DATA.open() as f:
    for line in f:
        r = json.loads(line)
        xs.append(r["x"])
        ys.append(r["y"])
        vals.append(r["v"])
        keys.append(r["g"])

X = np.asarray(xs, dtype=np.float32)
y = np.asarray(ys, dtype=np.int64)
V = np.asarray(vals, dtype=np.float32)    # rollout value per action
assert X.shape[1] == len(names), "feature count mismatch with farm_meta.json"

# Decision importance: rating gap between the two options. Near-ties get almost
# no weight — being "wrong" there costs nothing.
margin = np.abs(V[:, 1] - V[:, 0]) / 1000.0
weight = np.clip(margin, 0.005, 1.0).astype(np.float32)

val_mask = np.asarray([zlib.crc32(k.encode()) % 10 == 0 for k in keys], dtype=bool)
Xtr, ytr, Wtr = X[~val_mask], y[~val_mask], weight[~val_mask]
Xva, yva, Vva = X[val_mask], y[val_mask], V[val_mask]
print(f"{len(Xtr)} train / {len(Xva)} val samples "
      f"({len(set(keys))} games, {X.shape[1]} features)")
counts = np.bincount(ytr, minlength=ACTIONS)
print(f"label counts (train): switch now {counts[0]}, farm {counts[1]}")
print(f"decisions with real stakes (margin > 25 rating): {(margin > 0.025).mean():.1%}")
if len(Xva) == 0:
    sys.exit("no validation samples — generate with more teams")

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

def ce_grads(x, target, w):
    h1, h2, z = forward(x)
    z = z - z.max(axis=1, keepdims=True)
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

def metrics(x, target, values):
    """Regret = rating the policy leaves on the table vs the rollout-best option."""
    _, _, z = forward(x)
    pred = z.argmax(axis=1)
    acc = (pred == target).mean()
    regret = (values.max(axis=1) - values[np.arange(len(x)), pred]).mean()
    recalls = [(pred[target == c] == c).mean() if (target == c).any() else float("nan")
               for c in range(ACTIONS)]
    return acc, regret, recalls

# Reference points: what the two fixed policies would score on the same samples.
always_farm = (Vva.max(axis=1) - Vva[:, 1]).mean()
never_farm = (Vva.max(axis=1) - Vva[:, 0]).mean()
print(f"val regret of fixed policies: always farm {always_farm:.2f}, never farm {never_farm:.2f}")

# ---------------------------------------------------------------- train

best_regret = np.inf
best_params = None

for epoch in range(1, EPOCHS + 1):
    order = rng.permutation(len(Xtr))
    total = 0.0
    for s in range(0, len(order), BATCH):
        idx = order[s:s + BATCH]
        loss, grads = ce_grads(Xtr[idx], ytr[idx], Wtr[idx])
        total += loss * len(idx)
        t += 1
        for i, (p, g) in enumerate(zip(params, grads)):
            m[i] = beta1 * m[i] + (1 - beta1) * g
            v[i] = beta2 * v[i] + (1 - beta2) * g * g
            p -= LR * (m[i] / (1 - beta1**t)) / (np.sqrt(v[i] / (1 - beta2**t)) + eps)
    acc, regret, recalls = metrics(Xva, yva, Vva)
    if regret < best_regret:
        best_regret = regret
        best_params = [p.copy() for p in params]
    if epoch % 5 == 0 or epoch == 1:
        r = " ".join(f"{x:.3f}" for x in recalls)
        print(f"epoch {epoch:3d}  loss {total / len(Xtr):.4f}  "
              f"val regret {regret:6.2f}  acc {acc:.4f}  recalls [{r}]")

W1, b1, W2, b2, W3, b3 = best_params
acc, regret, recalls = metrics(Xva, yva, Vva)
r = " ".join(f"{x:.3f}" for x in recalls)
print(f"\nfinal (best ckpt): val regret {regret:.2f} rating | acc {acc:.4f} recalls [{r}]")
print(f"(must beat the best fixed policy: min(always farm {always_farm:.2f}, never farm {never_farm:.2f}))")

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
