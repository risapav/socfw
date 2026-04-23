#!/usr/bin/env bash
set -euo pipefail

pytest tests/unit
pytest tests/integration -k "not picorv32 and not sim"
