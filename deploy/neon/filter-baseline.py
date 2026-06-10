#!/usr/bin/env python3
"""Filter a pg_dump of an InsForge database into a Neon-importable baseline.

The InsForge docker image ships the pg_cron and http extensions; managed
Postgres (Neon) does not. This strips the objects that cannot exist there:
  - CREATE EXTENSION / COMMENT ON EXTENSION for pg_cron and http
  - functions whose signatures use http extension types
  - GRANT/REVOKE statements on http extension functions (the functions are
    extension members, so they are absent without the extension)

Everything else — auth/system/storage/functions schemas, RLS policies, grants
to the legacy roles, and rows inserted by migrations — passes through intact.
The in-database schedules engine is intentionally disabled on Neon; schedules
run from the control plane instead.

Usage: filter-baseline.py < pg_dump.sql > baseline.sql
"""

import re
import sys

DROP_EXTENSIONS = ("pg_cron", "http")

# Functions whose *signature* references http extension types (creation-time
# failure without the extension). Bodies referencing http/cron at runtime are
# fine: pg_dump emits SET check_function_bodies = false.
DROP_FUNCTION_BLOCKS = ("schedules.build_http_headers",)

# ACL targets that belong to the http extension.
ACL_PATTERN = re.compile(
    r"^(GRANT|REVOKE).*ON FUNCTION public\.(http|bytea_to_text|text_to_bytea|urlencode)", re.I
)


def main() -> None:
    lines = sys.stdin.read().splitlines(keepends=True)
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]

        if any(
            re.match(rf"CREATE EXTENSION IF NOT EXISTS {ext}\b", line)
            or re.match(rf"COMMENT ON EXTENSION {ext}\b", line)
            for ext in DROP_EXTENSIONS
        ):
            i += 1
            continue

        if any(line.startswith(f"CREATE FUNCTION {fn}(") for fn in DROP_FUNCTION_BLOCKS):
            # Skip until the closing `$$;` of this function body.
            while i < len(lines) and not lines[i].rstrip().endswith("$$;"):
                i += 1
            i += 1
            continue

        if ACL_PATTERN.match(line):
            i += 1
            continue

        # pg_cron config tables (cron.job, cron.job_run_details) are dumped as
        # extension config data; without the extension the schema is absent.
        # The retention jobs they contained run from the control plane instead.
        if line.startswith("COPY cron."):
            while i < len(lines) and lines[i].rstrip() != "\\.":
                i += 1
            i += 1
            continue

        if re.match(r"SELECT pg_catalog\.setval\('cron\.", line):
            i += 1
            continue

        # The dump's owner role (postgres) does not exist on managed Postgres;
        # apply default-privilege statements to the importing role instead.
        line = line.replace("ALTER DEFAULT PRIVILEGES FOR ROLE postgres ", "ALTER DEFAULT PRIVILEGES ")

        out.append(line)
        i += 1

    sys.stdout.write("".join(out))


if __name__ == "__main__":
    main()
