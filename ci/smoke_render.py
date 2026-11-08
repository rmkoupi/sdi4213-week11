"""Render the page once, headless, and check what it says about itself.

The health endpoint answers `ok` while the page itself can still fail (the
Week 10 lesson), so this runs app.py through Streamlit's AppTest, from the
deployed image, with the deployed environment, and checks:

  - the script raised nothing
  - the caption names the expected environment and database
  - (optional) the caption names the expected version

Exit status is the verdict. Configuration comes from the environment:
  EXPECT_ENV       e.g. Cloud          (required)
  EXPECT_DB        e.g. PostgreSQL     (required)
  EXPECT_VERSION   e.g. 1.1.0          (optional)
  APP_FILE         default app.py
"""

import os
import sys

from streamlit.testing.v1 import AppTest


def main() -> int:
    expect_env = os.environ["EXPECT_ENV"]
    expect_db = os.environ["EXPECT_DB"]
    expect_version = os.environ.get("EXPECT_VERSION", "")
    # Absolute, against the working directory (/app in the image). AppTest
    # resolves a relative path against the CALLING FILE's directory, which is
    # the ConfigMap mount /smoke, so a bare "app.py" is "not found" there.
    app_file = os.path.abspath(os.environ.get("APP_FILE", "app.py"))

    at = AppTest.from_file(app_file, default_timeout=30).run()

    failures = []
    if at.exception:
        failures.append("page raised: " + "; ".join(str(e.value) for e in at.exception))
    if at.error:
        failures.append("page showed an error: " + "; ".join(str(e.value) for e in at.error))

    captions = [c.value for c in at.caption]
    caption = captions[0] if captions else ""
    print(f"caption: {caption!r}")
    if f"Environment: {expect_env}" not in caption:
        failures.append(f"caption does not say Environment: {expect_env}")
    if f"Database: {expect_db}" not in caption:
        failures.append(f"caption does not say Database: {expect_db}")
    if expect_version and f"Version {expect_version}" not in caption:
        failures.append(f"caption does not say Version {expect_version}")

    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        return 1
    print("PASS  page renders and reports the expected deployment")
    return 0


if __name__ == "__main__":
    sys.exit(main())
