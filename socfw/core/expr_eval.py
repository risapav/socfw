from __future__ import annotations

import ast
import math
import re


def _clog2(n: int) -> int:
    """SystemVerilog $clog2: ceiling log2. Returns 0 for n<=1 (SV spec)."""
    if n <= 1:
        return 0
    return (n - 1).bit_length()


def resolve_port_width(port, instance_params: dict) -> int:
    """Return concrete width for a PortDescriptor given instance params.

    If the port has a width_expr, re-evaluate it with instance_params.
    Falls back to port.width (which was evaluated at load time with defaults).
    """
    if not getattr(port, 'width_expr', None):
        return port.width
    int_params: dict[str, int] = {}
    for k, v in instance_params.items():
        if isinstance(v, (int, bool)):
            int_params[k] = int(v)
    try:
        return eval_width_expr(port.width_expr, int_params)
    except ValueError:
        return port.width


def eval_width_expr(expr: str, params: dict[str, int]) -> int:
    """Evaluate a parameterized width expression.

    Supports: integer literals, parameter names, +, -, *, $clog2(expr).
    Raises ValueError on invalid expression or missing parameter.
    """
    text = expr.strip()

    # Expand $clog2(...) before substitution — handle nested param names inside
    def _expand_clog2(m: re.Match) -> str:
        inner = eval_width_expr(m.group(1), params)
        return str(_clog2(inner))

    text = re.sub(r'\$clog2\(([^)]+)\)', _expand_clog2, text)

    # Substitute parameter names (longest first to avoid partial matches)
    for name in sorted(params, key=len, reverse=True):
        text = re.sub(rf'\b{re.escape(name)}\b', str(params[name]), text)

    # Check for unresolved identifiers
    if re.search(r'[A-Za-z_]', text):
        unresolved = re.findall(r'[A-Za-z_]\w*', text)
        raise ValueError(
            f"Unresolved names in width_expr '{expr}': {unresolved}. "
            f"Available params: {list(params.keys())}"
        )

    # Safe arithmetic eval — only allow integers and operators
    try:
        tree = ast.parse(text, mode='eval')
    except SyntaxError as exc:
        raise ValueError(f"Syntax error in width_expr '{expr}': {exc}") from exc

    for node in ast.walk(tree):
        if not isinstance(node, (ast.Expression, ast.BinOp, ast.UnaryOp,
                                  ast.Constant, ast.Add, ast.Sub, ast.Mult,
                                  ast.USub, ast.UAdd)):
            raise ValueError(
                f"Disallowed AST node {type(node).__name__} in width_expr '{expr}'"
            )

    result = eval(compile(tree, '<width_expr>', 'eval'))  # noqa: S307
    if not isinstance(result, int):
        raise ValueError(f"width_expr '{expr}' evaluated to non-integer: {result!r}")
    if result < 0:
        raise ValueError(f"width_expr '{expr}' evaluated to {result} — must be >= 0")
    return result
