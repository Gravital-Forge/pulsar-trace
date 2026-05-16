"""Hello-world test proving the pytest harness works (Epic 1).

The real pyannote/diart wrapper tests land in Epic 3.
"""

import pulsartrace_ai


def test_package_imports():
    """The package imports and exposes a version string."""
    assert pulsartrace_ai.__version__ == "0.1.0"


def test_harness_runs():
    """The pytest harness itself runs."""
    assert 320 == 16_000 * 20 // 1000  # canonical 20ms frame size
