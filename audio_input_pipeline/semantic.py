"""
Semantic noise flagging with a dynamic topic centroid.

Per session:
  1. Seed:  V_topic = embed(rich seed text built from seminar_topic)
  2. Every flush (10 min, or on session stop) over the buffered chunks:
       sim_i    = cos(chunk_i, V_ref)
       is_noise = sim_i < threshold   (COLD_THRESHOLD on the 1st flush, NOISE_THRESHOLD after)
       V_topic  = norm(OLD_WEIGHT * V_topic + (1 - OLD_WEIGHT) * Centroid(clean chunks))

NOISE_SCORING=llm: the pipeline asks llm_filter for the noise flags and passes them in
as noise_override; the steps above still run (similarities + centroid update).

V_ref depends on NOISE_SCORING:
  seed_only - V_ref = V_topic (score against the current topic vector only)
  two_pass  - V_ref = norm(w * V_topic + (1 - w) * Centroid(batch)),
              w = 0.3 on the cold flush, 0.7 afterwards. The batch's own centroid is
              dominated by the lecture, so real content scores high even when the
              seed text is generic.

Topic guard (two_pass): if the batch itself is off-topic - e.g. a whole session of
chatter - its centroid is off-topic too and every chunk looks "on-topic" against it
(phone test e48a4b09: 11 chatter chunks, 0 flagged). So when
cos(Centroid(batch), V_topic) < TOPIC_GUARD the batch is scored against V_topic only.
Off for the default topic: its generic seed scores a real ML lecture at 0.10 (1804334c).
On all 22 stored sessions: lectures scored 0.37-0.57 (unchanged), the 6 chatter-only
sessions -0.05..0.08 (now flagged). Preliminary - 22 sessions, not proof.

MIXED (embedding modes): a chunk that is not noise but has 2+ sentences is split at
. ? ! and each sentence is scored against V_ref; one sentence below SENTENCE_THRESHOLD
marks the chunk is_mixed. Every such sentence is returned in off_topic (they are cut
from the clean transcript unless the user KEEPs the chunk); the first goes in noise_reason.
On 5 hand-labelled sessions (55 chunks, 14 noise/mixed, one post-lecture flush) this
took misses 7 -> 4 for 1 extra false flag.

All vectors are L2-normalised, so cosine similarity = dot product.
"""

import logging
import os
import re
import threading

import numpy as np

log = logging.getLogger("semantic")

MODEL_NAME = "all-MiniLM-L6-v2"  # SRS SW-4, 384-d
DEFAULT_SEMINAR_TOPIC = "General Academic & Technical Seminar"
SEED_TEMPLATE = ("Academic presentation, lecture and technical discussion on {topic}. "
                 "Subject definitions, formulas, concepts, and explanation.")

# two_pass is the default: in tests seed_only flagged 3-9 of 9 real lecture sentences
# (a short seed text is too far from real sentences); two_pass flagged 0-1.
# llm: gpt-oss decides is_flagged_noise (see llm_filter.py), two_pass is its fallback.
NOISE_SCORING = os.getenv("NOISE_SCORING", "two_pass")  # two_pass | seed_only | llm
COLD_THRESHOLD = float(os.getenv("COLD_THRESHOLD", "0.28"))   # first flush
NOISE_THRESHOLD = float(os.getenv("NOISE_THRESHOLD", "0.40"))  # later flushes (SRS 3.4)
CENTROID_OLD_WEIGHT = float(os.getenv("CENTROID_OLD_WEIGHT", "0.6"))
SENTENCE_THRESHOLD = float(os.getenv("SENTENCE_THRESHOLD", "0.20"))  # MIXED check
MIN_SENTENCE_WORDS = 3  # shorter fragments embed unreliably - not scored on their own
TOPIC_GUARD = float(os.getenv("TOPIC_GUARD", "0.20"))  # batch-vs-topic floor; 0 = off

_model = None
_model_lock = threading.Lock()


def get_model():
    global _model
    with _model_lock:
        if _model is None:
            from sentence_transformers import SentenceTransformer

            log.info("loading sentence-transformers model %s...", MODEL_NAME)
            try:
                # cached copy first: skips ~7 s of HuggingFace online checks per start
                _model = SentenceTransformer(MODEL_NAME, device="cpu", local_files_only=True)
            except Exception:
                _model = SentenceTransformer(MODEL_NAME, device="cpu")  # first run: download
            log.info("sentence-transformers model loaded")
    return _model


def _norm(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v)
    return v / n if n else v


def embed(texts: list[str]) -> np.ndarray:
    return get_model().encode(texts, normalize_embeddings=True, convert_to_numpy=True)


def seed_vector(seminar_topic: str) -> np.ndarray:
    return embed([SEED_TEMPLATE.format(topic=seminar_topic)])[0]


def _split_sentences(text: str) -> list[str]:
    parts = (s.strip() for s in re.split(r"(?<=[.?!])\s+", text))
    return [s for s in parts if len(s.split()) >= MIN_SENTENCE_WORDS]


def _find_mixed(texts: list[str], noise: np.ndarray, ref: np.ndarray
                ) -> tuple[np.ndarray, list[str | None], list[list[str]]]:
    """Sentence-level check of the non-noise chunks.
    Returns (is_mixed, reason, off-topic sentences) per chunk."""
    owners, sentences = [], []
    for i, text in enumerate(texts):
        parts = _split_sentences(text)
        if not noise[i] and len(parts) >= 2:
            owners += [i] * len(parts)
            sentences += parts
    mixed, reasons = np.zeros(len(texts), dtype=bool), [None] * len(texts)
    off_topic: list[list[str]] = [[] for _ in texts]
    if not sentences:
        return mixed, reasons, off_topic
    sent_sims = embed(sentences) @ ref  # one encode call for the whole batch
    for i, s, sim in zip(owners, sentences, sent_sims):
        if sim < SENTENCE_THRESHOLD:
            off_topic[i].append(s)
            if not mixed[i]:
                mixed[i] = True
                reasons[i] = f'off-topic sentence ({sim:.2f}): "{s}"'
    return mixed, reasons, off_topic


def score_batch(texts: list[str], topic: np.ndarray, cold: bool,
                noise_override: np.ndarray | None = None, guard: bool = True) -> dict:
    """Embed + score one flush batch. Returns embeddings, similarities, noise flags,
    mixed flags (+ reason), the updated topic vector and the settings used.
    noise_override: flags decided elsewhere (llm_filter); similarities are still computed
    and the topic centroid still learns only from the non-noise chunks.
    guard: allow the topic guard (the caller passes False for the default topic)."""
    E = embed(texts)
    batch_centroid = _norm(E.mean(axis=0))
    topic_match = float(batch_centroid @ topic)
    w = 0.3 if cold else 0.7
    two_pass_ref = _norm(w * topic + (1 - w) * batch_centroid)
    guarded = (NOISE_SCORING != "seed_only" and guard and topic_match < TOPIC_GUARD)
    ref = topic if NOISE_SCORING == "seed_only" or guarded else two_pass_ref
    threshold = COLD_THRESHOLD if cold else NOISE_THRESHOLD
    sims = E @ ref
    noise = sims < threshold if noise_override is None else np.asarray(noise_override, dtype=bool)
    mixed, mixed_reason = np.zeros(len(texts), dtype=bool), [None] * len(texts)
    off_topic: list[list[str]] = [[] for _ in texts]
    if noise_override is None:
        mixed, mixed_reason, off_topic = _find_mixed(texts, noise, ref)

    clean = E[~noise]
    if len(clean):
        new_topic = _norm(CENTROID_OLD_WEIGHT * topic
                          + (1 - CENTROID_OLD_WEIGHT) * _norm(clean.mean(axis=0)))
    else:
        new_topic = topic  # nothing clean to learn from - keep the old topic
    return {
        "embeddings": E,
        "similarities": sims,
        "is_noise": noise,
        "is_mixed": mixed,
        "mixed_reason": mixed_reason,
        "off_topic": off_topic,
        "topic": new_topic,
        "threshold": threshold,
        "mode": (NOISE_SCORING if noise_override is None else "override")
                + ("+topic_guard" if guarded else ""),
        "topic_updated": bool(len(clean)),
        "topic_match": topic_match,  # batch centroid vs topic vector
        "topic_guard": guarded,
        # what two_pass alone would have scored (logged, to investigate guard decisions)
        "two_pass_similarities": E @ two_pass_ref,
    }
