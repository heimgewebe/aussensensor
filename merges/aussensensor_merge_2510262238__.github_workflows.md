### 📄 .github/workflows/contracts-validate.yml

**Größe:** 187 B | **md5:** `dca48dea5be7bde5fa5ca44dae67795f`

```yaml
name: contracts-validate
permissions:
  contents: read

on:
  push:
  pull_request:

jobs:
  validate:
    uses: heimgewebe/metarepo/.github/workflows/contracts-validate.yml@contracts-v1
```

### 📄 .github/workflows/jsonl-guard.yml

**Größe:** 2 KB | **md5:** `5e3a3c7836b3648afd40fdf3437c91ba`

```yaml
name: jsonl-guard
on:
  push:
    paths:
      - "**/*.jsonl"
      - ".github/workflows/jsonl-guard.yml"
  pull_request:
    paths:
      - "**/*.jsonl"
      - ".github/workflows/jsonl-guard.yml"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq
      - name: Ensure JSONL lines are single, valid JSON objects
        shell: bash
        run: |
          shopt -s globstar nullglob
          failed=0
          for f in **/*.jsonl; do
            echo "::group::check $f"
            lineno=0
            while IFS= read -r line || [[ -n "$line" ]]; do
              lineno=$((lineno+1))
              [[ -n "${line// }" ]] || continue
              if ! printf '%s\n' "$line" | jq -e . >/dev/null 2>&1; then
                echo "::error file=$f,line=$lineno::Invalid JSON (line must be a complete JSON object)."
                failed=1
              fi
              # Fail if the object appears split across multiple lines (heuristic: trailing comma or open brace-only)
              [[ "$line" =~ ,[[:space:]]*$ ]] && { echo "::error file=$f,line=$lineno::Line ends with comma -> multiline JSON not allowed."; failed=1; }
              [[ "$line" =~ ^[[:space:]]*[{[]?[[:space:]]*$ ]] && { echo "::warning file=$f,line=$lineno::Suspicious structural-only line."; failed=1; }
            done < "$f"
            echo "::endgroup::"
          done
          exit $failed
```

### 📄 .github/workflows/push_leitstand.yml

**Größe:** 2 KB | **md5:** `ef7f8a536f4a80cc35f20d6b0d14575d`

```yaml
name: Push feed to Leitstand
permissions:
  contents: read

on:
  workflow_dispatch:
    inputs:
      url:
        description: "Optional: Override Leitstand ingest URL"
        required: false
        type: string
      dry_run:
        description: "Nur Testlauf ohne HTTP-Request"
        required: false
        default: false
        type: boolean

jobs:
  push:
    name: Validate and push feed
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Validate feed against schema
        run: |
          set -euo pipefail
          if [ ! -f export/feed.jsonl ] || [ ! -s export/feed.jsonl ]; then
            echo "Keine Einträge in export/feed.jsonl – Validierung übersprungen."
            exit 0
          fi
          tmp_dir="$(mktemp -d)"
          trap 'rm -rf "$tmp_dir"' EXIT
          cp export/feed.jsonl "$tmp_dir/feed.jsonl"
          while IFS= read -r line || [ -n "$line" ]; do
            if [ -z "${line// }" ]; then
              continue
            fi
            printf '%s\n' "$line" > export/feed.jsonl
            npx -y ajv-cli@5 validate --spec=draft2020 --strict=false --validate-formats=false -s contracts/aussen.event.schema.json -d export/feed.jsonl
          done < "$tmp_dir/feed.jsonl"
          mv "$tmp_dir/feed.jsonl" export/feed.jsonl

      - name: Push feed to Leitstand
        env:
          LEITSTAND_INGEST_URL: ${{ inputs.url != '' && inputs.url || secrets.LEITSTAND_INGEST_URL }}
          LEITSTAND_TOKEN: ${{ secrets.LEITSTAND_TOKEN }}
        run: |
          set -euo pipefail
          DRY_RUN_FLAG=""
          if [ "${{ inputs.dry_run }}" = 'true' ]; then
            DRY_RUN_FLAG="--dry-run"
          fi
          scripts/push_leitstand.sh $DRY_RUN_FLAG
```

### 📄 .github/workflows/validate-aussen-fixtures.yml

**Größe:** 2 KB | **md5:** `abd4a12563c883ee595aff21ecb56404`

```yaml
name: validate (aussen fixtures)

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

on:
  push:
    paths:
      - 'tests/fixtures/aussen/**'
      - '.github/workflows/validate-aussen-fixtures.yml'
  pull_request:
    paths:
      - 'tests/fixtures/aussen/**'
      - '.github/workflows/validate-aussen-fixtures.yml'
  workflow_dispatch:

jobs:
  discover:
    name: Discover fixture files
    runs-on: ubuntu-latest
    outputs:
      files: ${{ steps.collect.outputs.files }}
    steps:
      - uses: actions/checkout@v4
      - id: collect
        shell: bash
        run: |
          shopt -s nullglob
          arr=(tests/fixtures/aussen/*.jsonl)
          if [ ${#arr[@]} -eq 0 ]; then
            echo "files=[]" >> "$GITHUB_OUTPUT"
            echo "No fixtures found."
            exit 0
          fi
          printf 'files=[' >> "$GITHUB_OUTPUT"
          first=1
          for f in "${arr[@]}"; do
            if [ $first -eq 1 ]; then first=0; else printf ',' >> "$GITHUB_OUTPUT"; fi
            printf '%s' "\"$f\"" >> "$GITHUB_OUTPUT"
          done
          printf ']\n' >> "$GITHUB_OUTPUT"
          echo "Discovered ${#arr[@]} fixture file(s)."

  validate:
    name: Validate ${{ matrix.file }}
    needs: discover
    if: ${{ fromJSON(needs.discover.outputs.files) != null && length(fromJSON(needs.discover.outputs.files)) > 0 }}
    uses: heimgewebe/metarepo/.github/workflows/reusable-validate-jsonl.yml@contracts-v1
    strategy:
      fail-fast: false
      matrix:
        file: ${{ fromJSON(needs.discover.outputs.files) }}
    with:
      # Reusable erwartet ggf. einen einzelnen Pfad:
      jsonl_path: ${{ matrix.file }}
      # Falls die Reusable zusätzlich strict/validate_formats unterstützt, kann man sie dort aktivieren;
      # werte ignoriert die Reusable einfach.
      schema_url: https://raw.githubusercontent.com/heimgewebe/metarepo/contracts-v1/contracts/aussen.event.schema.json
      strict: false
      validate_formats: true
```

### 📄 .github/workflows/validate-feed.yml

**Größe:** 789 B | **md5:** `30320262e5f4b3905dcc447672e7ea63`

```yaml
name: validate (aussensensor feed)

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

on:
  push:
    paths:
      - export/feed.jsonl
      - .github/workflows/validate-feed.yml
      - contracts/**
      - scripts/validate.sh
  pull_request:
    paths:
      - export/feed.jsonl
      - .github/workflows/validate-feed.yml
      - contracts/**
      - scripts/validate.sh
  workflow_dispatch:
jobs:
  validate:
    uses: heimgewebe/metarepo/.github/workflows/reusable-validate-jsonl.yml@contracts-v1
    with:
      jsonl_path: export/feed.jsonl
      schema_url: https://raw.githubusercontent.com/heimgewebe/metarepo/contracts-v1/contracts/aussen.event.schema.json
      strict: false
      validate_formats: true
```

### 📄 .github/workflows/validate.yml

**Größe:** 419 B | **md5:** `eeea55413117a04030cc80424b64c67b`

```yaml
name: validate (aussensensor)
on: [push, pull_request, workflow_dispatch]
permissions:
  contents: read
jobs:
  v:
    uses: heimgewebe/metarepo/.github/workflows/reusable-validate-jsonl.yml@contracts-v1
    with:
      jsonl_path: export/feed.jsonl
      schema_url: https://raw.githubusercontent.com/heimgewebe/metarepo/contracts-v1/contracts/aussen.event.schema.json
      strict: false
      validate_formats: true
```

