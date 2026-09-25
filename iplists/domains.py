"""Exact domain names and conservative suffix grouping."""

import re

COLLAPSE_MIN_SIBLINGS = 2
DOMAIN_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")


def normalize_domain(value: str) -> str:
    domain = value.strip().lower().removesuffix(".")
    labels = domain.split(".")
    if len(domain) > 253 or len(labels) < 2 or any(not DOMAIN_LABEL.fullmatch(label) for label in labels):
        raise ValueError(f"invalid domain: {value!r}")
    return domain


def collapse_domains(domains: set[str], known_roots: set[str]) -> tuple[set[str], set[str]]:
    """Collapse siblings only when their parent also appears in the sources."""
    counts: dict[str, int] = {}
    for domain in domains:
        _, parent = domain.split(".", 1)
        counts[parent] = counts.get(parent, 0) + 1
    candidates = {
        "." + parent
        for parent, count in counts.items()
        if count >= COLLAPSE_MIN_SIBLINGS and parent in known_roots
    }

    def under_suffix(domain: str, suffixes: set[str]) -> bool:
        parent = domain.partition(".")[2]
        while parent:
            if "." + parent in suffixes:
                return True
            parent = parent.partition(".")[2]
        return False

    suffixes = {suffix for suffix in candidates if not under_suffix(suffix[1:], candidates)}
    remaining = {domain for domain in domains if not under_suffix(domain, suffixes)}
    return remaining, suffixes
