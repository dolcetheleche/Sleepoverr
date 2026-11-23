import base64
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

# Make `mock_romm` importable however pytest is invoked (repo root or dev/mock-romm).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mock_romm.auth import AuthConfig  # noqa: E402
from mock_romm.data import FIXTURES_DIR, load_library  # noqa: E402
from mock_romm.main import create_app  # noqa: E402

CLIENT_TOKEN = "rmm_" + "ab" * 32


@pytest.fixture
def auth_config() -> AuthConfig:
    return AuthConfig(username="admin", password="s3cret", client_token=CLIENT_TOKEN, jwt_secret="t" * 64)


@pytest.fixture
def client(auth_config) -> TestClient:
    # Always test against the committed fixtures, even if a local roms.resolved.json exists.
    library = load_library(FIXTURES_DIR, prefer_resolved=False)
    return TestClient(create_app(auth=auth_config, library=library))


@pytest.fixture
def token_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {CLIENT_TOKEN}"}


@pytest.fixture
def basic_headers() -> dict[str, str]:
    return {"Authorization": "Basic " + base64.b64encode(b"admin:s3cret").decode()}
