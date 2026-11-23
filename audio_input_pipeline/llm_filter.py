"""
LLM noise classifier (NOISE_SCORING=llm).

Why: sentence embeddings judge each ~5 s chunk alone. In a real session (c617d5e7) the
two_pass scorer flagged 6 lecture chunks (a song-based ML example looked "off-topic")
and missed all 3 side remarks. gpt-oss-20b with the prompt below, given the batch plus
a little earlier lecture as context, had 0 false positives / 0-1 misses on the same data.

Embeddings are still computed and stored (SRS SW-4 schema, topic centroid); only the
is_flagged_noise decision comes from here. Any failure raises, and the caller falls back
to the embedding threshold.
"""

import json
import logging
import os

import stt

log = logging.getLogger("llm_filter")

NOISE_LLM_MODEL = os.getenv("NOISE_LLM_MODEL", "openai/gpt-oss-20b")
CONTEXT_CHUNKS = 4  # earlier clean lecture chunks sent as context (not labelled)

SYSTEM_PROMPT = """You are a real-time semantic audio filtering engine for a lecture transcription system.

GOAL:
Identify chunks in a lecture batch that are semantic noise (off-topic chatter, technical setup, administrative discussions, or audience complaints).

CONSTRAINTS & DOMAIN RULES:
1. Session Topic: "{session_topic}"
2. Examples from other domains, analogies, or audience questions regarding the topic ARE PART OF THE LECTURE. Do not flag them as noise.
3. Listener opinions, complaints about the speaker, mic checks, or unrelated side chatter ARE NOISE.
4. If a chunk contains BOTH academic content and minor chatter, set is_mixed = true.

OUTPUT INSTRUCTIONS:
Return ONLY a JSON object containing ONLY the chunks that are noise or mixed. Omit purely academic chunks completely. Do not include confidence scores.

OUTPUT FORMAT:
{
  "flagged_chunks": [
    {
      "id": 12,
      "is_mixed": true,
      "reason": "Listener complaint mixed with lecture question"
    }
  ]
}"""


def classify(topic: str, chunks: list[dict], context: list[str]) -> dict[int, dict]:
    """chunks: [{"id": int, "text": str}]; context: earlier clean lecture text.
    Returns {id: {"is_mixed": bool, "reason": str}} for noise/mixed chunks only
    (ids not in the result are lecture)."""
    user = ""
    if context:
        user += "Earlier lecture (context only):\n" + "\n".join(context[-CONTEXT_CHUNKS:]) + "\n\n"
    user += "Chunks:\n" + json.dumps(chunks, ensure_ascii=False)

    resp = stt._get_groq_client().chat.completions.create(
        model=NOISE_LLM_MODEL,
        temperature=0,
        reasoning_effort="low",
        response_format={"type": "json_object"},
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT.replace("{session_topic}", topic)},
            {"role": "user", "content": user},
        ],
    )
    data = json.loads(resp.choices[0].message.content)
    valid = {c["id"] for c in chunks}
    out = {}
    for item in data.get("flagged_chunks", []):
        cid = int(item["id"])
        if cid in valid:  # ignore ids the model invented
            out[cid] = {"is_mixed": bool(item.get("is_mixed")),
                        "reason": str(item.get("reason", "")).strip()}
    return out


# ------------------------------------------------------------------ session check
# Whole-session "lecture or chatter?" question. Embeddings can't answer it when the topic
# is generic ("Lecture 1", default topic): measured on the cooking session 8b897cc8, a
# chatter-only set and the real lecture both matched a generic topic at 0.20-0.25, so no
# threshold separates them. One call per flush, only when the topic is generic or the
# topic guard is about to flag the whole batch (see audio_pipeline.flush_buffer).

SESSION_CHECK_MAX_WORDS = 1500  # long lectures are sampled evenly to stay under the TPM limit

SESSION_CHECK_PROMPT = """You check whether a recorded session is a lecture.

Session title given by the user (may be generic or wrong): "{session_topic}"

A LECTURE is someone teaching, presenting or explaining a subject. It still counts as a lecture if it also has greetings, side chatter, audience questions, examples or Urdu/English mixing.
NOT A LECTURE: only casual conversation, personal talk, phone calls, background chatter or mic tests, with no teaching.

Judge the transcript content, not the title. Return ONLY JSON:
{"is_lecture": true, "reason": "short reason"}"""


def _sample_texts(texts: list[str], max_words: int) -> list[str]:
    """Evenly spaced chunks whose total stays under max_words (keeps the order)."""
    if sum(len(t.split()) for t in texts) <= max_words:
        return texts
    avg = max(1, sum(len(t.split()) for t in texts) // len(texts))
    keep = max(1, max_words // avg)
    step = len(texts) / keep
    return [texts[int(i * step)] for i in range(keep)]


def session_is_lecture(topic: str, texts: list[str]) -> tuple[bool, str]:
    """True if the transcript reads as a lecture. Raises on any failure (caller falls back)."""
    sample = _sample_texts([t for t in texts if t.strip()], SESSION_CHECK_MAX_WORDS)
    resp = stt._get_groq_client().chat.completions.create(
        model=NOISE_LLM_MODEL,
        temperature=0,
        reasoning_effort="low",
        response_format={"type": "json_object"},
        messages=[
            {"role": "system", "content": SESSION_CHECK_PROMPT.replace("{session_topic}", topic)},
            {"role": "user", "content": "Transcript chunks:\n" + "\n".join(sample)},
        ],
    )
    data = json.loads(resp.choices[0].message.content)
    if not isinstance(data.get("is_lecture"), bool):
        raise ValueError(f"bad session-check answer: {data!r}")
    return data["is_lecture"], str(data.get("reason", "")).strip()
