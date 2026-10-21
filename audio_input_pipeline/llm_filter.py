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
