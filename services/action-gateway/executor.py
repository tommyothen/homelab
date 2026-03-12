"""Script execution logic for the Action Gateway."""

import asyncio
import logging
from pathlib import Path

logger = logging.getLogger(__name__)


async def run_script(
    scripts_dir: str,
    script_name: str,
    timeout: int,
    env_overrides: dict[str, str] | None = None,
) -> dict:
    """Run a shell script and return stdout/stderr/returncode."""
    scripts_dir_resolved = Path(scripts_dir).resolve()
    script_path = (scripts_dir_resolved / script_name).resolve()

    # Prevent path traversal — script must live inside the scripts directory.
    if not str(script_path).startswith(str(scripts_dir_resolved) + "/"):
        return {
            "success": False,
            "stdout": "",
            "stderr": "Blocked: script path escapes the scripts directory",
            "returncode": -1,
        }

    if not script_path.exists():
        return {
            "success": False,
            "stdout": "",
            "stderr": f"Script not found: {script_path}",
            "returncode": -1,
        }

    if not script_path.is_file():
        return {
            "success": False,
            "stdout": "",
            "stderr": f"Not a file: {script_path}",
            "returncode": -1,
        }

    logger.info("Running script: %s (timeout=%ds)", script_path, timeout)
    try:
        env = None
        if env_overrides:
            import os
            env = {**os.environ, **env_overrides}

        proc = await asyncio.create_subprocess_exec(
            str(script_path),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(), timeout=timeout
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.communicate()
            return {
                "success": False,
                "stdout": "",
                "stderr": f"Script timed out after {timeout}s",
                "returncode": -1,
            }

        returncode = proc.returncode
        stdout = stdout_bytes.decode(errors="replace").strip()
        stderr = stderr_bytes.decode(errors="replace").strip()
        logger.info("Script exited with code %d", returncode)
        return {
            "success": returncode == 0,
            "stdout": stdout[:4000],
            "stderr": stderr[:4000],
            "returncode": returncode,
        }
    except OSError as exc:
        logger.exception("Unexpected error running script %s", script_path)
        return {
            "success": False,
            "stdout": "",
            "stderr": str(exc),
            "returncode": -1,
        }
