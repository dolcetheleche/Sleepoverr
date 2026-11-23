"""Authentication that imitates RomM's three accepted schemes.

1. ``Authorization: Bearer rmm_<64 hex>`` - a RomM "Client API Token" (what Sleepoverr will use).
2. ``Authorization: Bearer <JWT>``       - an OAuth2 access token from ``POST /api/token``.
3. ``Authorization: Basic <b64 user:pw>`` - HTTP Basic with the RomM username/password.
"""

from __future__ import annotations

import base64
import binascii
import os
import re
import secrets
import sys
import time
from dataclasses import dataclass, field

import jwt
from fastapi import HTTPException, Request, status

CLIENT_TOKEN_RE = re.compile(r"^rmm_[0-9a-f]{64}$")
ACCESS_TOKEN_TTL = 1800  # seconds, RomM's OAUTH_ACCESS_TOKEN_EXPIRE_SECONDS default
REFRESH_TOKEN_TTL = 604800  # seconds, 7 days


def generate_client_token() -> str:
    return "rmm_" + secrets.token_hex(32)


@dataclass
class AuthConfig:
    username: str
    password: str
    client_token: str
    jwt_secret: str = field(repr=False)

    @classmethod
    def from_env(cls) -> AuthConfig:
        token = os.environ.get("MOCK_ROMM_CLIENT_TOKEN", "").strip()
        if not token:
            token = generate_client_token()
            print(f"[mock-romm] MOCK_ROMM_CLIENT_TOKEN not set; generated: {token}", file=sys.stderr, flush=True)
        elif not CLIENT_TOKEN_RE.match(token):
            print("[mock-romm] WARNING: MOCK_ROMM_CLIENT_TOKEN is not of the form rmm_<64 hex>", file=sys.stderr)
        return cls(
            username=os.environ.get("MOCK_ROMM_USER", "admin"),
            password=os.environ.get("MOCK_ROMM_PASSWORD", "admin"),
            client_token=token,
            jwt_secret=os.environ.get("MOCK_ROMM_JWT_SECRET") or secrets.token_hex(32),
        )

    # -- OAuth2 tokens --------------------------------------------------------------------
    def _encode(self, kind: str, scopes: list[str], ttl: int) -> str:
        now = int(time.time())
        payload = {
            "sub": self.username,
            "iss": "romm:oauth",
            "type": kind,
            "scopes": " ".join(scopes),
            "iat": now,
            "exp": now + ttl,
            "jti": secrets.token_hex(8),
        }
        return jwt.encode(payload, self.jwt_secret, algorithm="HS256")

    def issue_tokens(self, scopes: list[str]) -> dict:
        return {
            "access_token": self._encode("access", scopes, ACCESS_TOKEN_TTL),
            "refresh_token": self._encode("refresh", scopes, REFRESH_TOKEN_TTL),
            "token_type": "bearer",
            "expires": ACCESS_TOKEN_TTL,
            "refresh_expires": REFRESH_TOKEN_TTL,
        }

    def decode(self, token: str, kind: str) -> dict | None:
        try:
            claims = jwt.decode(token, self.jwt_secret, algorithms=["HS256"], issuer="romm:oauth")
        except jwt.PyJWTError:
            return None
        if claims.get("type") != kind or claims.get("sub") != self.username:
            return None
        return claims

    # -- request check --------------------------------------------------------------------
    def check_basic(self, value: str) -> bool:
        try:
            user, _, pw = base64.b64decode(value, validate=True).decode().partition(":")
        except (binascii.Error, UnicodeDecodeError):
            return False
        return secrets.compare_digest(user, self.username) and secrets.compare_digest(pw, self.password)

    def authenticate(self, request: Request) -> str:
        header = request.headers.get("authorization", "")
        scheme, _, value = header.partition(" ")
        scheme = scheme.lower()
        value = value.strip()
        if scheme == "bearer" and value:
            if value.startswith("rmm_"):
                if secrets.compare_digest(value, self.client_token):
                    return "client_token"
            elif self.decode(value, "access") is not None:
                return "oauth"
        elif scheme == "basic" and value and self.check_basic(value):
            return "basic"
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated" if not header else "Invalid credentials",
            headers={"WWW-Authenticate": "Bearer"},
        )
