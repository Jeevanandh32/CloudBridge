import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[2]
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from mindbridge.builder import build  # noqa: E402
from mindbridge.whatif import build_report  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


@pytest.fixture(scope="session")
def built():
    return build()


@pytest.fixture(scope="session")
def report(built):
    model, facts, log, problems, _ = built
    return build_report(model, facts, log, problems)


@pytest.fixture(scope="session")
def rows(report):
    return {r["component"]: r for r in report["rows"]}
