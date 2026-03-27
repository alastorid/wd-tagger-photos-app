#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
import traceback
import threading
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import huggingface_hub
import numpy as np
import pandas as pd
import timm
import torch
from PIL import Image
from timm.data import create_transform, resolve_data_config
from typing import List, Tuple, Dict
Image.MAX_IMAGE_PIXELS = 1_000_000_000
# -------------------------
# Models / constants
# -------------------------
LABEL_FILENAME = "selected_tags.csv"

kaomojis = [
    "0_0", "(o)_(o)", "+_+", "+_-", "._.", "<o>_<o>", "<|>_<|>", "=_=", ">_<", "3_3",
    "6_9", ">_o", "@_@", "^_^", "o_o", "u_u", "x_x", "|_|", "||_||",
]

# -------------------------
# Utilities
# -------------------------
def str2bool(s: str) -> bool:
    return str(s).lower() in ("1", "true", "yes", "y", "on")


def _ts() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()) + f".{int((time.time() % 1) * 1000):03d}"


def _log(debug: bool, msg: str, err: bool = False) -> None:
    if not debug:
        return
    fp = sys.stderr if err else sys.stdout
    print(f"[{_ts()}] {msg}", file=fp, flush=True)


def _image_info(path: str) -> tuple[int, str]:
    try:
        size = os.path.getsize(path)
    except Exception:
        size = -1
    wh = "?x?"
    try:
        with Image.open(path) as im:
            w, h = im.size
        wh = f"{w}x{h}"
    except Exception:
        pass
    return size, wh


def _safe_unlink(path: str, debug: bool = False) -> None:
    try:
        os.unlink(path)
        _log(debug, f"[wd-daemon] preload delete input ok path={path}")
    except FileNotFoundError:
        _log(debug, f"[wd-daemon] preload delete skipped missing path={path}")
    except Exception as e:
        _log(debug, f"[wd-daemon][warn] preload delete failed path={path} err={e}", err=True)


def mcut_threshold(probs: np.ndarray) -> float:
    sorted_probs = probs[probs.argsort()[::-1]]
    difs = sorted_probs[:-1] - sorted_probs[1:]
    t = int(difs.argmax())
    return float((sorted_probs[t] + sorted_probs[t + 1]) / 2.0)


def pick_device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def load_labels(df: pd.DataFrame):
    name_series = df["name"].map(lambda x: x.replace("_", " ") if x not in kaomojis else x)
    tag_names = name_series.tolist()
    rating_indexes = list(np.where(df["category"] == 9)[0])
    general_indexes = list(np.where(df["category"] == 0)[0])
    character_indexes = list(np.where(df["category"] == 4)[0])
    return tag_names, rating_indexes, general_indexes, character_indexes


def _open_and_prepare_pil(path: str, max_side: int) -> Image.Image:
    with Image.open(path) as im:
        if im.mode == "RGBA":
            canvas = Image.new("RGBA", im.size, (255, 255, 255))
            canvas.alpha_composite(im)
            im = canvas.convert("RGB")
        else:
            im = im.convert("RGB")

        w, h = im.size
        m = max(w, h)
        if m > max_side:
            scale = max_side / float(m)
            nw = max(1, int(w * scale))
            nh = max(1, int(h * scale))
            im = im.resize((nw, nh), Image.LANCZOS)

        w, h = im.size
        if w != h:
            px = max(w, h)
            padded = Image.new("RGB", (px, px), (255, 255, 255))
            padded.paste(im, ((px - w) // 2, (px - h) // 2))
            im = padded

        return im


# -------------------------
# Keyed one-shot cache
# -------------------------
class KeyedTensorCache:
    """
    key -> entry
    entry = {
        "event": threading.Event(),
        "tensor": torch.Tensor | None,
        "error": str | None,
        "path": str,
        "created_at": float,
    }
    """
    def __init__(self, debug: bool = True):
        self.debug = debug
        self._lock = threading.RLock()
        self._seq = 0
        self._data: Dict[str, dict] = {}

    def new_key(self) -> str:
        with self._lock:
            self._seq += 1
            return f"k{self._seq}"

    def create_pending(self, path: str) -> str:
        with self._lock:
            key = self.new_key()
            self._data[key] = {
                "event": threading.Event(),
                "tensor": None,
                "error": None,
                "path": path,
                "created_at": time.time(),
            }
            return key

    def set_ready(self, key: str, tensor: torch.Tensor):
        with self._lock:
            ent = self._data.get(key)
            if ent is None:
                return
            ent["tensor"] = tensor
            ent["error"] = None
            ent["event"].set()

    def set_error(self, key: str, err: str):
        with self._lock:
            ent = self._data.get(key)
            if ent is None:
                return
            ent["error"] = err
            ent["event"].set()

    def get_entry(self, key: str):
        with self._lock:
            return self._data.get(key)

    def get_if_ready(self, key: str):
        with self._lock:
            ent = self._data.get(key)
            if ent is None:
                return None
            if not ent["event"].is_set():
                return None
            return ent

    def wait_ready(self, key: str, timeout: float | None = None):
        ent = self.get_entry(key)
        if ent is None:
            raise KeyError(f"unknown cache key: {key}")
        ok = ent["event"].wait(timeout=timeout)
        if not ok:
            raise TimeoutError(f"cache key not ready: {key}")
        return ent

    def purge(self, key: str):
        with self._lock:
            self._data.pop(key, None)

    def purge_many(self, keys: List[str]):
        with self._lock:
            for k in keys:
                self._data.pop(k, None)

    def __len__(self):
        with self._lock:
            return len(self._data)


# -------------------------
# Local predictor
# -------------------------
class LocalTagger:
    def __init__(self, model_repo: str, debug: bool = True, max_side: int = 1024):
        self.device = pick_device()
        self.debug = debug
        self.max_side = int(max_side)

        self.last_loaded_repo = None
        self.model = None
        self.transform = None

        self.tag_names = []
        self.rating_indexes = []
        self.general_indexes = []
        self.character_indexes = []

        self._input_h = None
        self._input_w = None

        self._model_lock = threading.RLock()

        self.load_model(model_repo)

    def _hf_download(self, repo: str, filename: str) -> str:
        return huggingface_hub.hf_hub_download(repo, filename)

    def load_model(self, model_repo: str):
        with self._model_lock:
            if model_repo == self.last_loaded_repo and self.model is not None:
                return

            t0 = time.perf_counter()

            csv_path = self._hf_download(model_repo, LABEL_FILENAME)
            df = pd.read_csv(csv_path)
            tag_names, rating_idx, general_idx, character_idx = load_labels(df)
            self.tag_names = tag_names
            self.rating_indexes = rating_idx
            self.general_indexes = general_idx
            self.character_indexes = character_idx

            model = timm.create_model("hf-hub:" + model_repo).eval()
            state_dict = timm.models.load_state_dict_from_hf(model_repo)
            missing, unexpected = model.load_state_dict(state_dict, strict=False)
            if self.debug and (missing or unexpected):
                _log(self.debug, f"[wd-daemon][warn] strict=False missing={len(missing)} unexpected={len(unexpected)}", err=True)

            data_cfg = resolve_data_config(model.pretrained_cfg, model=model)
            self._input_h = int(data_cfg["input_size"][1])
            self._input_w = int(data_cfg["input_size"][2])
            self.transform = create_transform(**data_cfg)

            self.model = model.to(self.device)
            self.last_loaded_repo = model_repo

            with torch.inference_mode():
                dummy = torch.zeros((1, 3, self._input_h, self._input_w), device=self.device)
                _ = self.model(dummy)

            dt = time.perf_counter() - t0
            _log(self.debug, f"[wd-daemon] loaded model={model_repo} device={self.device} input={self._input_w}x{self._input_h} dt={dt:.3f}s")

    def prepare_tensor_cpu(self, image_path: str, model_repo: str) -> torch.Tensor:
        self.load_model(model_repo)
        pil = _open_and_prepare_pil(image_path, max_side=self.max_side)
        x = self.transform(pil).unsqueeze(0)
        x = x[:, [2, 1, 0], :, :]
        return x.contiguous().cpu()

    def _prepare_tensor_batch_from_cpu(self, xs_cpu: List[torch.Tensor]) -> torch.Tensor:
        if not xs_cpu:
            raise ValueError("empty xs_cpu")
        x = torch.cat(xs_cpu, dim=0)
        return x.to(self.device)

    def infer_batch_from_prepared(
        self,
        xs_cpu: List[torch.Tensor],
        model_repo: str,
        gth: float,
        gmcut: bool,
        cth: float,
        cmcut: bool,
    ) -> Tuple[List[str], List[Dict[str, float]]]:
        if not xs_cpu:
            return [], []

        self.load_model(model_repo)

        with self._model_lock:
            x = self._prepare_tensor_batch_from_cpu(xs_cpu)
            with torch.inference_mode():
                probs = torch.sigmoid(self.model(x)).to("cpu").numpy()

        tag_strings: List[str] = []
        ratings_list: List[Dict[str, float]] = []

        for b in range(probs.shape[0]):
            pb = probs[b]

            rating_items = [(self.tag_names[i], float(pb[i])) for i in self.rating_indexes]
            rating = dict(rating_items)

            general_items = [(self.tag_names[i], float(pb[i])) for i in self.general_indexes]
            if gmcut:
                general_thresh = mcut_threshold(np.array([v for _, v in general_items], dtype=np.float32))
            else:
                general_thresh = float(gth)
            general_kept = [(k, v) for (k, v) in general_items if v > general_thresh]

            character_items = [(self.tag_names[i], float(pb[i])) for i in self.character_indexes]
            if cmcut:
                character_thresh = mcut_threshold(np.array([v for _, v in character_items], dtype=np.float32))
                character_thresh = max(0.15, float(character_thresh))
            else:
                character_thresh = float(cth)
            _ = [(k, v) for (k, v) in character_items if v > character_thresh]

            tag_str = ", ".join([k for (k, _) in sorted(general_kept, key=lambda x: x[1], reverse=True)])
            tag_str = tag_str.replace("(", r"\(").replace(")", r"\)")
            tag_strings.append((tag_str or "").strip())
            ratings_list.append(rating)

        return tag_strings, ratings_list

    def get_selected_tags(self) -> List[str]:
        self.load_model(self.last_loaded_repo)
        return list(self.tag_names)


def _wants_text(handler) -> bool:
    u = urlparse(handler.path)
    qs = parse_qs(u.query)
    fmt = (qs.get("fmt") or [""])[0].lower()
    if fmt in ("text", "plain", "us", "unitsep"):
        return True
    accept = (handler.headers.get("Accept") or "").lower()
    return "text/plain" in accept


# -------------------------
# Preload manager
# -------------------------
class PreloadManager:
    def __init__(self, tagger: LocalTagger, cache: KeyedTensorCache, model_repo: str, max_workers: int = 2, debug: bool = True):
        self.tagger = tagger
        self.cache = cache
        self.model_repo = model_repo
        self.debug = debug
        self.pool = ThreadPoolExecutor(max_workers=max(1, int(max_workers)), thread_name_prefix="preload")

    def preload_async(self, path: str) -> str:
        key = self.cache.create_pending(path)

        def _job():
            t0 = time.perf_counter()
            _log(self.debug, f"[wd-daemon] preload start key={key} path={path}")
            try:
                if not os.path.isfile(path):
                    raise FileNotFoundError(path)

                in_bytes, in_wh = _image_info(path)
                if in_bytes <= 0:
                    raise RuntimeError(f"input file is empty (0 bytes): {path}")

                x_cpu = self.tagger.prepare_tensor_cpu(path, self.model_repo)
                self.cache.set_ready(key, x_cpu)

                dt = time.perf_counter() - t0
                _log(
                    self.debug,
                    f"[wd-daemon] preload done key={key} path={path} size={in_bytes} wh={in_wh} cache_items={len(self.cache)} dt={dt:.3f}s"
                )
            except Exception as e:
                self.cache.set_error(key, str(e))
                _log(self.debug, f"[wd-daemon][error] preload key={key} path={path!r} err={e}", err=True)
                traceback.print_exc(file=sys.stderr)
            finally:
                _safe_unlink(path, self.debug)

        self.pool.submit(_job)
        return key

    def wait_tensor(self, key: str, timeout: float | None = None) -> torch.Tensor:
        ent = self.cache.wait_ready(key, timeout=timeout)
        if ent["error"]:
            raise RuntimeError(f"preload failed for {key}: {ent['error']}")
        tensor = ent["tensor"]
        if tensor is None:
            raise RuntimeError(f"preload missing tensor for {key}")
        return tensor


# -------------------------
# HTTP server
# -------------------------
def make_handler(state, debug: bool):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def _send(self, code: int, payload: dict):
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _send_text(self, code: int, text: str):
            data = text.encode("utf-8", errors="strict")
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            u = urlparse(self.path)
            if u.path == "/health":
                return self._send(200, {"ok": True, "cache_items": len(state["tensor_cache"])})
            if u.path == "/selected_tags":
                try:
                    tags = state["tagger"].get_selected_tags()

                    if _wants_text(self):
                        sep = chr(31)
                        return self._send_text(200, sep.join(tags))

                    return self._send(200, {
                        "ok": True,
                        "model": state["model"],
                        "count": len(tags),
                        "tags": tags,
                    })
                except Exception as e:
                    if debug:
                        _log(debug, "[wd-daemon][error] GET /selected_tags", err=True)
                        traceback.print_exc(file=sys.stderr)
                    if _wants_text(self):
                        return self._send_text(500, "ERR " + str(e))
                    return self._send(500, {"ok": False, "error": str(e)})
            return self._send(404, {"ok": False, "error": "use POST /hint or POST /tag_batch"})

        def do_POST(self):
            u = urlparse(self.path)

            if u.path == "/hint":
                try:
                    n = int(self.headers.get("Content-Length", "0"))
                    body = self.rfile.read(n).decode("utf-8", errors="replace")
                    obj = json.loads(body) if body else {}

                    paths = obj.get("paths", [])
                    if not isinstance(paths, list) or not paths:
                        return self._send(400, {"ok": False, "error": "missing paths (list)"})

                    keys = []
                    for p in paths:
                        if not isinstance(p, str) or not p:
                            return self._send(400, {"ok": False, "error": "every path must be non-empty string"})
                        key = state["preload_mgr"].preload_async(p)
                        keys.append(key)

                    if _wants_text(self):
                        sep = chr(31)
                        return self._send_text(200, sep.join(keys))

                    return self._send(202, {
                        "ok": True,
                        "keys": keys,
                        "cache_items": len(state["tensor_cache"]),
                    })
                except Exception as e:
                    if debug:
                        _log(debug, "[wd-daemon][error] POST /hint", err=True)
                        traceback.print_exc(file=sys.stderr)
                    return self._send(500, {"ok": False, "error": str(e)})

            if u.path == "/tag_batch":
                req_t0 = time.perf_counter()
                _log(debug, "[wd-daemon] tag_batch request start")
                try:
                    n = int(self.headers.get("Content-Length", "0"))
                    body = self.rfile.read(n).decode("utf-8", errors="replace")
                    obj = json.loads(body) if body else {}

                    keys = obj.get("keys", [])
                    if not isinstance(keys, list) or not keys:
                        if _wants_text(self):
                            return self._send_text(400, "ERR missing keys")
                        return self._send(400, {"ok": False, "error": "missing keys (list)"})

                    gth = float(obj.get("gth", state["gth"]))
                    gmcut = bool(obj.get("gmcut", state["gmcut"]))
                    cth = float(obj.get("cth", state["cth"]))
                    cmcut = bool(obj.get("cmcut", state["cmcut"]))
                    batch_size = int(obj.get("batch", 4))
                    batch_size = max(1, min(batch_size, 64))

                    tags = handle_tag_batch_request(state, keys, gth, gmcut, cth, cmcut, debug, batch_size, req_t0)

                    total_dt = time.perf_counter() - req_t0
                    _log(debug, f"[wd-daemon] tag_batch response ready total_dt={total_dt:.3f}s")

                    if _wants_text(self):
                        sep = chr(31)
                        return self._send_text(200, sep.join(tags))

                    return self._send(200, {"ok": True, "tags": tags})

                except Exception as e:
                    if debug:
                        _log(debug, "[wd-daemon][error] POST /tag_batch", err=True)
                        traceback.print_exc(file=sys.stderr)

                    if _wants_text(self):
                        return self._send_text(500, "ERR " + str(e))

                    return self._send(500, {"ok": False, "error": str(e)})

            return self._send(404, {"ok": False, "error": "use POST /hint or POST /tag_batch"})

    return Handler


def handle_tag_batch_request(state, keys, gth, gmcut, cth, cmcut, debug: bool, batch_size: int, req_t0: float) -> list[str]:
    if not isinstance(keys, list) or not keys:
        raise ValueError("keys must be a non-empty list")

    prepared_tensors: list[torch.Tensor] = []

    t_wait0 = time.perf_counter()
    _log(debug, f"[wd-daemon] tag_batch wait-cache begin n={len(keys)} batch_size={batch_size} since_req={t_wait0 - req_t0:.3f}s")

    for idx, k in enumerate(keys):
        if not isinstance(k, str) or not k:
            raise ValueError("each key must be a non-empty string")

        ent = state["tensor_cache"].get_if_ready(k)
        ready = ent is not None
        _log(debug, f"[wd-daemon] tag_batch key[{idx}]={k} ready={ready}")

        tensor = state["preload_mgr"].wait_tensor(k, timeout=None)
        prepared_tensors.append(tensor)

    t_wait1 = time.perf_counter()
    _log(debug, f"[wd-daemon] tag_batch wait-cache done n={len(prepared_tensors)} dt={t_wait1 - t_wait0:.3f}s since_req={t_wait1 - req_t0:.3f}s")

    all_tags: list[str] = []
    t_pred0 = time.perf_counter()
    _log(debug, f"[wd-daemon] tag_batch predict begin since_req={t_pred0 - req_t0:.3f}s")

    for i in range(0, len(prepared_tensors), int(batch_size)):
        chunk_tensors = prepared_tensors[i:i + int(batch_size)]
        chunk_t0 = time.perf_counter()
        _log(debug, f"[wd-daemon] tag_batch predict chunk start offset={i} size={len(chunk_tensors)} since_req={chunk_t0 - req_t0:.3f}s")

        tags_chunk, _ratings = state["tagger"].infer_batch_from_prepared(
            chunk_tensors, state["model"], gth, gmcut, cth, cmcut
        )
        all_tags.extend(tags_chunk)

        chunk_t1 = time.perf_counter()
        _log(debug, f"[wd-daemon] tag_batch predict chunk done offset={i} size={len(chunk_tensors)} dt={chunk_t1 - chunk_t0:.3f}s since_req={chunk_t1 - req_t0:.3f}s")

    t_pred1 = time.perf_counter()
    _log(debug, f"[wd-daemon] tag_batch predict done total_tags={len(all_tags)} dt={t_pred1 - t_pred0:.3f}s since_req={t_pred1 - req_t0:.3f}s")

    t_purge0 = time.perf_counter()
    state["tensor_cache"].purge_many(keys)
    t_purge1 = time.perf_counter()
    _log(debug, f"[wd-daemon] tag_batch purge done n={len(keys)} dt={t_purge1 - t_purge0:.3f}s since_req={t_purge1 - req_t0:.3f}s")

    return all_tags


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5566)

    ap.add_argument("--model", default=os.environ.get("MODEL_REPO", "SmilingWolf/wd-swinv2-tagger-v3"))
    ap.add_argument("--gth", type=float, default=float(os.environ.get("GENERAL_THRESH", "0.35")))
    ap.add_argument("--gmcut", type=str2bool, default=str2bool(os.environ.get("GENERAL_MCUT", "false")))
    ap.add_argument("--cth", type=float, default=float(os.environ.get("CHARACTER_THRESH", "0.85")))
    ap.add_argument("--cmcut", type=str2bool, default=str2bool(os.environ.get("CHARACTER_MCUT", "false")))

    ap.add_argument("--max-side", type=int, default=int(os.environ.get("WD_MAX_SIDE", "1024")))
    ap.add_argument("--debug", type=str2bool, default=str2bool(os.environ.get("WD_DEBUG", "true")))
    ap.add_argument("--preload-workers", type=int, default=int(os.environ.get("WD_PRELOAD_WORKERS", "2")))

    args = ap.parse_args()

    tagger = LocalTagger(args.model, debug=args.debug, max_side=args.max_side)
    tensor_cache = KeyedTensorCache(debug=args.debug)
    preload_mgr = PreloadManager(
        tagger=tagger,
        cache=tensor_cache,
        model_repo=args.model,
        max_workers=args.preload_workers,
        debug=args.debug,
    )

    state = {
        "tagger": tagger,
        "tensor_cache": tensor_cache,
        "preload_mgr": preload_mgr,
        "model": args.model,
        "gth": args.gth,
        "gmcut": args.gmcut,
        "cth": args.cth,
        "cmcut": args.cmcut,
        "max_side": args.max_side,
    }

    server = ThreadingHTTPServer((args.listen, args.port), make_handler(state, args.debug))
    _log(args.debug, f"[wd-daemon] listening on http://{args.listen}:{args.port}")
    _log(args.debug, f"[wd-daemon] default model: {args.model}")
    _log(args.debug, f"[wd-daemon] resize: max_side={args.max_side}")
    _log(args.debug, f"[wd-daemon] preload_workers={args.preload_workers}")
    _log(args.debug, f"[wd-daemon] debug={args.debug}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _log(args.debug, "[wd-daemon] shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
