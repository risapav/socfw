"""Stable string IDs used as keys throughout the framework.

Centralising these prevents typo-driven bugs when the same key is referenced
in multiple layers (config, model, elaboration, IR).
"""
from __future__ import annotations

# Built-in artifact family names
FAMILY_RTL = "rtl"
FAMILY_TIMING = "timing"
FAMILY_BOARD = "board"
FAMILY_SOFTWARE = "software"
FAMILY_DOCS = "docs"

ALL_FAMILIES = (FAMILY_RTL, FAMILY_TIMING, FAMILY_BOARD, FAMILY_SOFTWARE, FAMILY_DOCS)

# Board resource reference prefix
BOARD_REF_PREFIX = "board:"

# Board resource path segments
ONBOARD_NS = "onboard"
CONNECTOR_NS = "connector"

# IP origin kinds
ORIGIN_SOURCE = "source"
ORIGIN_VENDOR_GENERATED = "vendor_generated"
ORIGIN_GENERATED = "generated"

# Clock output kinds
CLOCK_KIND_GENERATED = "generated_clock"
CLOCK_KIND_STATUS = "status"

# Bus roles
BUS_ROLE_SLAVE = "slave"
BUS_ROLE_MASTER = "master"

# Reset/adapt policy names
ADAPT_ZERO = "zero"
ADAPT_REPLICATE = "replicate"
ADAPT_HIGH_Z = "high_z"

# Source-location keys used in Diagnostic
LOC_PROJECT = "project config"
LOC_BOARD = "board config"
LOC_IP = "ip descriptor"
LOC_TIMING = "timing config"
