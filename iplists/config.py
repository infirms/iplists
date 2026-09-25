"""Service definitions: per-URL text or JSON format."""

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from .domains import normalize_domain

CATEGORIES = ("domains", "domains_", "ipv4_cidr", "ipv6_cidr")
OUTPUT_NAMES = {"domains": "domains", "domains_": "domains_", "ipv4_cidr": "ipv4", "ipv6_cidr": "ipv6"}


@dataclass(frozen=True, slots=True)
class Source:
    url: str
    format: Literal["text", "json"]


def load_services(directory: Path) -> list[tuple[str, dict]]:
    services = []
    for path in sorted(directory.glob("*.json")):
        config = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(config, dict) or set(config) - {*CATEGORIES, "exclude_domains", "exclude_exact_domains"}:
            raise ValueError(f"{path}: unknown fields or invalid service object")
        for category in CATEGORIES:
            items = config.get(category, [])
            if not isinstance(items, list):
                raise ValueError(f"{path}: {category} must be a list of sources")
            sources = []
            for index, item in enumerate(items, 1):
                if not isinstance(item, dict) or set(item) != {"url", "format"}:
                    raise ValueError(f"{path}: {category}[{index}] requires url and format")
                url, format_name = item["url"], item["format"]
                if not isinstance(url, str):
                    raise ValueError(f"{path}: {category}[{index}]: url must be a string")
                parts = urlsplit(url)
                if parts.scheme not in ("https", "http") or not parts.netloc:
                    raise ValueError(f"{path}: {category}[{index}]: invalid HTTP URL: {url!r}")
                if format_name not in ("text", "json"):
                    raise ValueError(f"{path}: {category}[{index}]: format must be text or json")
                sources.append(Source(url, format_name))
            config[category] = sources
        for key in ("exclude_domains", "exclude_exact_domains"):
            values = config.get(key, [])
            if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
                raise ValueError(f"{path}: {key} must be a list of domains")
            try:
                config[key] = [normalize_domain(value) for value in values]
            except ValueError as error:
                raise ValueError(f"{path}: {key}: {error}") from error
        if not any(config[category] for category in CATEGORIES):
            raise ValueError(f"{path}: at least one source URL is required")
        services.append((path.stem, config))
    if not services:
        raise ValueError(f"no services/*.json found in {directory}")
    return services
