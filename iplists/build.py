"""Build separate sing-box v4 source/binary rule-sets per service and category."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from .config import CATEGORIES, OUTPUT_NAMES, load_services
from .domains import collapse_domains
from .sources import Downloader, parse_entries


def build_rule_sets(config: dict, downloader: Downloader) -> dict[str, dict]:
    collected = {category: set() for category in CATEGORIES}
    for category in CATEGORIES:
        for source in config[category]:
            collected[category].update(
                parse_entries(downloader.fetch(source.url), source.format, category, source.url)
            )
        if config[category] and not collected[category]:
            raise ValueError(f"{category}: all source lists are empty")

    excluded_subtrees = set(config["exclude_domains"])
    excluded_exact = set(config["exclude_exact_domains"])

    def allowed(domain: str) -> bool:
        return domain not in excluded_exact and all(
            domain != root and not domain.endswith("." + root) for root in excluded_subtrees
        )

    collected["domains"] = {domain for domain in collected["domains"] if allowed(domain)}
    collected["domains_"] = {domain for domain in collected["domains_"] if allowed(domain)}
    exact, suffixes = collapse_domains(collected["domains_"], collected["domains"] | collected["domains_"])
    rule_sets = {}
    for category in CATEGORIES:
        if not config[category]:
            continue
        if category == "domains":
            rule = {"domain": sorted(collected[category])} if collected[category] else None
        elif category == "domains_":
            positive = {}
            if exact:
                positive["domain"] = sorted(exact)
            if suffixes:
                positive["domain_suffix"] = sorted(suffixes)
            rule = positive or None
            if suffixes and (excluded_subtrees or excluded_exact):
                negative = {"domain": sorted(excluded_subtrees | excluded_exact), "invert": True}
                if excluded_subtrees:
                    negative["domain_suffix"] = ["." + domain for domain in sorted(excluded_subtrees)]
                rule = {"type": "logical", "mode": "and", "rules": [positive, negative]}
        else:
            rule = {"ip_cidr": sorted(collected[category])} if collected[category] else None
        if rule is None:
            raise ValueError(f"{category}: no rules after exclusions")
        rule_sets[category] = {"version": 3, "rules": [rule] if rule else []}
    return rule_sets


MANIFEST = ".iplists-files.json"


def previous_files(path: Path) -> set[str]:
    if not path.exists():
        return set()
    names = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(names, list) or any(
        not isinstance(name, str) or name == MANIFEST or Path(name).name != name or
        Path(name).suffix not in (".json", ".srs", ".src", ".srcs")
        for name in names
    ):
        raise ValueError(f"{path}: invalid generated-file manifest")
    return set(names)


def publish(output: Path, generated: Path, backup: Path, retired: set[str]) -> None:
    """Restore the previous generation if a file operation fails mid-publish."""
    names = {file.name for file in generated.iterdir()} | retired
    for name in names:
        original = output / name
        if original.exists():
            shutil.copy2(original, backup / name)
    try:
        for file in generated.iterdir():
            if file.name != MANIFEST:
                os.replace(file, output / file.name)
        for name in retired:
            (output / name).unlink(missing_ok=True)
        os.replace(generated / MANIFEST, output / MANIFEST)
    except BaseException:
        try:
            for name in names:
                saved = backup / name
                if saved.exists():
                    os.replace(saved, output / name)
                else:
                    (output / name).unlink(missing_ok=True)
        except OSError as error:
            recovery = output.parent / f".iplists-recovery-{backup.parent.name}"
            backup.rename(recovery)
            raise RuntimeError(f"rollback failed; saved files at {recovery}") from error
        raise


def compile_services(directory: Path, output: Path, sing_box: str = "sing-box") -> None:
    services = load_services(directory)
    output.mkdir(parents=True, exist_ok=True)
    previous = previous_files(output / MANIFEST)
    downloader = Downloader()  # One clock shared across categories and services.
    with tempfile.TemporaryDirectory(dir=output) as temp:
        temporary = Path(temp)
        generated = temporary / "new"
        backup = temporary / "previous"
        generated.mkdir()
        backup.mkdir()
        legacy = set()
        current = set()
        for name, config in services:
            rule_sets = build_rule_sets(config, downloader)
            for category in CATEGORIES:
                stem = f"{name}_{OUTPUT_NAMES[category]}"
                legacy.update(f"{stem}.{extension}" for extension in ("json", "srs", "src", "srcs"))
            for category, rules in rule_sets.items():
                stem = f"{name}_{OUTPUT_NAMES[category]}"
                source = generated / f"{stem}.json"
                binary = generated / f"{stem}.srs"
                source.write_text(json.dumps(rules, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                subprocess.run([sing_box, "rule-set", "compile", "--output", str(binary), str(source)], check=True)
                current.update((source.name, binary.name))
        (generated / MANIFEST).write_text(json.dumps(sorted(current)) + "\n", encoding="utf-8")
        publish(output, generated, backup, (previous | legacy) - current)
    for name in sorted(current):
        if name.endswith(".srs"):
            print(output / name)
