import asyncio
import logging
import os
from concurrent.futures import ThreadPoolExecutor

from temporalio.client import Client
from temporalio.worker import Worker

from . import activities, workflows

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


async def main() -> None:
    target = os.getenv("TEMPORAL_TARGET", "localhost:7233")
    namespace = os.getenv("TEMPORAL_NAMESPACE", "default")
    task_queue = os.getenv("TEMPORAL_TASK_QUEUE", "v3-matrix")
    logger.info("Connecting to Temporal target=%s namespace=%s", target, namespace)
    client = await Client.connect(target, namespace=namespace)
    max_workers = int(os.getenv("TEMPORAL_ACTIVITY_WORKERS", "8"))
    executor = ThreadPoolExecutor(max_workers=max_workers)

    worker = Worker(
        client,
        task_queue=task_queue,
        workflows=[workflows.RunMatrixWorkflow],
        activities=[
            activities.discover_worklist,
            activities.run_combo,
        ],
        activity_executor=executor,
        max_concurrent_activities=max_workers,
    )
    try:
        await worker.run()
    finally:
        executor.shutdown(wait=False)


if __name__ == "__main__":
    asyncio.run(main())