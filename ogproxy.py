# opencode-go codex 模型代理(Responses -> Chat Completions 转换层)
#
# 背景:
# 1. codex 只支持 wire_api="responses",而 opencode-go 的 deepseek-v4-pro 在 /responses 上
#    直接返回 400,只有 /chat/completions 可用 -> 需要转换。
# 2. codex 期望 GET /v1/models 返回 {"models":[...]},opencode-go 返回 OpenAI 标准格式,
#    导致运行时用回退元数据(桌面端显示"自定义"、通用指令模板)。
#
# 本代理:
#   GET  /v1/models           -> 返回 codex 格式模型注册表(deepseek-v4-pro 全量元数据+完整指令模板)
#   POST /v1/responses        -> 转换为 /chat/completions 请求(支持流式 SSE 与非流式)
#   POST /v1/chat/completions -> 原样转发
import json
import os
import sys
import time
import uuid
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "https://opencode.ai/zen/go/v1"
TOKEN = os.environ.get("OPENCODE_GO_API_KEY", "")
PORT = int(os.environ.get("OPENCODE_GO_PROXY_PORT", "8765"))
MODELS_CACHE = os.path.join(os.path.expanduser("~"), ".codex", "models_cache.json")
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

CONTEXT_WINDOW = 200000
MAX_CONTEXT_WINDOW = 1000000
MAX_OUTPUT = 64000

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "ogproxy-config.json")

# 订阅模型挂到 codex 已知模型名上(已知名才有工具注入)。
# 应用模型选择器会显示这些条目,选中即切换,无需重启。
DEFAULT_SLOTS = {
    "gpt-5.6-sol": {"upstream_model": "deepseek-v4-pro", "display_name": "DeepSeek V4 Pro"},
    "gpt-5.6-terra": {"upstream_model": "deepseek-v4-flash", "display_name": "DeepSeek V4 Flash"},
    "gpt-5.6-luna": {"upstream_model": "kimi-k3", "display_name": "Kimi K3"},
    "gpt-5.5": {"upstream_model": "glm-5.2", "display_name": "GLM-5.2"},
    "gpt-5.4": {"upstream_model": "qwen3.7-plus", "display_name": "Qwen3.7 Plus"},
    "gpt-5.4-mini": {"upstream_model": "gpt-5.6-luna", "display_name": "GPT-5.6 Luna"},
    "codex-auto-review": {"upstream_model": "deepseek-v4-pro", "display_name": "DeepSeek V4 Pro (review)"},
}


def load_config():
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            raw = json.load(f)
    except Exception:
        raw = {}
    slots = {}
    if isinstance(raw.get("slots"), dict):
        slots = {k: dict(v) for k, v in raw["slots"].items() if isinstance(v, dict)}
    if not slots:
        # 兼容旧格式(扁平 upstream_model/display_name)
        um = raw.get("upstream_model") or os.environ.get("OPENCODE_GO_PROXY_UPSTREAM_MODEL", "deepseek-v4-pro")
        dn = raw.get("display_name") or os.environ.get("OPENCODE_GO_PROXY_DISPLAY", "DeepSeek V4 Pro")
        slots = {k: dict(v) for k, v in DEFAULT_SLOTS.items()}
        slots["gpt-5.6-sol"] = {"upstream_model": um, "display_name": dn}
    if "gpt-5.6-sol" not in slots:
        slots["gpt-5.6-sol"] = {"upstream_model": "deepseek-v4-pro", "display_name": "DeepSeek V4 Pro"}
    return slots


SLOTS = load_config()


def save_config():
    try:
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump({"slots": SLOTS}, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


# codex 只给"已知模型"注入工具。已知模型名 -> 订阅真实模型 的映射(热切换时更新)。
MODEL_MAP = {}
for _cslug, _cfg in SLOTS.items():
    MODEL_MAP[_cslug] = _cfg["upstream_model"]
# 兜底:未配置的已知名直接透传
MODEL_MAP.setdefault("gpt-5.6-sol", "deepseek-v4-pro")


def load_template():
    try:
        with open(MODELS_CACHE, "r", encoding="utf-8") as f:
            data = json.load(f)
        for m in data.get("models", []):
            tmpl = (m.get("model_messages") or {}).get("instructions_template")
            if tmpl:
                return tmpl.replace("GPT-5", "DeepSeek V4")
    except Exception as e:
        print("[proxy] load_template failed: %s" % e, file=sys.stderr)
    return None


def model_meta_from_cache(model_id):
    # 从 opencode 的 models.json 缓存读取模型的元数据(显示名/推理档/上下文窗口)
    try:
        p = os.path.join(os.path.expanduser("~"), ".cache", "opencode", "models.json")
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
        for prov in data.values():
            if isinstance(prov, dict) and isinstance(prov.get("models"), dict):
                m = prov["models"].get(model_id)
                if m:
                    return m
    except Exception as e:
        print("[proxy] meta load failed: %s" % e, file=sys.stderr)
    return None


def _build_slot_entry(codex_slug, cfg):
    # codex 只给"已知模型"注入工具,因此 codex 侧 slug 必须是已知名;
    # 显示名/元数据按槽位对应的真实订阅模型生成,请求在 build_chat_request 里被改写。
    up = cfg.get("upstream_model") or codex_slug
    disp = cfg.get("display_name") or codex_slug
    meta = model_meta_from_cache(up) or {}
    template = load_template()

    # 输入模态:从模型元数据读取(text/image/pdf/video -> codex 的 text/image)
    modalities = ["text"]
    for mod in ((meta.get("modalities") or {}).get("input") or []):
        if mod == "text":
            pass
        elif mod in ("image", "pdf", "video"):
            if "image" not in modalities:
                modalities.append("image")
        elif mod == "audio":
            if "audio" not in modalities:
                modalities.append("audio")
    supports_image = "image" in modalities

    effort_desc = {
        "none": "No reasoning",
        "low": "Fast responses with lighter reasoning",
        "medium": "Balances speed and reasoning depth for everyday tasks",
        "high": "Greater reasoning depth for complex problems",
        "xhigh": "Extra high reasoning depth for complex problems",
        "max": "Maximum reasoning depth for the hardest problems",
        "ultra": "Maximum reasoning with automatic task delegation",
    }
    efforts = []
    for opt in (meta.get("reasoning_options") or []):
        if opt.get("type") == "effort":
            for v in opt.get("values", []):
                if v not in [e["effort"] for e in efforts]:
                    efforts.append({"effort": v, "description": effort_desc.get(v, v)})
    if not efforts:
        efforts = [{"effort": "high", "description": "Greater reasoning depth for complex problems"},
                   {"effort": "max", "description": "Maximum reasoning depth for the hardest problems"}]

    limit = meta.get("limit") or {}
    ctx = int(limit.get("context") or CONTEXT_WINDOW)
    ctx = min(max(ctx, 8000), 1000000)
    out = int(limit.get("output") or MAX_OUTPUT)
    out = min(max(out, 1000), 256000)

    entry = {
        "slug": codex_slug,
        "display_name": disp,
        "description": meta.get("description") or "Model from OpenCode Go subscription (routed via proxy)",
        "default_reasoning_level": efforts[0]["effort"],
        "supported_reasoning_levels": efforts,
        "shell_type": "shell_command",
        "visibility": "list",
        "supported_in_api": True,
        "priority": 1,
        "additional_speed_tiers": ["fast"],
        "service_tiers": [
            {"id": "priority", "name": "Fast", "description": "1.5x speed, increased usage"}
        ],
        "default_reasoning_summary": "none",
        "support_verbosity": True,
        "default_verbosity": "medium",
        "apply_patch_tool_type": "freeform",
        "web_search_tool_type": "text",
        "truncation_policy": {"mode": "tokens", "limit": out},
        "supports_parallel_tool_calls": bool(meta.get("tool_call", True)),
        "supports_image_detail_original": supports_image,
        "context_window": ctx,
        "max_context_window": ctx,
        "effective_context_window_percent": 95,
        "experimental_supported_tools": [],
        "input_modalities": modalities,
        "supports_search_tool": False,
        # 关键:必须是 False。lite 模式下工具以文本塞进 input,deepseek 不会用该文本协议,
        # 会导致永远不调用工具。非 lite 才走原生 tools 数组(deepseek 的函数调用)。
        "use_responses_lite": False,
        # direct:完整扁平工具列表(shell_command 等)。code_mode_only 会把工具嵌套进 exec/wait,
        # 模型拿到的是 5 个包装工具,体验差。
        "tool_mode": "direct",
        "multi_agent_version": "v2",
    }
    if template:
        entry["model_messages"] = {"instructions_template": template}
    else:
        entry["base_instructions"] = (
            "You are Codex, an agent based on %s. You and the user share one "
            "workspace, and your job is to collaborate with them until their goal is genuinely "
            "handled. Use tools when appropriate, and keep responses concise." % disp
        )
    return entry


def build_payload():
    return {"models": [_build_slot_entry(cslug, cfg) for cslug, cfg in SLOTS.items()]}


PAYLOAD = build_payload()


def message_text_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for p in content:
            if isinstance(p, str):
                parts.append(p)
            elif isinstance(p, dict) and p.get("type") in ("input_text", "output_text"):
                parts.append(p.get("text", ""))
            elif isinstance(p, dict) and p.get("type") == "text":
                parts.append(p.get("text", ""))
        return "\n".join(parts)
    return ""


def message_content_to_chat(content):
    """把 responses 的 content 部分转成 chat 格式。
    纯文本 -> str;含图片 -> [{type:text}, {type:image_url,...}] 数组。"""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    has_image = False
    for p in content:
        if isinstance(p, str):
            parts.append({"type": "text", "text": p})
        elif not isinstance(p, dict):
            continue
        pt = p.get("type")
        if pt in ("input_text", "output_text", "text"):
            parts.append({"type": "text", "text": p.get("text", "")})
        elif pt == "input_image":
            url = p.get("image_url")
            if not url and p.get("data") and p.get("media_type"):
                url = "data:%s;base64,%s" % (p.get("media_type"), p.get("data"))
            if url:
                detail = p.get("detail") or "auto"
                parts.append({"type": "image_url", "image_url": {"url": url, "detail": detail}})
                has_image = True
            else:
                # file_id 引用本地解析不了,丢弃
                continue
    if not parts:
        return ""
    if not has_image:
        return "".join(pt.get("text", "") for pt in parts)
    return parts


def responses_input_to_messages(req):
    messages = []
    instructions = req.get("instructions")
    if instructions:
        messages.append({"role": "system", "content": instructions})
    inp = req.get("input")
    if inp is None:
        return messages
    if isinstance(inp, str):
        messages.append({"role": "user", "content": inp})
        return messages
    pending_call_ids = []
    pending_reasoning = None
    merged_assistant = None  # 合并连续 function_call 为一条 assistant(tool_calls)
    for item in inp:
        t = item.get("type")
        if t == "reasoning":
            texts = []
            for c in (item.get("content") or []):
                if isinstance(c, dict):
                    if c.get("type") in ("reasoning_text", "reasoning_summary_text"):
                        texts.append(c.get("text", ""))
                    elif c.get("type") == "output_text":
                        texts.append(c.get("text", ""))
            if texts:
                pending_reasoning = "\n".join(texts)
            continue
        if t == "message":
            merged_assistant = None
            role = item.get("role", "user")
            if role == "developer":
                role = "system"
            content = message_content_to_chat(item.get("content"))
            if content:
                msg = {"role": role, "content": content}
                if role == "assistant" and pending_reasoning:
                    msg["reasoning_content"] = pending_reasoning
                    pending_reasoning = None
                messages.append(msg)
        elif t == "function_call":
            name = item.get("name")
            status = item.get("status", "completed")
            if status in ("incomplete", "failed", "cancelled") or not name:
                merged_assistant = None
                continue
            call_id = item.get("call_id") or ("call_" + uuid.uuid4().hex[:24])
            pending_call_ids.append(call_id)
            tc = {
                "id": call_id,
                "type": "function",
                "function": {"name": name, "arguments": item.get("arguments", "")},
            }
            if merged_assistant is None:
                merged_assistant = {"role": "assistant", "content": None, "tool_calls": []}
                if pending_reasoning:
                    merged_assistant["reasoning_content"] = pending_reasoning
                    pending_reasoning = None
                messages.append(merged_assistant)
            merged_assistant["tool_calls"].append(tc)
        elif t == "function_call_output":
            merged_assistant = None
            call_id = item.get("call_id") or (pending_call_ids[-1] if pending_call_ids else "")
            if pending_call_ids:
                pending_call_ids.pop()
            out = item.get("output")
            if isinstance(out, (dict, list)):
                out = json.dumps(out, ensure_ascii=False)
            elif out is None:
                out = ""
            messages.append({"role": "tool", "tool_call_id": call_id, "content": str(out)})
        elif t in ("web_search_call", "web_search_call_output"):
            merged_assistant = None
            continue
    # 后处理:上游要求"带 tool_calls 的 assistant 消息必须紧跟对应 tool 消息"。
    # 成对消费:assistant(tool_calls) 后紧跟的 tool 消息若覆盖全部 call_id 则保留,
    # 否则去掉该 tool_calls(空内容则丢弃);孤儿 tool 消息直接丢弃。
    cleaned = []
    i = 0
    n = len(messages)
    while i < n:
        msg = messages[i]
        if msg.get("tool_calls"):
            need = {tc["id"] for tc in msg["tool_calls"]}
            j = i + 1
            got = set()
            while j < n and messages[j].get("role") == "tool":
                got.add(messages[j].get("tool_call_id"))
                j += 1
            if need.issubset(got):
                cleaned.append(msg)
                i += 1
                while i < n and messages[i].get("role") == "tool":
                    if messages[i].get("tool_call_id") in need:
                        cleaned.append(messages[i])
                    i += 1
            else:
                stripped = {kk: vv for kk, vv in msg.items() if kk != "tool_calls"}
                if stripped.get("content"):
                    cleaned.append(stripped)
                i += 1
        elif msg.get("role") == "tool":
            i += 1
        else:
            cleaned.append(msg)
            i += 1
    return cleaned


def build_chat_request(req):
    body = {
        "model": MODEL_MAP.get(req.get("model"), req.get("model")),
        "messages": responses_input_to_messages(req),
        "stream": bool(req.get("stream", True)),
    }
    tools = []
    for t in (req.get("tools") or []):
        if t.get("type") == "function":
            fn = {
                "name": t.get("name"),
                "description": t.get("description"),
                "parameters": t.get("parameters") or {"type": "object", "properties": {}},
            }
            if t.get("strict") is not None:
                fn["strict"] = t["strict"]
            tools.append({"type": "function", "function": fn})
    if tools:
        body["tools"] = tools
    for k, dst in (
        ("max_output_tokens", "max_tokens"),
        ("temperature", "temperature"),
        ("top_p", "top_p"),
        ("parallel_tool_calls", "parallel_tool_calls"),
    ):
        if req.get(k) is not None:
            body[dst] = req[k]
    return body


def now():
    return int(time.time())


def base_response(model, status="completed"):
    return {
        "id": "resp_" + uuid.uuid4().hex,
        "object": "response",
        "created_at": now(),
        "status": status,
        "error": None,
        "incomplete_details": None,
        "instructions": None,
        "max_output_tokens": None,
        "model": model,
        "output": [],
        "parallel_tool_calls": True,
        "previous_response_id": None,
        "reasoning": None,
        "store": False,
        "temperature": None,
        "text": None,
        "tool_choice": "auto",
        "tools": [],
        "top_p": None,
        "truncation": "disabled",
        "usage": None,
        "user": None,
        "metadata": {},
    }


def chat_completion_to_response(chat, model, instructions=None):
    resp = base_response(model)
    msg = chat.get("choices", [{}])[0].get("message") or {}
    finish = chat.get("choices", [{}])[0].get("finish_reason")
    resp["status"] = "completed" if finish in ("stop", "tool_calls", None) else "incomplete"
    resp["instructions"] = instructions
    usage = chat.get("usage")
    if usage:
        resp["usage"] = {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
            "total_tokens": usage.get("total_tokens", 0),
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens_details": {"reasoning_tokens": 0},
        }
    text = msg.get("content")
    reasoning = msg.get("reasoning_content")
    if reasoning:
        resp["output"].append({
            "id": "rs_" + uuid.uuid4().hex,
            "type": "reasoning",
            "status": "completed",
            "summary": [],
            "content": [{"type": "reasoning_text", "text": reasoning, "annotations": []}],
        })
    if text:
        resp["output"].append({
            "id": "msg_" + uuid.uuid4().hex,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text, "annotations": []}],
        })
    for tc in (msg.get("tool_calls") or []):
        fn = tc.get("function") or {}
        resp["output"].append({
            "id": "fc_" + uuid.uuid4().hex,
            "type": "function_call",
            "status": "completed",
            "call_id": tc.get("id", ""),
            "name": fn.get("name", ""),
            "arguments": fn.get("arguments", ""),
        })
    return resp


class StreamTranslator:
    def __init__(self, wfile):
        self.wfile = wfile
        self.seq = 0
        self.resp = None
        self.output = []
        self.cur_item = None
        self.cur_item_index = -1
        self.cur_part_index = -1
        self.cur_text = ""
        self.msg_started = False
        self.tc_state = {}
        self.reasoning_item = None
        self.reasoning_text = ""

    def emit(self, name, data):
        data["type"] = name
        data["sequence_number"] = self.seq
        self.seq += 1
        payload = "event: %s\ndata: %s\n\n" % (name, json.dumps(data, ensure_ascii=False))
        self.wfile.write(payload.encode("utf-8"))
        self.wfile.flush()

    def start(self, model, instructions):
        self.resp = base_response(model, "in_progress")
        self.resp["instructions"] = instructions
        self.emit("response.created", {"response": self.resp})
        self.emit("response.in_progress", {"response": self.resp})

    def _start_reasoning(self):
        if self.reasoning_item is not None:
            return
        self.cur_item_index += 1
        self.reasoning_item = {
            "id": "rs_" + uuid.uuid4().hex,
            "type": "reasoning",
            "status": "in_progress",
            "summary": [],
            "content": [{"type": "reasoning_text", "text": "", "annotations": []}],
        }
        self.output.append(self.reasoning_item)
        self.emit("response.output_item.added", {
            "output_index": self.cur_item_index,
            "item": json.loads(json.dumps(self.reasoning_item)),
        })
        self.emit("response.content_part.added", {
            "item_id": self.reasoning_item["id"],
            "output_index": self.cur_item_index,
            "content_index": 0,
            "part": {"type": "reasoning_text", "text": "", "annotations": []},
        })

    def reasoning_delta(self, chunk):
        if not chunk:
            return
        self._start_reasoning()
        self.reasoning_text += chunk
        self.emit("response.reasoning_text.delta", {
            "item_id": self.reasoning_item["id"],
            "output_index": self.cur_item_index,
            "content_index": 0,
            "delta": chunk,
        })

    def _finish_reasoning(self):
        if self.reasoning_item is None:
            return
        item = self.reasoning_item
        item["status"] = "completed"
        item["content"][0]["text"] = self.reasoning_text
        self.emit("response.reasoning_text.done", {
            "item_id": item["id"],
            "output_index": self.cur_item_index,
            "content_index": 0,
            "text": self.reasoning_text,
        })
        self.emit("response.content_part.done", {
            "item_id": item["id"],
            "output_index": self.cur_item_index,
            "content_index": 0,
            "part": {"type": "reasoning_text", "text": self.reasoning_text, "annotations": []},
        })
        self.emit("response.output_item.done", {
            "output_index": self.cur_item_index,
            "item": json.loads(json.dumps(item)),
        })
        self.reasoning_item = None

    def _start_message(self):
        if self.msg_started:
            return
        self.msg_started = True
        self.cur_item_index += 1
        self.cur_item = {
            "id": "msg_" + uuid.uuid4().hex,
            "type": "message",
            "status": "in_progress",
            "role": "assistant",
            "content": [],
        }
        self.output.append(self.cur_item)
        self.emit("response.output_item.added", {
            "output_index": self.cur_item_index,
            "item": json.loads(json.dumps(self.cur_item)),
        })
        self.cur_part_index = 0
        self.cur_text = ""
        self.cur_item["content"].append({"type": "output_text", "text": "", "annotations": []})
        self.emit("response.content_part.added", {
            "item_id": self.cur_item["id"],
            "output_index": self.cur_item_index,
            "content_index": 0,
            "part": {"type": "output_text", "text": "", "annotations": []},
        })

    def text_delta(self, chunk):
        self._start_message()
        if not chunk:
            return
        self.cur_text += chunk
        self.emit("response.output_text.delta", {
            "item_id": self.cur_item["id"],
            "output_index": self.cur_item_index,
            "content_index": 0,
            "delta": chunk,
        })

    def _finish_message(self):
        if not self.msg_started:
            return
        self.cur_item["status"] = "completed"
        self.cur_item["content"][0]["text"] = self.cur_text
        self.emit("response.output_text.done", {
            "item_id": self.cur_item["id"],
            "output_index": self.cur_item_index,
            "content_index": 0,
            "text": self.cur_text,
        })
        self.emit("response.content_part.done", {
            "item_id": self.cur_item["id"],
            "output_index": self.cur_item_index,
            "content_index": 0,
            "part": {"type": "output_text", "text": self.cur_text, "annotations": []},
        })
        self.emit("response.output_item.done", {
            "output_index": self.cur_item_index,
            "item": json.loads(json.dumps(self.cur_item)),
        })

    def tool_call_delta(self, idx, tc):
        state = self.tc_state.get(idx)
        if state is None:
            self.cur_item_index += 1
            state = {
                "item": {
                    "id": "fc_" + uuid.uuid4().hex,
                    "type": "function_call",
                    "status": "in_progress",
                    "call_id": tc.get("id") or ("call_" + uuid.uuid4().hex[:24]),
                    "name": (tc.get("function") or {}).get("name", "") or "",
                    "arguments": "",
                },
                "index": self.cur_item_index,
            }
            self.tc_state[idx] = state
            self.output.append(state["item"])
            self.emit("response.output_item.added", {
                "output_index": state["index"],
                "item": json.loads(json.dumps(state["item"])),
            })
        else:
            if tc.get("id"):
                state["item"]["call_id"] = tc["id"]
            name = (tc.get("function") or {}).get("name")
            if name:
                state["item"]["name"] += name
        delta = (tc.get("function") or {}).get("arguments")
        if delta:
            state["item"]["arguments"] += delta
            self.emit("response.function_call_arguments.delta", {
                "item_id": state["item"]["id"],
                "output_index": state["index"],
                "delta": delta,
            })

    def _finish_tool_calls(self):
        for idx in sorted(self.tc_state.keys()):
            state = self.tc_state[idx]
            item = state["item"]
            item["status"] = "completed"
            self.emit("response.function_call_arguments.done", {
                "item_id": item["id"],
                "output_index": state["index"],
                "arguments": item["arguments"],
            })
            self.emit("response.output_item.done", {
                "output_index": state["index"],
                "item": json.loads(json.dumps(item)),
            })

    def finish(self, finish_reason, usage):
        self._finish_message()
        self._finish_tool_calls()
        status = "completed" if finish_reason in ("stop", "tool_calls") else "incomplete"
        self.resp["status"] = status
        self.resp["output"] = self.output
        if usage:
            self.resp["usage"] = {
                "input_tokens": usage.get("prompt_tokens", 0),
                "output_tokens": usage.get("completion_tokens", 0),
                "total_tokens": usage.get("total_tokens", 0),
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens_details": {"reasoning_tokens": 0},
            }
        self.emit("response.completed", {"response": self.resp})

    def feed_chunk(self, obj):
        if obj.get("error"):
            self.resp["error"] = obj["error"]
            self.resp["status"] = "failed"
            self.emit("response.failed", {"response": self.resp})
            return True
        for choice in (obj.get("choices") or []):
            delta = choice.get("delta") or {}
            if delta.get("reasoning_content"):
                self.reasoning_delta(delta["reasoning_content"])
            if delta.get("content"):
                self._finish_reasoning()
                self.text_delta(delta["content"])
            for tc in (delta.get("tool_calls") or []):
                self._finish_reasoning()
                self.tool_call_delta(tc.get("index", 0), tc)
            fr = choice.get("finish_reason")
            if fr:
                self._finish_reasoning()
                self.finish(fr, obj.get("usage"))
                return True
        return False


def _dump_chat_req(chat_req):
    try:
        with open(os.path.join(os.path.expanduser("~"), ".codex", "ogproxy-upstream.log"), "a", encoding="utf-8") as lf:
            lf.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), json.dumps(chat_req, ensure_ascii=False)))
    except Exception:
        pass


def proxy_chat_stream(self, chat_req, model, instructions):
    self.send_response(200)
    self.send_header("Content-Type", "text/event-stream")
    self.send_header("Cache-Control", "no-cache")
    self.send_header("Connection", "close")
    self.end_headers()
    self.close_connection = True
    tr = StreamTranslator(self.wfile)
    tr.start(model, instructions)
    _dump_chat_req(chat_req)
    body = json.dumps(chat_req).encode("utf-8")
    headers = {
        "Authorization": "Bearer " + TOKEN,
        "Content-Type": "application/json",
        "User-Agent": UA,
    }
    req = urllib.request.Request(UPSTREAM + "/chat/completions", data=body, method="POST", headers=headers)
    try:
        resp = urllib.request.urlopen(req, timeout=600)
        finished = False
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
            except Exception:
                continue
            if tr.feed_chunk(obj):
                finished = True
                break
        if not finished:
            tr.finish("stop", None)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", "replace")
        tr.resp["status"] = "failed"
        tr.resp["error"] = {"type": "server_error", "message": "upstream %s: %s" % (e.code, err_body[:500])}
        tr.emit("response.failed", {"response": tr.resp})
    except Exception as e:
        tr.resp["status"] = "failed"
        tr.resp["error"] = {"type": "server_error", "message": str(e)}
        tr.emit("response.failed", {"response": tr.resp})


def proxy_chat_nonstream(self, chat_req, model, instructions):
    _dump_chat_req(chat_req)
    body = json.dumps(chat_req).encode("utf-8")
    headers = {
        "Authorization": "Bearer " + TOKEN,
        "Content-Type": "application/json",
        "User-Agent": UA,
    }
    req = urllib.request.Request(UPSTREAM + "/chat/completions", data=body, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            chat = json.loads(resp.read().decode("utf-8", "replace"))
        out = chat_completion_to_response(chat, model, instructions)
        raw = json.dumps(out, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", "replace")
        self._send_json(e.code, {"error": {"message": "upstream: " + err_body[:500]}})
    except Exception as e:
        self._send_json(502, {"error": {"message": str(e)}})


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[proxy] %s\n" % (fmt % args))

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _forward(self, method, path):
        url = UPSTREAM + path
        length = int(self.headers.get("Content-Length", 0) or 0)
        data = self.rfile.read(length) if length else None
        headers = {
            "Authorization": "Bearer " + TOKEN,
            "Content-Type": self.headers.get("Content-Type", "application/json"),
            "User-Agent": UA,
        }
        for h in ("OpenAI-Organization", "OpenAI-Project", "User-Agent"):
            if self.headers.get(h):
                headers[h] = self.headers[h]
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                body = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            self._send_json(502, {"error": {"message": str(e)}})

    def do_GET(self):
        path = self.path.split("?")[0]
        if path.endswith("/models"):
            self._send_json(200, PAYLOAD)
        elif path.endswith("/current-model"):
            default = SLOTS.get("gpt-5.6-sol", {})
            self._send_json(200, {
                "codex_model": "gpt-5.6-sol",
                "upstream_model": default.get("upstream_model", "deepseek-v4-pro"),
                "display_name": default.get("display_name", "DeepSeek V4 Pro"),
            })
        else:
            self._forward("GET", self.path)

    def do_switch(self, body):
        global PAYLOAD, MODEL_MAP
        cslug = body.get("codex_model") or "gpt-5.6-sol"
        up = body.get("upstream_model")
        if not up or not isinstance(up, str):
            self._send_json(400, {"error": {"message": "missing upstream_model"}})
            return
        slot = SLOTS.setdefault(cslug, {"upstream_model": up})
        slot["upstream_model"] = up
        if body.get("display_name"):
            slot["display_name"] = body["display_name"]
        MODEL_MAP[cslug] = up
        PAYLOAD = build_payload()
        save_config()
        sys.stderr.write("[proxy] switched slot %s -> %s\n" % (cslug, up))
        self._send_json(200, {
            "ok": True,
            "codex_model": cslug,
            "upstream_model": up,
            "display_name": slot.get("display_name"),
        })

    def do_POST(self):
        path = self.path.split("?")[0]
        if path.endswith("/switch-model"):
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                self._send_json(400, {"error": {"message": "bad json"}})
                return
            self.do_switch(body)
        elif path.endswith("/responses"):
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                req = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                self._send_json(400, {"error": {"message": "bad json"}})
                return
            try:
                with open(os.path.join(os.path.expanduser("~"), ".codex", "ogproxy-requests.log"), "a", encoding="utf-8") as lf:
                    tools = req.get("tools") or []
                    inp = req.get("input")
                    n_items = len(inp) if isinstance(inp, list) else 1
                    types = {}
                    if isinstance(inp, list):
                        for it in inp:
                            t = it.get("type", "?")
                            types[t] = types.get(t, 0) + 1
                    lf.write("%s model=%s stream=%s tools=%d items=%d item_types=%s tool_names=%s\n" % (
                        time.strftime("%Y-%m-%dT%H:%M:%S"),
                        req.get("model"), req.get("stream"), len(tools), n_items,
                        json.dumps(types, ensure_ascii=False),
                        json.dumps([t.get("name") or t.get("type") for t in tools][:40], ensure_ascii=False),
                    ))
            except Exception:
                pass
            chat_req = build_chat_request(req)
            default_slug = "gpt-5.6-sol" if "gpt-5.6-sol" in SLOTS else next(iter(SLOTS))
            model = req.get("model") or default_slug
            if chat_req.get("stream"):
                proxy_chat_stream(self, chat_req, model, req.get("instructions"))
            else:
                proxy_chat_nonstream(self, chat_req, model, req.get("instructions"))
        elif path.endswith("/chat/completions"):
            self._forward("POST", self.path)
        else:
            self._forward("POST", self.path)


def main():
    if not TOKEN:
        print("OPENCODE_GO_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write("opencode-go proxy listening on 127.0.0.1:%d slots=%s\n" % (
        PORT, ",".join("%s->%s" % (k, v.get("upstream_model")) for k, v in SLOTS.items())))
    server.serve_forever()


if __name__ == "__main__":
    main()
