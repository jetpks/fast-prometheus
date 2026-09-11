# How to verify a release build

Catch packaging bugs that `bundle exec sus` and the `script/` E2Es can't — files missing
from `spec.files`, runtime deps declared only for the test group, require-path mistakes —
before you tag a release. `sus` and the E2Es run against the checkout's `lib/` directly;
the integration harness runs only against a built, installed `.gem`. You need `prometheus`
and `promtool` on `PATH` to exercise the harness's E2E checks in full.

## Steps

1. During development, run the harness against a gem built from your working checkout:

   ```bash
   ./integration/run
   ```

   This builds `fast-prometheus.gemspec`, installs it into an isolated `GEM_HOME`, and runs
   every check against that install only — the checkout's `lib/` is never on the child
   processes' load path.

2. To verify a specific artifact instead (e.g. a `.gem` downloaded from a release asset),
   pass its path:

   ```bash
   ./integration/run path/to/some.gem
   ```

3. Set `E2E_REQUIRED=1` to make the harness fail, rather than skip, when `prometheus` or
   `promtool` aren't on `PATH`:

   ```bash
   E2E_REQUIRED=1 ./integration/run
   ```

4. Before a tag graduates to a release, run the required form against the exact artifact
   being tagged:

   ```bash
   E2E_REQUIRED=1 ./integration/run path/to/fast-prometheus-<version>.gem
   ```

## Result

The harness prints one `CHECK <id>: PASS|FAIL|SKIP` line per check, then a final line:

```
INTEGRATION: PASS
```

`INTEGRATION: PASS` means every check passed and, if `E2E_REQUIRED=1` was set, none were
skipped. Any `FAIL` line, or a skip under `E2E_REQUIRED=1`, is `INTEGRATION: FAIL` and the
tag must not graduate.
