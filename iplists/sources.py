"""Serialized downloads and text/JSON entry extraction."""

import json
import time
from urllib.request import urlopen

from .domains import normalize_domain
from .networks import normalize_network

REQUEST_INTERVAL_SECONDS = 10
REQUEST_TIMEOUT_SECONDS = 30
DOWNLOAD_RETRIES = 5  # Additional attempts after the first request.
MAX_RESPONSE_BYTES = 16 * 1024 * 1024


class Downloader:
    def __init__(self) -> None:
        self.last_request: float | None = None

    def fetch(self, url: str) -> str:
        for attempt in range(DOWNLOAD_RETRIES + 1):
            if self.last_request is not None:
                time.sleep(max(0, REQUEST_INTERVAL_SECONDS - (time.monotonic() - self.last_request)))
            self.last_request = time.monotonic()
            try:
                with urlopen(url, timeout=REQUEST_TIMEOUT_SECONDS) as response:
                    payload = response.read(MAX_RESPONSE_BYTES + 1)
                if len(payload) > MAX_RESPONSE_BYTES:
                    raise ValueError(f"{url}: response exceeds {MAX_RESPONSE_BYTES} bytes")
                return payload.decode("utf-8-sig")
            except (OSError, UnicodeError) as error:
                if attempt == DOWNLOAD_RETRIES:
                    raise RuntimeError(f"failed downloading {url} after {attempt + 1} attempts") from error
        raise AssertionError("unreachable")


def parse_entries(payload: str, format_name: str, category: str, url: str) -> set[str]:
    if format_name == "text":
        items = (
            (line.split("#", 1)[0].strip(), f"{url}:{number}")
            for number, line in enumerate(payload.splitlines(), 1)
        )
    elif format_name == "json":
        try:
            data = json.loads(payload)
        except json.JSONDecodeError as error:
            raise ValueError(f"{url}: invalid JSON: {error}") from error
        if isinstance(data, list):
            groups = {"items": data}
        elif isinstance(data, dict):
            groups = data  # OpenCCK: {"site": ["domain", "CIDR", ...]}.
        else:
            raise ValueError(f"{url}: JSON must be an array or an object of arrays")
        for key, values in groups.items():
            if not isinstance(values, list):
                raise ValueError(f"{url}: {key}: expected an array of strings")
        items = ((item, f"{url}:{key}[{index}]") for key, values in groups.items()
                 for index, item in enumerate(values, 1))
    else:
        raise ValueError(f"{url}: unsupported format: {format_name}")

    result = set()
    for value, location in items:
        if format_name == "text" and not value:
            continue
        if not isinstance(value, str):
            raise ValueError(f"{location}: expected a string")
        try:
            if category in ("domains", "domains_"):
                item = normalize_domain(value)
            else:
                item = normalize_network(value, 4 if category == "ipv4_cidr" else 6)
        except ValueError as error:
            raise ValueError(f"{location}: {error}") from error
        result.add(item)
    return result
