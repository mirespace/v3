from __future__ import annotations

from dataclasses import asdict
from datetime import timedelta
from typing import Any, Dict, List

from temporalio import workflow

from .models import MatrixFilters


@workflow.defn
class RunMatrixWorkflow:
    @workflow.run
    async def run(
        self,
        config_path: str,
        filters: MatrixFilters | None = None,
        run_id: str | None = None,
        max_parallel: int = 1,
    ) -> list[dict[str, Any]]:
        filters_dict = asdict(filters) if filters else {}

        if isinstance(config_path, dict):
            payload = config_path
            config_path = payload.get("config_path", config_path)
            if "filters" in payload and not filters:
                filters_dict = payload.get("filters") or {}
            if payload.get("run_id") and not run_id:
                run_id = payload.get("run_id")
            if payload.get("max_parallel") and max_parallel == 1:
                try:
                    max_parallel = int(payload.get("max_parallel"))
                except (TypeError, ValueError):
                    max_parallel = max_parallel

        if not isinstance(config_path, str):
            raise ValueError("config_path must be a string")

        run_id = run_id or workflow.uuid4()

        discovery_input = {"config_path": config_path, "filters": filters_dict}
        discovery = await workflow.execute_activity(
            "discover_worklist",
            discovery_input,
            schedule_to_close_timeout=timedelta(minutes=5),
        )
        work_items: List[Dict[str, Any]] = discovery.get("work_items", [])
        phases: List[Dict[str, Any]] = discovery.get("phases", [])
        artifacts_root = discovery.get("config", {}).get("artifacts_dir", "artifacts")

        results: list[dict[str, Any]] = []
        pending: list[workflow.ActivityHandle] = []

        async def _drain_one() -> None:
            handle = pending.pop(0)
            results.append(await handle)

        for item in work_items:
            combo_input = {
                "work_item": item,
                "phases": phases,
                "run_id": run_id,
                "artifacts_root": artifacts_root,
            }
            handle = workflow.start_activity(
                "run_combo",
                combo_input,
                schedule_to_close_timeout=timedelta(hours=6),
                heartbeat_timeout=timedelta(minutes=5),
            )
            pending.append(handle)
            if len(pending) >= max_parallel:
                await _drain_one()

        while pending:
            await _drain_one()
        return results