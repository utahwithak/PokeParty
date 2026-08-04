#!/usr/bin/env python3
"""Self-play PPO for the 3v3 switch policy (RL milestone 3).

Warm-starts from the expert-iteration net (data/switch_policy.json), adds a
value head on the shared trunk, and improves the policy by playing itself:
each iteration the Swift engine generates a batch of stochastic self-play
games (rl/generate --selfplay-batch), then this script applies clipped PPO
updates. Every few iterations the candidate is benchmarked with the FIXED
external yardstick (--switch-eval vs the heuristic engine on unseen teams,
seed 424242) — self-play reward can drift, the benchmark can't. The best
weights by benchmark are kept; the shipped file is only replaced by hand.

Usage: venv/bin/python ppo_switch.py [iterations]
Writes: data/switch_policy_ppo.json (current), data/switch_policy_ppo_best.json (best)
"""

import json
import re
import subprocess
import sys
from pathlib import Path

import numpy as np

DATA = Path("data")
START = DATA / "switch_policy.json"          # EXIT round-3 warm start
CURRENT = DATA / "switch_policy_ppo.json"
BEST = DATA / "switch_policy_ppo_best.json"
BATCH_FILE = DATA / "selfplay_batch.jsonl"

ITERATIONS = int(sys.argv[1]) if len(sys.argv) > 1 else 40
GAMES_PER_BATCH = 4000
EPOCHS = 2
MINIBATCH = 8192
LR = 3e-5
CLIP = 0.2
VALUE_COEF = 0.5
ENTROPY_COEF = 0.005
EVAL_EVERY = 5
ACTIONS = 3
# Iterations with the policy (and trunk) frozen while the fresh value head
# fits — a random value head means garbage advantages, which is what damaged
# the warm start on the first PPO attempt.
VALUE_WARMUP = 6

rng = np.random.default_rng(11)

# ---------------------------------------------------------------- weights

w = json.loads(START.read_text())
names, hidden = w["featureNames"], w["hidden"]
W1 = np.asarray(w["W1"], dtype=np.float32); b1 = np.asarray(w["b1"], dtype=np.float32)
W2 = np.asarray(w["W2"], dtype=np.float32); b2 = np.asarray(w["b2"], dtype=np.float32)
W3 = np.asarray(w["W3"], dtype=np.float32); b3 = np.asarray(w["b3"], dtype=np.float32)
# Fresh value head on the shared trunk.
W3v = rng.normal(0, 0.01, (hidden, 1)).astype(np.float32)
b3v = np.zeros(1, dtype=np.float32)

params = [W1, b1, W2, b2, W3, b3, W3v, b3v]
adam_m = [np.zeros_like(p) for p in params]
adam_v = [np.zeros_like(p) for p in params]
adam_t = 0

def save(path: Path):
    path.write_text(json.dumps({
        "featureNames": names, "hidden": hidden,
        "W1": W1.tolist(), "b1": b1.tolist(),
        "W2": W2.tolist(), "b2": b2.tolist(),
        "W3": W3.tolist(), "b3": b3.tolist(),
        # Value head — ignored by the Swift decoder, used to resume PPO.
        "W3v": W3v.tolist(), "b3v": b3v.tolist(),
    }))

def forward(x):
    h1 = np.maximum(x @ W1 + b1, 0)
    h2 = np.maximum(h1 @ W2 + b2, 0)
    return h1, h2, h2 @ W3 + b3, (h2 @ W3v + b3v).squeeze(-1)

def adam_step(grads, lr):
    global adam_t
    adam_t += 1
    for i, (p, g) in enumerate(zip(params, grads)):
        adam_m[i] = 0.9 * adam_m[i] + 0.1 * g
        adam_v[i] = 0.999 * adam_v[i] + 0.001 * g * g
        p -= lr * (adam_m[i] / (1 - 0.9**adam_t)) / (np.sqrt(adam_v[i] / (1 - 0.999**adam_t)) + 1e-8)

# ---------------------------------------------------------------- PPO update

def ppo_update(X, A_idx, LP_old, M, R, value_only=False):
    """One epoch of clipped PPO over minibatches; returns diagnostics.
    `value_only` freezes everything except the value head (warmup)."""
    order = rng.permutation(len(X))
    clip_frac_sum, ent_sum, vloss_sum, nb = 0.0, 0.0, 0.0, 0

    for s in range(0, len(order), MINIBATCH):
        idx = order[s:s + MINIBATCH]
        x, a, lp_old, mask, r = X[idx], A_idx[idx], LP_old[idx], M[idx], R[idx]
        n = len(x)

        h1, h2, z, V = forward(x)
        zm = np.where(mask > 0, z, -1e9)
        zm = zm - zm.max(axis=1, keepdims=True)
        e = np.exp(zm)
        p = e / e.sum(axis=1, keepdims=True)
        logp = np.log(np.maximum(p, 1e-12))
        lp_new = logp[np.arange(n), a]

        adv = r - V
        adv = (adv - adv.mean()) / (adv.std() + 1e-6)

        ratio = np.exp(np.clip(lp_new - lp_old, -20, 20))
        clipped_out = ((adv > 0) & (ratio > 1 + CLIP)) | ((adv < 0) & (ratio < 1 - CLIP))
        clip_frac_sum += clipped_out.mean(); nb += 1

        onehot = np.eye(ACTIONS, dtype=np.float32)[a]
        # d(-clip objective)/dz: policy-gradient through the softmax, zeroed
        # where the clip is active.
        coef = np.where(clipped_out, 0.0, adv * ratio).astype(np.float32)
        dz = -coef[:, None] * (onehot - p) / n

        # Entropy bonus (legal actions only): dH/dz_j = -p_j (log p_j + H).
        H = -(p * np.where(p > 0, logp, 0)).sum(axis=1)
        ent_sum += H.mean()
        dH = -p * (np.where(p > 0, logp, 0) + H[:, None])
        dz += -ENTROPY_COEF * dH / n

        # Value head: c1 * (V - r)^2.
        verr = V - r
        vloss_sum += (verr ** 2).mean()
        dV = (2 * VALUE_COEF * verr / n)[:, None].astype(np.float32)

        gW3v = h2.T @ dV
        gb3v = dV.sum(0)
        if value_only:
            adam_step([np.zeros_like(W1), np.zeros_like(b1),
                       np.zeros_like(W2), np.zeros_like(b2),
                       np.zeros_like(W3), np.zeros_like(b3), gW3v, gb3v], LR * 20)
            continue
        gW3 = h2.T @ dz
        gb3 = dz.sum(0)
        dh2 = (dz @ W3.T + dV @ W3v.T) * (h2 > 0)
        gW2 = h1.T @ dh2
        gb2 = dh2.sum(0)
        dh1 = (dh2 @ W2.T) * (h1 > 0)
        gW1 = x.T @ dh1
        gb1 = dh1.sum(0)
        adam_step([gW1, gb1, gW2, gb2, gW3, gb3, gW3v, gb3v], LR)

    return clip_frac_sum / nb, ent_sum / nb, vloss_sum / nb

# ---------------------------------------------------------------- benchmark

def benchmark(path: Path) -> float:
    """Win rate vs the heuristic engine on the fixed unseen-teams benchmark."""
    out = subprocess.run(
        ["./generate", "../bench/data", "150", "data",
         "--switch-eval", "120", "--seed", "424242", "--weights", str(path)],
        capture_output=True, text=True, check=True).stdout
    m = re.search(r"net switch vs heuristics:\s+win rate\s+([\d.]+)%", out)
    return float(m.group(1)) if m else float("nan")

# ---------------------------------------------------------------- loop

save(CURRENT)
best_win = benchmark(CURRENT)
save(BEST)
print(f"warm start benchmark: {best_win:.1f}% (EXIT r3)")

for it in range(1, ITERATIONS + 1):
    subprocess.run(
        ["./generate", "../bench/data", "150", "data",
         "--selfplay-batch", str(GAMES_PER_BATCH), "--seed", str(1000 + it),
         "--weights", str(CURRENT), "--out", str(BATCH_FILE),
         "--anchor", "data/switch_policy_exit3.json"],
        capture_output=True, check=True)

    xs, acts, lps, masks, rs = [], [], [], [], []
    with BATCH_FILE.open() as f:
        for line in f:
            t = json.loads(line)
            xs.append(t["x"]); acts.append(t["a"]); lps.append(t["lp"]); rs.append(t["r"])
            m = np.zeros(ACTIONS, dtype=np.float32); m[t["legal"]] = 1
            masks.append(m)
    X = np.asarray(xs, dtype=np.float32)
    A_idx = np.asarray(acts, dtype=np.int64)
    LP_old = np.asarray(lps, dtype=np.float32)
    M = np.asarray(masks, dtype=np.float32)
    R = np.asarray(rs, dtype=np.float32)

    for _ in range(EPOCHS):
        clip_frac, entropy, vloss = ppo_update(X, A_idx, LP_old, M, R,
                                               value_only=it <= VALUE_WARMUP)
    save(CURRENT)

    line = (f"iter {it:3d}  {len(X):6d} transitions  reward {R.mean():+.4f}  "
            f"entropy {entropy:.3f}  clip {clip_frac:.3f}  vloss {vloss:.4f}")
    if it % EVAL_EVERY == 0 or it == ITERATIONS:
        win = benchmark(CURRENT)
        line += f"  | benchmark {win:.1f}%"
        if win > best_win:
            best_win = win
            save(BEST)
            line += "  ** new best"
    print(line, flush=True)

print(f"\nbest benchmark win rate: {best_win:.1f}% (weights in {BEST})")
print("ship with: cp data/switch_policy_ppo_best.json data/switch_policy.json "
      "&& cp data/switch_policy.json ../PokeParty/Resources/switch_policy.json")
