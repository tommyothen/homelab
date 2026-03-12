"""Homelab MCP Server — read-only observability tools for Metis.

Exposes infrastructure query tools via the Model Context Protocol (MCP)
so that OpenClaw on Metis can observe metrics, logs, container state,
and network health without needing direct access to each service.

Runs on Panoptes as a systemd service, listening on port 8090 (Tailscale-only).
All tools are read-only — no mutations, no restarts, no deployments.

Usage (dev):
    python server.py
"""

import asyncio
import json
import logging
import os
import subprocess
from typing import Any

import httpx
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)

PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")
LOKI_URL = os.environ.get("LOKI_URL", "http://localhost:3100")
GATUS_URL = os.environ.get("GATUS_URL", "http://localhost:8080")
DEPLOY_USER = os.environ.get("DEPLOY_USER", "deploy")

server = Server("homelab-mcp")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _http_get(url: str, params: dict | None = None, timeout: float = 15) -> dict:
    async with httpx.AsyncClient(timeout=timeout) as client:
        resp = await client.get(url, params=params)
        resp.raise_for_status()
        return resp.json()


async def _ssh_command(host: str, command: str, timeout: int = 15) -> str:
    proc = await asyncio.create_subprocess_exec(
        "ssh",
        "-o", "StrictHostKeyChecking=yes",
        "-o", f"ConnectTimeout={timeout}",
        "-o", "BatchMode=yes",
        f"{DEPLOY_USER}@{host}",
        command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout + 5)
    if proc.returncode != 0:
        raise RuntimeError(f"SSH to {host} failed (rc={proc.returncode}): {stderr.decode().strip()}")
    return stdout.decode().strip()


def _text(content: str) -> list[TextContent]:
    return [TextContent(type="text", text=content)]


# ---------------------------------------------------------------------------
# Tool definitions
# ---------------------------------------------------------------------------

@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="prometheus_query",
            description="Run a PromQL instant query against Prometheus. Returns the current value of a metric expression.",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "PromQL expression (e.g. 'up', 'node_memory_MemAvailable_bytes')"},
                },
                "required": ["query"],
            },
        ),
        Tool(
            name="prometheus_query_range",
            description="Run a PromQL range query for trend analysis. Returns time series data over a period.",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "PromQL expression"},
                    "start": {"type": "string", "description": "Start time (ISO 8601 or relative like '1h')"},
                    "end": {"type": "string", "description": "End time (ISO 8601 or 'now'). Default: now"},
                    "step": {"type": "string", "description": "Query resolution step (e.g. '5m', '1h'). Default: 5m"},
                },
                "required": ["query", "start"],
            },
        ),
        Tool(
            name="prometheus_alerts",
            description="List all currently firing Prometheus alerts with severity, labels, and annotations.",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        Tool(
            name="loki_query",
            description="Search logs via LogQL. Returns log lines matching the query from Loki.",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "LogQL query (e.g. '{job=\"docker\"} |= \"error\"')"},
                    "start": {"type": "string", "description": "Start time (ISO 8601 or relative like '1h'). Default: 1h ago"},
                    "end": {"type": "string", "description": "End time. Default: now"},
                    "limit": {"type": "integer", "description": "Max log lines to return. Default: 100"},
                },
                "required": ["query"],
            },
        ),
        Tool(
            name="container_status",
            description="List Docker containers on a remote host with their status, image, and ports.",
            inputSchema={
                "type": "object",
                "properties": {
                    "host": {"type": "string", "description": "Target hostname (e.g. 'dionysus', 'panoptes')"},
                },
                "required": ["host"],
            },
        ),
        Tool(
            name="nixos_generations",
            description="Show recent NixOS system generations on a host (current, previous, rollback targets).",
            inputSchema={
                "type": "object",
                "properties": {
                    "host": {"type": "string", "description": "Target hostname"},
                    "count": {"type": "integer", "description": "Number of generations to show. Default: 10"},
                },
                "required": ["host"],
            },
        ),
        Tool(
            name="gatus_status",
            description="Get endpoint uptime status from Gatus monitoring.",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        Tool(
            name="tailscale_status",
            description="Get Tailscale mesh network status — all nodes, online/offline, IPs, and last seen.",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        Tool(
            name="disk_usage",
            description="Get disk usage for all monitored hosts from Prometheus (root filesystem percent used).",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
    ]


# ---------------------------------------------------------------------------
# Tool handlers
# ---------------------------------------------------------------------------

@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    try:
        if name == "prometheus_query":
            data = await _http_get(
                f"{PROMETHEUS_URL}/api/v1/query",
                params={"query": arguments["query"]},
            )
            return _text(json.dumps(data["data"], indent=2))

        elif name == "prometheus_query_range":
            params: dict[str, Any] = {
                "query": arguments["query"],
                "start": arguments["start"],
                "end": arguments.get("end", "now"),
                "step": arguments.get("step", "5m"),
            }
            data = await _http_get(
                f"{PROMETHEUS_URL}/api/v1/query_range",
                params=params,
            )
            return _text(json.dumps(data["data"], indent=2))

        elif name == "prometheus_alerts":
            data = await _http_get(f"{PROMETHEUS_URL}/api/v1/alerts")
            alerts = data.get("data", {}).get("alerts", [])
            if not alerts:
                return _text("No alerts currently firing.")
            formatted = []
            for alert in alerts:
                if alert.get("state") == "firing":
                    formatted.append(
                        f"[{alert['labels'].get('severity', 'unknown').upper()}] "
                        f"{alert['labels'].get('alertname', '?')} — "
                        f"{alert.get('annotations', {}).get('summary', 'no summary')}"
                    )
            return _text("\n".join(formatted) if formatted else "No alerts currently firing.")

        elif name == "loki_query":
            params = {
                "query": arguments["query"],
                "limit": str(arguments.get("limit", 100)),
                "direction": "backward",
            }
            if "start" in arguments:
                params["start"] = arguments["start"]
            if "end" in arguments:
                params["end"] = arguments["end"]
            data = await _http_get(
                f"{LOKI_URL}/loki/api/v1/query_range",
                params=params,
                timeout=30,
            )
            results = data.get("data", {}).get("result", [])
            lines = []
            for stream in results:
                labels = stream.get("stream", {})
                label_str = ", ".join(f"{k}={v}" for k, v in labels.items())
                for ts, line in stream.get("values", []):
                    lines.append(f"[{label_str}] {line}")
            return _text("\n".join(lines[:500]) if lines else "No log lines matched the query.")

        elif name == "container_status":
            host = arguments["host"]
            if not host.replace("-", "").replace("_", "").isalnum():
                return _text(f"ERROR: invalid hostname: {host}")
            output = await _ssh_command(
                host,
                'docker ps --format \'{"name":"{{.Names}}","status":"{{.Status}}","image":"{{.Image}}","ports":"{{.Ports}}"}\'',
            )
            if not output:
                return _text(f"No running containers on {host}.")
            containers = []
            for line in output.strip().split("\n"):
                try:
                    containers.append(json.loads(line))
                except json.JSONDecodeError:
                    containers.append({"raw": line})
            return _text(json.dumps(containers, indent=2))

        elif name == "nixos_generations":
            host = arguments["host"]
            count = arguments.get("count", 10)
            if not host.replace("-", "").replace("_", "").isalnum():
                return _text(f"ERROR: invalid hostname: {host}")
            output = await _ssh_command(
                host,
                f"nixos-rebuild list-generations 2>/dev/null | head -n {int(count) + 1}",
            )
            return _text(output if output else f"No generation data from {host}.")

        elif name == "gatus_status":
            try:
                data = await _http_get(f"{GATUS_URL}/api/v1/endpoints/statuses")
                statuses = []
                for ep in data:
                    name_val = ep.get("name", "?")
                    group = ep.get("group", "")
                    results_list = ep.get("results", [])
                    latest = results_list[-1] if results_list else {}
                    status_val = "UP" if latest.get("success", False) else "DOWN"
                    statuses.append(f"  [{status_val}] {group}/{name_val}")
                return _text("\n".join(statuses) if statuses else "No endpoints configured in Gatus.")
            except Exception as e:
                return _text(f"Gatus unavailable: {e}")

        elif name == "tailscale_status":
            proc = await asyncio.create_subprocess_exec(
                "tailscale", "status", "--json",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10)
            if proc.returncode != 0:
                return _text(f"tailscale status failed: {stderr.decode().strip()}")
            data = json.loads(stdout.decode())
            lines = []
            self_node = data.get("Self", {})
            lines.append(f"Self: {self_node.get('HostName')} | {self_node.get('TailscaleIPs', ['?'])[0]} | Online: {self_node.get('Online')}")
            lines.append("")
            for peer in (data.get("Peer") or {}).values():
                lines.append(
                    f"  {peer.get('HostName')} | {peer.get('TailscaleIPs', ['?'])[0]} | "
                    f"Online: {peer.get('Online')} | LastSeen: {peer.get('LastSeen', '?')}"
                )
            return _text("\n".join(lines))

        elif name == "disk_usage":
            data = await _http_get(
                f"{PROMETHEUS_URL}/api/v1/query",
                params={
                    "query": 'round((1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})) * 100)'
                },
            )
            results = data.get("data", {}).get("result", [])
            if not results:
                return _text("No disk usage data available from Prometheus.")
            lines = []
            for r in results:
                instance = r["metric"].get("instance", "?")
                pct = r["value"][1]
                lines.append(f"  {instance}: {pct}% used")
            return _text("Disk usage (root filesystem):\n" + "\n".join(sorted(lines)))

        else:
            return _text(f"Unknown tool: {name}")

    except httpx.HTTPStatusError as e:
        return _text(f"HTTP error: {e.response.status_code} — {e.response.text[:500]}")
    except httpx.ConnectError as e:
        return _text(f"Connection error: {e}")
    except RuntimeError as e:
        return _text(str(e))
    except Exception as e:
        logger.exception("Tool %s failed", name)
        return _text(f"Error: {type(e).__name__}: {e}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
