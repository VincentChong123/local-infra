#!/usr/bin/env python3
"""OpenTelemetry step exporter for Antigravity CLI PostToolUse & Stop hooks.

Receives tool and turn execution metadata via stdin from Antigravity CLI, constructs
OpenTelemetry spans correlated with the conversation trace ID, and exports them to Langfuse.

Follows strict environment validation (no_env_fallback): defaults live only in the root .env.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import random
import socket
import subprocess
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlparse, urlunparse

logger = logging.getLogger("export_agy_otel_to_langfuse")


def load_env_file(env_path: Path) -> dict[str, str]:
    """Parse key=value pairs from .env with fallback if python-dotenv is not installed."""
    if not env_path.is_file():
        return {}

    try:
        from dotenv import dotenv_values

        values = dotenv_values(env_path)
        return {k: str(v) for k, v in values.items() if v is not None}
    except ImportError:
        pass

    env_vars: dict[str, str] = {}
    with open(env_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip().strip("'\"")
            env_vars[k] = v
    return env_vars


def parse_iso_to_ns(iso_str: str | None) -> int:
    """Parse ISO-8601 timestamp string from transcript to epoch nanoseconds."""
    if not iso_str:
        return int(datetime.now(UTC).timestamp() * 1_000_000_000)
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return int(dt.timestamp() * 1_000_000_000)
    except (ValueError, TypeError):
        return int(datetime.now(UTC).timestamp() * 1_000_000_000)


def extract_turn_steps(
    transcript_path: str | None,
) -> tuple[dict | None, list[dict], str]:
    """Extract current turn (user prompt, planner generations, tool results) from transcript."""
    if not transcript_path or not os.path.isfile(transcript_path):
        return None, [], ""

    full_path = Path(transcript_path).parent / "transcript_full.jsonl"
    target_file = full_path if full_path.is_file() else Path(transcript_path)

    steps: list[dict] = []
    try:
        with open(target_file, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        steps.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"[export_agy_otel_to_langfuse] Failed reading transcript: {exc}\n")
        return None, [], ""

    if not steps:
        return None, [], ""

    # Locate the beginning of the latest turn (the most recent USER_INPUT step)
    last_user_idx = -1
    for i in range(len(steps) - 1, -1, -1):
        if steps[i].get("source") == "USER_EXPLICIT" and steps[i].get("type") == "USER_INPUT":
            last_user_idx = i
            break

    user_step = steps[last_user_idx] if last_user_idx != -1 else steps[0]
    turn_steps = steps[last_user_idx + 1 :] if last_user_idx != -1 else steps

    final_response = ""
    for s in reversed(turn_steps):
        if s.get("source") == "MODEL" and s.get("type") == "PLANNER_RESPONSE" and s.get("content"):
            final_response = str(s.get("content", ""))
            break

    return user_step, turn_steps, final_response


def deterministic_span_id(conv_id: str, key: str) -> int:
    """Generate a consistent 64-bit unsigned integer span ID from a conversation and key."""
    val = int(hashlib.sha256(f"{conv_id}:{key}".encode()).hexdigest()[:16], 16)
    return val if val != 0 else 1


def resolve_sandbox_url(url: str, default_port: int = 3100) -> str:
    """If url points to loopback and loopback is unreachable, auto-resolve to host gateway."""
    if not ("127.0.0.1" in url or "localhost" in url):
        return url

    parsed = urlparse(url)
    target_port = parsed.port or default_port

    def is_port_open(host: str, port: int) -> bool:
        try:
            with socket.create_connection((host, port), timeout=0.15):
                return True
        except OSError:
            return False

    if is_port_open(parsed.hostname or "127.0.0.1", target_port):
        return url

    # Probe potential host addresses from environment, routing table, or alias
    candidates: list[str] = []
    if os.environ.get("HOST_GATEWAY_IP"):
        candidates.append(os.environ["HOST_GATEWAY_IP"])
    try:
        res = subprocess.run(
            ["ip", "route", "show", "default"],
            capture_output=True,
            text=True,
            timeout=0.5,
            check=False,
        )
        parts = res.stdout.strip().split()
        if "via" in parts:
            candidates.append(parts[parts.index("via") + 1])
    except (subprocess.SubprocessError, OSError):
        pass
    candidates.append("host.docker.internal")

    for candidate in candidates:
        if candidate and is_port_open(candidate, target_port):
            netloc = f"{candidate}:{target_port}" if parsed.port else candidate
            new_parsed = parsed._replace(netloc=netloc)
            resolved = urlunparse(new_parsed)
            sys.stderr.write(
                f"[export_agy_otel_to_langfuse] Auto-detected host gateway: {resolved}\n"
            )
            return resolved

    return url


def export_step() -> None:
    # 0. Prevent blocking when executed manually in an interactive terminal
    if sys.stdin.isatty():
        sys.stderr.write(
            "[export_agy_otel_to_langfuse] Notice: Stdin is interactive (TTY). "
            "To test, pipe JSON input: "
            "echo '{\"toolCall\":...}' | python scripts/export_agy_otel_to_langfuse.py\n"
        )
        sys.stdout.write("{}\n")
        sys.stdout.flush()
        return

    # 1. Read PostToolUse payload from stdin
    try:
        raw_input = sys.stdin.read()
        payload = json.loads(raw_input) if raw_input.strip() else {}
    except (json.JSONDecodeError, OSError):
        payload = {}

    # PostToolUse contract expects an empty JSON object on stdout
    sys.stdout.write("{}\n")
    sys.stdout.flush()

    if not payload:
        sys.stderr.write("[export_agy_otel_to_langfuse] Empty payload received, skipping.\n")
        return

    is_stop_event = "terminationReason" in payload or "executionNum" in payload
    conv_id = payload.get("conversationId", str(uuid.uuid4()))
    error_msg = payload.get("error")
    model_name = payload.get("modelName", "agent")
    transcript_path = payload.get("transcriptPath")

    # Optimization: Intermediate PostToolUse hook calls can be skipped to avoid ~170ms overhead
    # per step, delegating full hierarchical trace export to the Stop hook.
    export_on_tool = os.environ.get("AGY_EXPORT_ON_TOOL_USE", "false").lower() in (
        "true",
        "1",
    )
    if not is_stop_event and not export_on_tool:
        return

    # 2. Resolve configuration from project root .env (or CWD .env)
    dotenv_path = Path.cwd() / ".env"
    if not dotenv_path.is_file():
        dotenv_path = Path(__file__).resolve().parent.parent / ".env"
    dotenv = load_env_file(dotenv_path)

    # Respect IS_LANGFUSE_ENABLED toggle
    is_enabled_str = os.environ.get("IS_LANGFUSE_ENABLED") or dotenv.get("IS_LANGFUSE_ENABLED")
    if is_enabled_str is not None and is_enabled_str.strip().lower() != "true":
        return

    # Strictly require URL from env or dotenv (fail fast, no fallback)
    raw_url = (
        os.environ.get("LANGFUSE_SERVER_URL_AGY")
        or dotenv.get("LANGFUSE_SERVER_URL_AGY")
        or os.environ.get("LANGFUSE_SERVER_URL")
        or dotenv.get("LANGFUSE_SERVER_URL")
    )
    if not raw_url:
        raise RuntimeError("LANGFUSE_SERVER_URL (or LANGFUSE_SERVER_URL_AGY) must be set in .env")

    # Expand variable references using strictly defined values
    if "${LANGFUSE_CONNECT_IP}" in raw_url:
        conn_ip = os.environ.get("LANGFUSE_CONNECT_IP") or dotenv.get("LANGFUSE_CONNECT_IP")
        if not conn_ip:
            raise RuntimeError("LANGFUSE_CONNECT_IP must be set in .env")
        raw_url = raw_url.replace("${LANGFUSE_CONNECT_IP}", conn_ip)

    if "${LANGFUSE_UI_PORT}" in raw_url:
        ui_port = os.environ.get("LANGFUSE_UI_PORT") or dotenv.get("LANGFUSE_UI_PORT")
        if not ui_port:
            raise RuntimeError("LANGFUSE_UI_PORT must be set in .env")
        raw_url = raw_url.replace("${LANGFUSE_UI_PORT}", ui_port)

    langfuse_url = raw_url.rstrip("/")

    # Dynamic fallback to host gateway if loopback in sandbox is unreachable
    langfuse_url = resolve_sandbox_url(langfuse_url)

    # Prioritize dedicated AGY credentials, falling back to general project credentials
    public_key = (
        os.environ.get("LANGFUSE_PUBLIC_KEY_AGY")
        or dotenv.get("LANGFUSE_PUBLIC_KEY_AGY")
        or os.environ.get("LANGFUSE_SECRET_PUBLIC_KEY_AGY")
        or dotenv.get("LANGFUSE_SECRET_PUBLIC_KEY_AGY")
        or os.environ.get("LANGFUSE_PUBLIC_KEY")
        or dotenv.get("LANGFUSE_PUBLIC_KEY")
    )
    secret_key = (
        os.environ.get("LANGFUSE_SECRET_KEY_AGY")
        or dotenv.get("LANGFUSE_SECRET_KEY_AGY")
        or os.environ.get("LANGFUSE_SECRET_KEY")
        or dotenv.get("LANGFUSE_SECRET_KEY")
    )

    if not public_key:
        raise RuntimeError("LANGFUSE_PUBLIC_KEY (or LANGFUSE_PUBLIC_KEY_AGY) must be set in .env")
    if not secret_key:
        raise RuntimeError("LANGFUSE_SECRET_KEY (or LANGFUSE_SECRET_KEY_AGY) must be set in .env")

    try:
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
            OTLPSpanExporter,
        )
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import SimpleSpanProcessor
        from opentelemetry.sdk.trace.id_generator import IdGenerator
        from opentelemetry.trace import (
            NonRecordingSpan,
            SpanContext,
            StatusCode,
            TraceFlags,
            set_span_in_context,
        )

        # Map conversationId (UUID) into the 128-bit OTel trace_id
        clean_uuid = conv_id.replace("-", "")
        trace_id = (
            int(clean_uuid, 16)
            if len(clean_uuid) == 32
            else uuid.uuid5(uuid.NAMESPACE_DNS, conv_id).int
        )

        class FixedTraceIdGenerator(IdGenerator):
            def __init__(self, tid: int) -> None:
                self._tid = tid

            def generate_span_id(self) -> int:
                return random.getrandbits(64)

            def generate_trace_id(self) -> int:
                return self._tid

        # Resource attributes identifying the agent session
        resource = Resource.create(
            {
                "service.name": "antigravity-cli",
                "telemetry.sdk.language": "python",
                "yolo.mode": "true",
                "session.id": conv_id,
            }
        )

        provider = TracerProvider(
            resource=resource,
            id_generator=FixedTraceIdGenerator(trace_id),
        )

        auth_token = base64.b64encode(f"{public_key}:{secret_key}".encode()).decode()
        exporter = OTLPSpanExporter(
            endpoint=f"{langfuse_url}/api/public/otel/v1/traces",
            headers={
                "Authorization": f"Basic {auth_token}",
                "x-langfuse-ingestion-version": "4",
            },
            timeout=3,
        )
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        tracer = provider.get_tracer("antigravity-otel-exporter")

        if is_stop_event:
            user_step, turn_steps, final_response = extract_turn_steps(transcript_path)
            now_ns = int(datetime.now(UTC).timestamp() * 1_000_000_000)
            turn_start_ns = parse_iso_to_ns(user_step.get("created_at")) if user_step else now_ns
            turn_end_ns = now_ns
            user_prompt = (
                str(user_step.get("content", "")) if user_step else payload.get("lastUserInput", "")
            )

            # 1. Root Span (covers the whole turn timeline)
            root_span = tracer.start_span("agent:turn", start_time=turn_start_ns)
            root_span.set_attribute("session.id", conv_id)
            root_span.set_attribute("langfuse.observation.type", "SPAN")
            root_span.set_attribute("input.value", user_prompt)
            root_span.set_attribute("output.value", final_response)
            root_ctx = set_span_in_context(root_span)

            # 2. Iterate steps and construct Gantt chart hierarchy
            if turn_steps:
                for i, step in enumerate(turn_steps):
                    s_type = step.get("type")
                    step_start_ns = parse_iso_to_ns(step.get("created_at"))
                    next_start_ns = (
                        parse_iso_to_ns(turn_steps[i + 1].get("created_at"))
                        if i + 1 < len(turn_steps)
                        else turn_end_ns
                    )

                    if s_type == "PLANNER_RESPONSE":
                        is_final = i == len(turn_steps) - 1 or not step.get("tool_calls")
                        name = (
                            "agent:response"
                            if is_final
                            else f"planner:step_{step.get('step_index')}"
                        )
                        gen_span = tracer.start_span(
                            name, context=root_ctx, start_time=step_start_ns
                        )
                        gen_span.set_attribute("langfuse.observation.type", "GENERATION")
                        gen_span.set_attribute("model.name", model_name)
                        gen_span.set_attribute("gen_ai.request.model", model_name)

                        in_tok = step.get("input_tokens") or 0
                        out_tok = step.get("output_tokens") or 0
                        if in_tok:
                            gen_span.set_attribute("gen_ai.usage.prompt_tokens", in_tok)
                        if out_tok:
                            gen_span.set_attribute("gen_ai.usage.completion_tokens", out_tok)
                        if in_tok or out_tok:
                            gen_span.set_attribute("gen_ai.usage.total_tokens", in_tok + out_tok)

                        content = step.get("content") or step.get("thinking") or ""
                        gen_span.set_attribute("output.value", content)
                        gen_ctx = set_span_in_context(gen_span)

                        # If this planner called a tool, nested tool span executes next
                        if i + 1 < len(turn_steps) and turn_steps[i + 1].get("type") == "GENERIC":
                            tool_step = turn_steps[i + 1]
                            tool_start_ns = parse_iso_to_ns(tool_step.get("created_at"))
                            tool_end_ns = (
                                parse_iso_to_ns(turn_steps[i + 2].get("created_at"))
                                if i + 2 < len(turn_steps)
                                else next_start_ns
                            )
                            tool_calls = step.get("tool_calls") or [{}]
                            tool_name = tool_calls[0].get("name", "tool")
                            tool_args = tool_calls[0].get("args", {})

                            tool_span = tracer.start_span(
                                f"tool:{tool_name}",
                                context=gen_ctx,
                                start_time=tool_start_ns,
                            )
                            tool_span.set_attribute("langfuse.observation.type", "SPAN")
                            tool_span.set_attribute("tool.name", tool_name)
                            tool_span.set_attribute("input.value", json.dumps(tool_args))
                            tool_span.set_attribute(
                                "output.value", str(tool_step.get("content", ""))[:4096]
                            )
                            if tool_step.get("status") == "ERROR":
                                tool_span.set_status(
                                    StatusCode.ERROR, str(tool_step.get("error", ""))
                                )
                            else:
                                tool_span.set_status(StatusCode.OK)
                            tool_span.end(end_time=tool_end_ns)

                        gen_span.end(end_time=next_start_ns)

            root_span.end(end_time=turn_end_ns)
            sys.stderr.write(
                f"[export_agy_otel_to_langfuse] Exported full trace tree "
                f"for session {conv_id} to {langfuse_url}\n"
            )
        else:
            # Live PostToolUse fallback when AGY_EXPORT_ON_TOOL_USE=true
            tool_call = payload.get("toolCall", {})
            tool_name = tool_call.get("name", "unknown_tool")
            tool_args = tool_call.get("args", {})
            step_idx = payload.get("stepIdx", 0)

            # Link live tool span under the deterministic root span ID
            root_span_id = deterministic_span_id(conv_id, "root_turn")
            parent_ctx = set_span_in_context(
                NonRecordingSpan(
                    SpanContext(
                        trace_id=trace_id,
                        span_id=root_span_id,
                        is_remote=True,
                        trace_flags=TraceFlags(0x01),
                    )
                )
            )

            with tracer.start_as_current_span(f"tool:{tool_name}", context=parent_ctx) as span:
                span.set_attribute("step.index", step_idx)
                span.set_attribute("session.id", conv_id)
                span.set_attribute("model.name", model_name)
                span.set_attribute("langfuse.observation.type", "SPAN")
                span.set_attribute("tool.name", tool_name)
                if tool_args:
                    input_str = json.dumps(tool_args)
                    span.set_attribute("langfuse.observation.input", input_str)
                    span.set_attribute("input.value", input_str)
                if error_msg:
                    span.set_status(StatusCode.ERROR, description=str(error_msg))
                    span.set_attribute("error.message", str(error_msg))
                else:
                    span.set_status(StatusCode.OK)

            sys.stderr.write(
                f"[export_agy_otel_to_langfuse] Exported live span 'tool:{tool_name}' "
                f"(step {step_idx}) to {langfuse_url}\n"
            )

        provider.shutdown()
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"[export_agy_otel_to_langfuse] Error exporting span: {exc}\n")


if __name__ == "__main__":
    export_step()
