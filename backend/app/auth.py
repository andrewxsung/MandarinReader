import os

from fastapi import HTTPException, Security
from fastapi.security import APIKeyHeader

API_KEY_HEADER = APIKeyHeader(name="X-API-Key", auto_error=False)


async def verify_auth(api_key: str | None = Security(API_KEY_HEADER)) -> str:
    """Validate the X-API-Key header against MANDARINREADER_API_KEY env var.

    When MANDARINREADER_API_KEY is unset, auth is skipped (local dev).
    Returns a string identity — swap body for JWT logic later.
    """
    expected = os.getenv("MANDARINREADER_API_KEY", "")
    if not expected:
        return "local-dev"
    if not api_key or api_key != expected:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")
    return api_key
