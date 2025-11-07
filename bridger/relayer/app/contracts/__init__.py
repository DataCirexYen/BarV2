"""Contract ABIs shipped with the relayer."""

from importlib import resources
from typing import Any, Dict
import json


def load_contract_abi(filename: str) -> Dict[str, Any]:
    """Load an ABI JSON file from the contracts package."""
    with resources.files(__package__).joinpath(filename).open("r", encoding="utf-8") as fh:
        return json.load(fh)


__all__ = ["load_contract_abi"]
