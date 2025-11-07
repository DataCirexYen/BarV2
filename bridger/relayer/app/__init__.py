"""Top-level package for relayer automation utilities."""

from importlib import metadata


def __getattr__(name: str) -> str:
    """Expose the package version via ``relayer.__version__``."""
    if name == "__version__":
        try:
            return metadata.version("relayer")
        except metadata.PackageNotFoundError:
            return "0.0.0"
    raise AttributeError(name)


__all__ = ["__version__"]
