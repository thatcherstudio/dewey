"""Tier 2: a local decision model picks one folder per file.

Backends
  systemone  Laya (`pip install "laya[serve]"; laya-serve`) or any Jev-compatible server.
             Request:  POST {url}/v1/systemone
                       {"model", "state", "questions": {"folder": {"type": "choice",
                        "instructions": "...", "criteria": {key: description, ...}}}}
             Response: {"answers": {"folder": {"choice", "confidence", "probabilities"}}}
             Calibrated probabilities; one forward pass; the answer is always one of the keys.
  chat       Any OpenAI-compatible /v1/chat/completions server (mlx_lm.server, oMLX, Ollama,
             LM Studio, vLLM). Parses JSON from the reply. Confidence is self-reported and
             uncalibrated, so by default it is capped below the auto threshold.
  none       Rules only. Everything the rules don't claim is left in place.
"""
from __future__ import annotations

import http.client
import json
import os
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field


class DecisionError(RuntimeError):
    pass


@dataclass
class Decision:
    choice: str
    confidence: float
    probabilities: dict = field(default_factory=dict)
    decided_by: str = ""
    note: str = ""


def _post(url: str, body: dict, timeout: float, retries: int = 1) -> dict:
    data = json.dumps(body).encode()
    headers = {"Content-Type": "application/json"}
    key = os.environ.get("DEWEY_API_KEY")
    if key:
        headers["Authorization"] = f"Bearer {key}"
    last = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:500]
            raise DecisionError(f"HTTP {e.code} from {url}: {detail}") from None
        except (urllib.error.URLError, http.client.HTTPException, TimeoutError, ConnectionError) as e:
            last = e
            time.sleep(0.5 * (attempt + 1))
            continue
        try:
            return json.loads(raw.decode())
        except ValueError as e:  # bad JSON or bad UTF-8
            raise DecisionError(f"non-JSON response from {url}: {e}") from None
    raise DecisionError(f"can't reach {url}: {getattr(last, 'reason', last)}")


def _unreadable(resp, e: Exception) -> DecisionError:
    """A server answer we can't make sense of is a decider error (counted, reported), never a crash."""
    return DecisionError(f"couldn't read the response ({type(e).__name__}: {e}): {json.dumps(resp)[:300]}")


def _check_url(url) -> str:
    url = str(url)
    if not url.startswith(("http://", "https://")):
        raise SystemExit(f"decider url must start with http:// or https:// (got {url!r})")
    return url


def _probs_dict(p) -> dict:
    if isinstance(p, dict):
        return {str(k): float(v) for k, v in p.items()}
    if isinstance(p, list):  # unified format: [{"value": k, "probability": p}, ...]
        return {str(x.get("value")): float(x.get("probability", 0)) for x in p if isinstance(x, dict)}
    return {}


class SystemOneDecider:
    kind = "systemone"

    def __init__(self, url: str, model: str, timeout: float):
        url = url.rstrip("/")
        self.url = url if url.endswith("/v1/systemone") else url + "/v1/systemone"
        self.model = model
        self.timeout = timeout
        self.name = f"systemone:{model}"

    def choose(self, state: dict, question: str, options: dict[str, str]) -> Decision:
        body = {"model": self.model, "state": state,
                "questions": {"folder": {"type": "choice", "instructions": question, "criteria": options}}}
        resp = _post(self.url, body, self.timeout)
        try:
            return self._read(resp, options)
        except DecisionError:
            raise
        except Exception as e:  # noqa: BLE001
            raise _unreadable(resp, e) from None

    def _read(self, resp: dict, options: dict[str, str]) -> Decision:
        answers = resp.get("answers")
        if isinstance(answers, list):
            answers = {a.get("name"): a for a in answers if isinstance(a, dict)}
        ans = (answers or {}).get("folder")
        if not isinstance(ans, dict) or "choice" not in ans:
            raise DecisionError(f"unexpected response shape: {json.dumps(resp)[:300]}")
        choice = str(ans["choice"])
        if choice not in options:
            raise DecisionError(f"server answered {choice!r}, which isn't one of the options")
        probs = _probs_dict(ans.get("probabilities"))
        # The tiers need the chosen folder's probability. Laya sends it as `answer_confidence`; its
        # `confidence` is normalized entropy (1 - H(p)/log k), a different scale that also shifts with
        # the number of folders. LAYA_JEV_STRICT drops `answer_confidence`, so fall back to
        # probabilities[choice], and to `confidence` only for servers that send nothing else.
        conf = next((c for c in (ans.get("answer_confidence"), probs.get(choice), ans.get("confidence"))
                     if c is not None), None)
        if conf is None:
            raise DecisionError(f"response has no confidence or probabilities: {json.dumps(resp)[:300]}")
        conf = float(conf)
        if not 0.0 <= conf <= 1.0:  # e.g. a percentage: 95 would otherwise make every file "auto"
            raise DecisionError(f"confidence {conf!r} is outside 0..1; dewey expects a probability")
        return Decision(choice, conf, probs, f"systemone:{resp.get('model') or self.model}")


_THINK = re.compile(r"<think>.*?</think>", re.S)
_CHOICE = re.compile(r'"choice"\s*:\s*"([^"]+)"')
_CONF = re.compile(r'"confidence"\s*:\s*([0-9.]+)')


class ChatDecider:
    kind = "chat"

    def __init__(self, url: str, model: str, timeout: float, cap: float | None):
        url = url.rstrip("/")
        self.url = url if url.endswith("/chat/completions") else (
            url + ("/chat/completions" if url.endswith("/v1") else "/v1/chat/completions"))
        self.model = model
        self.timeout = timeout
        self.cap = cap
        self.name = f"chat:{model}"

    def choose(self, state: dict, question: str, options: dict[str, str]) -> Decision:
        opt_lines = "\n".join(f"- {k}: {v}" for k, v in options.items())
        messages = [
            {"role": "system", "content":
                "You file computer files into folders. Pick exactly one option key from the list. "
                'Reply with JSON only, no prose: {"choice": "<option key>", "confidence": <0 to 1>}'},
            {"role": "user", "content":
                f"{question}\n\nOptions:\n{opt_lines}\n\nFile:\n{json.dumps(state, ensure_ascii=False, indent=1)}"},
        ]
        body = {"model": self.model, "messages": messages, "temperature": 0, "max_tokens": 80}
        resp = _post(self.url, body, self.timeout)
        try:
            return self._read(resp, options)
        except DecisionError:
            raise
        except Exception as e:  # noqa: BLE001
            raise _unreadable(resp, e) from None

    def _read(self, resp: dict, options: dict[str, str]) -> Decision:
        try:
            text = resp["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, TypeError):
            raise DecisionError(f"unexpected chat response: {json.dumps(resp)[:300]}") from None
        text = _THINK.sub("", text).strip()
        choice, conf = None, 0.5
        lo, hi = text.find("{"), text.rfind("}")
        if lo != -1 and hi > lo:
            try:
                obj = json.loads(text[lo:hi + 1])
                choice, conf = str(obj.get("choice", "")), float(obj.get("confidence", 0.5))
            except (json.JSONDecodeError, ValueError, TypeError):
                pass
        if not choice:
            m = _CHOICE.search(text)
            choice = m.group(1) if m else None
            m = _CONF.search(text)
            conf = float(m.group(1)) if m else 0.5
        note = "self-reported confidence (uncalibrated)"
        if choice not in options:
            folded = {k.casefold(): k for k in options}
            choice = folded.get((choice or "").strip().casefold())
        if choice is None:
            hits = [k for k in options if re.search(rf"\b{re.escape(k)}\b", text)]
            choice = hits[0] if len(hits) == 1 else None
        if choice is None:
            fallback = "other" if "other" in options else next(iter(options))
            return Decision(fallback, 0.0, {}, self.name, f"unparseable reply: {text[:80]!r}")
        conf = max(0.0, min(1.0, conf))
        if self.cap is not None:
            conf = min(conf, self.cap)
        return Decision(choice, conf, {choice: conf}, self.name, note)


class NoDecider:
    kind = "none"
    name = "none"

    def choose(self, state, question, options) -> Decision:
        fallback = "other" if "other" in options else next(iter(options))
        return Decision(fallback, 0.0, {}, "none", "rules-only mode")


def make(cfg: dict, backend_override: str | None = None):
    d = cfg["decider"]
    backend = backend_override or d["backend"]
    if backend == "none":
        return NoDecider()
    if backend == "systemone":
        return SystemOneDecider(_check_url(d["url"]), d["model"], float(d["timeout"]))
    if backend == "chat":
        cap = None if d.get("trust_chat_confidence") else max(0.0, float(cfg["plan"]["auto_confidence"]) - 0.01)
        return ChatDecider(_check_url(d["url"]), d["model"], float(d["timeout"]), cap)
    raise SystemExit(f"unknown decider backend: {backend}")


PROBE_STATE = {"file_name": "Chase_Statement_2024-03.pdf", "folder": "Downloads", "extension": ".pdf",
               "size": "212.0 KB", "modified": "2024-04-02",
               "text_preview": "Chase Freedom statement. Account summary. Previous balance, payments, purchases."}


def probe(decider, cfg: dict) -> tuple[bool, str]:
    """One real request with a known-easy file, so setup problems fail fast and loudly."""
    if decider.kind == "none":
        return True, "rules-only (no decider)"
    opts = {k: v["desc"] for k, v in cfg["categories"].items()}
    t = time.monotonic()
    try:
        dec = decider.choose(PROBE_STATE, cfg["decider"]["question"], opts)
    except DecisionError as e:
        return False, str(e)
    except Exception as e:  # noqa: BLE001 - doctor reports problems, it doesn't crash on them
        return False, f"unexpected {type(e).__name__}: {e}"
    ms = (time.monotonic() - t) * 1000
    return True, (f"{decider.name} answered '{dec.choice}' ({dec.confidence:.2f}) for a credit card "
                  f"statement in {ms:.0f} ms" + (f" [{dec.note}]" if dec.note else ""))
