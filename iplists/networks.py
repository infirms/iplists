"""Validate and canonicalize IPv4/IPv6 source networks."""

import ipaddress


def normalize_network(value: str, version: int) -> str:
    network = ipaddress.ip_network(value, strict=False)
    if network.version != version:
        raise ValueError(f"expected IPv{version}")
    return str(network)
