"""CloudBridge demo app: one image, two roles (ROLE=frontend or ROLE=backend).

backend  -> GET /      : says which cloud and pod answered
frontend -> GET /      : calls the backend and returns its answer
            GET /health: deep check, 200 only if the backend answers (used by Route 53)
both     -> GET /live  : shallow check, 200 while the process runs (used by Kubernetes liveness)
"""

import asyncio
import os
import socket

import httpx
from fastapi import FastAPI, Response

ROLE = os.getenv("ROLE", "backend")
CLOUD = os.getenv("CLOUD", "unknown")
POD = os.getenv("POD_NAME", socket.gethostname())
BACKEND_URL = os.getenv("BACKEND_URL", "http://backend")

# Short timeout: a dead dependency should fail the health check fast, not hang it
TIMEOUT = httpx.Timeout(2.0)

app = FastAPI(title=f"cloudbridge-{ROLE}")


@app.get("/live")
def live():
    # Never checks dependencies: restarting a healthy frontend can't fix a broken backend
    return {"status": "alive", "role": ROLE, "pod": POD}


# Fault injection for the 502/503/504 lab (tests/b5). Off unless ENABLE_FAULTS=true, so the
# public endpoint can't be used to crash or stall pods.
if os.getenv("ENABLE_FAULTS") == "true":

    @app.get("/slow")
    async def slow(s: float = 10):
        # Holds the request open: the ALB gives up after its idle timeout -> 504
        await asyncio.sleep(min(s, 120))
        return {"slept": s, "pod": POD}

    @app.get("/crash")
    def crash():
        # Dies mid-request without answering: the ALB sees a reset connection -> 502.
        # Kubernetes restarts the container; the other replicas keep serving.
        os._exit(1)


if ROLE == "backend":

    @app.get("/")
    def backend_root():
        return {"role": "backend", "cloud": CLOUD, "pod": POD}

    @app.get("/health")
    def backend_health():
        return {"status": "ok", "role": "backend", "cloud": CLOUD}

else:

    def call_backend():
        with httpx.Client(timeout=TIMEOUT) as client:
            r = client.get(BACKEND_URL)
            r.raise_for_status()
            return r.json()

    @app.get("/")
    def frontend_root(response: Response):
        try:
            backend = call_backend()
        except Exception as e:  # DNS failure, timeout, refused, 5xx: all mean "backend unreachable"
            response.status_code = 503
            return {"role": "frontend", "cloud": CLOUD, "pod": POD, "error": type(e).__name__}
        return {"role": "frontend", "cloud": CLOUD, "pod": POD, "backend": backend}

    @app.get("/health")
    def frontend_health(response: Response):
        try:
            call_backend()
        except Exception as e:
            response.status_code = 503
            return {"status": "unhealthy", "cloud": CLOUD, "reason": type(e).__name__}
        return {"status": "ok", "cloud": CLOUD}
