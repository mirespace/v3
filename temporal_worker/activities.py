from __future__ import annotations

import os
import re
import subprocess
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import orjson
from temporalio import activity

from .models import PhaseSpec, WorkItem

_CONFIG_CACHE: dict[str, dict[str, Any]] = {}


def _load_config(config_path: str) -> dict[str, Any]:
    cached = _CONFIG_CACHE.get(config_path)
    if cached:
        return cached
    with open(config_path, "rb") as fh:
        data = orjson.loads(fh.read())
    _CONFIG_CACHE[config_path] = data
    return data


def _as_iterable(value: Any) -> list[str] | None:
    if value is None:
        return None
    if isinstance(value, str):
        if value.lower() == "all":
            return None
        return [item.strip() for item in value.split(",") if item.strip()]
    if isinstance(value, (list, tuple, set)):
        return [str(item) for item in value]
    return None


def _matches_arch(vm_type: str, arch_filter: str | None) -> bool:
    if not arch_filter or arch_filter == "all":
        return True
    if arch_filter == "arm":
        return vm_type.startswith("arm64_")
    if arch_filter == "amd":
        return vm_type.startswith("amd64_")
    return True


def _resolve_image(catalog: list[dict[str, Any]], series: str, vm_type: str) -> tuple[str | None, str | None, str | None]:
    for entry in catalog:
        if entry.get("series") == series and entry.get("type") == vm_type:
            return (entry.get("offer"), entry.get("sku"), entry.get("custom"))
    return (None, None, None)


def _build_vm_name(pattern: str, series: str, vm_type: str, size: str) -> str:
    name = pattern.format(series=series, type=vm_type, size=size)
    return re.sub(r"[^a-zA-Z0-9-]", "-", name)[:63]


def _materialize_phases(config: dict[str, Any]) -> list[PhaseSpec]:
    raw_tests = config.get("tests", [])
    phases: list[PhaseSpec] = []
    for entry in raw_tests:
        name = entry.get("name") or entry.get("id")
        command = entry.get("command") or entry.get("cmd")
        if not name or not command:
            continue
        if isinstance(command, str):
            command = ["bash", "-lc", command]
        timeout = entry.get("timeout") or entry.get("timeout_seconds")
        env = entry.get("env") or {}
        phases.append(PhaseSpec(name=name, command=tuple(command), timeout_seconds=timeout, environment=env))
    return phases


def _extract_metrics(output: str) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    for line in output.splitlines():
        if "METRIC:" not in line:
            continue
        try:
            _, kv = line.split("METRIC:", 1)
        except ValueError:
            continue
        key, _, value = kv.partition("=")
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        metrics[key] = value
    return metrics


def _asdict_phase(phase: PhaseSpec) -> dict[str, Any]:
    return {
        "name": phase.name,
        "command": list(phase.command),
        "timeout_seconds": phase.timeout_seconds,
        "environment": dict(phase.environment or {}),
    }


def _phase_timeout(phase: dict[str, Any]) -> int:
    raw = phase.get("timeout_seconds")
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str) and raw.isdigit():
        return int(raw)
    return 3600


def _resolve_matrix(config_path: str, cfg: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if cfg.get("matrix") or cfg.get("image_catalog"):
        return cfg.get("matrix") or {}, cfg.get("image_catalog") or []
    matrix_ref = cfg.get("matrix_ref")
    if not matrix_ref:
        return {}, []
    ref_path = Path(matrix_ref)
    if not ref_path.is_absolute():
        ref_path = Path(config_path).resolve().parent / ref_path
    matrix_cfg = _load_config(str(ref_path))
    return matrix_cfg.get("matrix") or {}, matrix_cfg.get("image_catalog") or []


@activity.defn
def discover_worklist(params: dict[str, Any]) -> dict[str, Any]:
    ctx = activity.info()
    config_path = params.get("config_path")
    if not isinstance(config_path, str):
        raise ValueError("config_path must be a string")
    cfg = _load_config(config_path)
    filters = params.get("filters") or {}

    matrix_cfg, catalog = _resolve_matrix(config_path, cfg)
    series_list = matrix_cfg.get("series") or []
    type_list = matrix_cfg.get("types") or []
    size_list = matrix_cfg.get("sizes") or []

    series_filter = _as_iterable(filters.get("series"))
    type_filter = _as_iterable(filters.get("types"))
    size_filter = _as_iterable(filters.get("sizes"))
    arch_filter = filters.get("arch")

    pattern = cfg.get("vm_name_pattern", "t-{series}-{type}-{size}")
    work_items: list[dict[str, Any]] = []

    for series in series_list:
        if series_filter and series not in series_filter:
            continue
        for vm_type in type_list:
            if type_filter and vm_type not in type_filter:
                continue
            if not _matches_arch(vm_type, arch_filter):
                continue
            for size in size_list:
                if size_filter and size not in size_filter:
                    continue
                offer, sku, custom = _resolve_image(catalog, series, vm_type)
                vm_name = _build_vm_name(pattern, series, vm_type, size)
                item = WorkItem(
                    series=series,
                    vm_type=vm_type,
                    size=size,
                    offer=offer,
                    sku=sku,
                    custom_image=custom,
                    vm_name=vm_name,
                    metadata={
                        "resource_group": cfg.get("resource_group"),
                        "location": cfg.get("location"),
                    },
                )
                work_items.append(asdict(item))

    phases = [_asdict_phase(phase) for phase in _materialize_phases(cfg)]
    activity.logger.info(
        "Discovered %d work items for workflow run_id=%s",
        len(work_items),
        ctx.workflow_run_id,
    )
    return {
        "work_items": work_items,
        "phases": phases,
        "config": {
            "resource_group": cfg.get("resource_group"),
            "location": cfg.get("location"),
            "artifacts_dir": cfg.get("artifacts_dir", "artifacts"),
            "keep_vms": bool(filters.get("keep_vms")),
        },
    }


@activity.defn
def run_combo(params: dict[str, Any]) -> dict[str, Any]:
    logger = activity.logger
    work_item = params.get("work_item") or {}
    phases = params.get("phases") or []
    run_id = params.get("run_id")
    if not isinstance(run_id, str):
        raise ValueError("run_id must be a string")
    artifacts_root = params.get("artifacts_root") or os.getenv("ARTIFACTS_DIR", "artifacts")
    vm_name = work_item.get("vm_name", "unknown")
    combo_dir = Path(artifacts_root) / "temporal" / run_id / vm_name
    combo_dir.mkdir(parents=True, exist_ok=True)

    results: list[dict[str, Any]] = []
    overall_status = "GOOD"

    base_env = {
        "SERIES": work_item.get("series", ""),
        "VM_TYPE": work_item.get("vm_type", ""),
        "VM_SIZE": work_item.get("size", ""),
        "VM_NAME": vm_name,
        "RUN_ID": run_id,
    }
    if work_item.get("offer"):
        base_env["IMAGE_OFFER"] = work_item["offer"]
    if work_item.get("sku"):
        base_env["IMAGE_SKU"] = work_item["sku"]
    if work_item.get("custom_image"):
        base_env["CUSTOM_IMAGE_ID"] = work_item["custom_image"]

    for phase in phases:
        started = datetime.now(timezone.utc)
        cmd = phase.get("command") or []
        if not cmd:
            results.append(
                {
                    "name": phase.get("name"),
                    "status": "SKIP",
                    "stdout": "",
                    "stderr": "",
                    "return_code": None,
                    "metrics": {},
                    "artifacts": [],
                    "started_at": started.isoformat(),
                    "completed_at": started.isoformat(),
                }
            )
            continue

        env = os.environ.copy()
        env.update(base_env)
        env.update(phase.get("environment") or {})
        log_prefix = f"[{work_item['vm_name']}::{phase.get('name')}]"
        logger.info("%s Starting phase", log_prefix)

        stdout_path = combo_dir / f"{phase.get('name')}-stdout.log"
        stderr_path = combo_dir / f"{phase.get('name')}-stderr.log"

        try:
            completed = subprocess.run(
                cmd,
                check=False,
                text=True,
                capture_output=True,
                env=env,
                timeout=_phase_timeout(phase),
            )
            stdout_path.write_text(completed.stdout)
            stderr_path.write_text(completed.stderr)
            status = "GOOD" if completed.returncode == 0 else "BAD"
            if status != "GOOD":
                overall_status = "BAD"
            metrics = _extract_metrics(completed.stdout)
            finished = datetime.now(timezone.utc)
            results.append(
                {
                    "name": phase.get("name"),
                    "status": status,
                    "stdout": stdout_path.name,
                    "stderr": stderr_path.name,
                    "return_code": completed.returncode,
                    "metrics": metrics,
                    "artifacts": [str(stdout_path), str(stderr_path)],
                    "started_at": started.isoformat(),
                    "completed_at": finished.isoformat(),
                }
            )
            logger.info("%s Completed with status=%s code=%s", log_prefix, status, completed.returncode)
        except subprocess.TimeoutExpired as exc:
            overall_status = "BAD"
            finished = datetime.now(timezone.utc)
            stderr_path.write_text(str(exc))
            results.append(
                {
                    "name": phase.get("name"),
                    "status": "TIMEOUT",
                    "stdout": "",
                    "stderr": stderr_path.name,
                    "return_code": None,
                    "metrics": {},
                    "artifacts": [str(stderr_path)],
                    "started_at": started.isoformat(),
                    "completed_at": finished.isoformat(),
                }
            )
            logger.error("%s Timeout after %ss", log_prefix, exc.timeout)

    combo_summary = {
        "work_item": work_item,
        "phases": results,
        "overall_status": overall_status,
        "artifacts_root": str(combo_dir),
    }
    summary_path = combo_dir / "_summary.json"
    summary_path.write_text(orjson.dumps(combo_summary, option=orjson.OPT_INDENT_2).decode("utf-8"))
    logger.info("Finished combo vm=%s overall_status=%s", work_item["vm_name"], overall_status)
    return combo_summary