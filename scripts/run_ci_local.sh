#!/usr/bin/env bash
set -euo pipefail

pytest tests/unit
pytest tests/integration
pytest tests/golden
