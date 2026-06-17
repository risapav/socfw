#!/usr/bin/env python3
"""Entry point for the XFCP command-line client."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from xfcp.cli import main

sys.exit(main())
