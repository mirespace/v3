from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Iterable, Mapping, Sequence


@dataclass(frozen=True)
class MatrixFilters:
    series: Iterable[str] | None = None
    types: Iterable[str] | None = None
    sizes: Iterable[str] | None = None
    arch: str | None = None


@dataclass(frozen=True)
class WorkItem:
    series: str
    vm_type: str
    size: str
    offer: str | None
    sku: str | None
    custom_image: str | None
    vm_name: str
    metadata: Mapping[str, Any]


@dataclass(frozen=True)
class PhaseSpec:
    name: str
    command: Sequence[str]
    timeout_seconds: int | None = None
    environment: Mapping[str, str] | None = None


@dataclass
class PhaseResult:
    name: str
    status: str
    started_at: datetime
    completed_at: datetime
    stdout: str
    stderr: str
    return_code: int
    metrics: Mapping[str, Any]
    artifacts: Sequence[str]


@dataclass
class ComboResult:
    work_item: WorkItem
    phases: list[PhaseResult]
    overall_status: str