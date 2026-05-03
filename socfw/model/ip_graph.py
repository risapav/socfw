from __future__ import annotations

from socfw.model.ip import IpDescriptor


def collect_synthesis_files(
    ip: IpDescriptor,
    catalog: dict[str, IpDescriptor],
    *,
    _visited: set[str] | None = None,
) -> list[str]:
    """Return synthesis artifact paths for `ip` and all its transitive requires."""
    if _visited is None:
        _visited = set()
    if ip.name in _visited:
        return []
    _visited.add(ip.name)

    files: list[str] = list(ip.artifacts.synthesis)
    for dep_name in ip.requires:
        dep = catalog.get(dep_name)
        if dep is not None:
            files.extend(collect_synthesis_files(dep, catalog, _visited=_visited))
    return files


def collect_simulation_files(
    ip: IpDescriptor,
    catalog: dict[str, IpDescriptor],
    *,
    _visited: set[str] | None = None,
) -> list[str]:
    """Return simulation artifact paths for `ip` and all its transitive requires."""
    if _visited is None:
        _visited = set()
    if ip.name in _visited:
        return []
    _visited.add(ip.name)

    files: list[str] = list(ip.artifacts.simulation)
    for dep_name in ip.requires:
        dep = catalog.get(dep_name)
        if dep is not None:
            files.extend(collect_simulation_files(dep, catalog, _visited=_visited))
    return files


def collect_include_dirs(
    ip: IpDescriptor,
    catalog: dict[str, IpDescriptor],
    *,
    _visited: set[str] | None = None,
) -> list[str]:
    """Return include_dirs for `ip` and all its transitive requires."""
    if _visited is None:
        _visited = set()
    if ip.name in _visited:
        return []
    _visited.add(ip.name)

    dirs: list[str] = list(ip.artifacts.include_dirs)
    for dep_name in ip.requires:
        dep = catalog.get(dep_name)
        if dep is not None:
            dirs.extend(collect_include_dirs(dep, catalog, _visited=_visited))
    return dirs


def transitive_requires(
    ip: IpDescriptor,
    catalog: dict[str, IpDescriptor],
    *,
    _visited: set[str] | None = None,
) -> set[str]:
    """Return set of all transitively required IP names (excluding `ip` itself)."""
    if _visited is None:
        _visited = {ip.name}
    result: set[str] = set()
    for dep_name in ip.requires:
        if dep_name in _visited:
            continue
        _visited.add(dep_name)
        result.add(dep_name)
        dep = catalog.get(dep_name)
        if dep is not None:
            result |= transitive_requires(dep, catalog, _visited=_visited)
    return result
