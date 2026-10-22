"""Any other GST tax invoice — the catch-all for business bills. Matched
only when nothing more specific fits."""

from .common import Profile

PROFILE = Profile(
    name="gst_invoice",
    keywords=(
        (r"\btax invoice\b", 1.5), (r"\bgstin\b", 1), (r"\bhsn\b|\bsac\b", 1),
        (r"\bplace of supply\b", 1),
    ),
)
