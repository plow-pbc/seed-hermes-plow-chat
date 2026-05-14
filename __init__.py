"""Root Hermes plugin entry point for the Plow Chat SEED.

Hermes installs Git plugins from the repository root. The readable reference
implementation lives under ref/hermes-plugin/plow_chat/ so this root module
loads that adapter and exposes its register(ctx) function.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_PLUGIN_ROOT = Path(__file__).resolve().parent
_ADAPTER_PATH = _PLUGIN_ROOT / "ref" / "hermes-plugin" / "plow_chat" / "adapter.py"
_MODULE_NAME = f"{__name__}._plow_chat_adapter"

if not _ADAPTER_PATH.exists():
    raise ImportError(f"Plow Chat adapter not found at {_ADAPTER_PATH}")

_spec = importlib.util.spec_from_file_location(_MODULE_NAME, _ADAPTER_PATH)
if _spec is None or _spec.loader is None:
    raise ImportError(f"Cannot load Plow Chat adapter from {_ADAPTER_PATH}")

_adapter = importlib.util.module_from_spec(_spec)
sys.modules[_MODULE_NAME] = _adapter
_spec.loader.exec_module(_adapter)

register = _adapter.register

__all__ = ["register"]
