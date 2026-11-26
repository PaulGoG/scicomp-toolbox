name: Format

on:
  push:
    branches: [<<BRANCH>>]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ startsWith(github.ref, 'refs/pull/') }}

jobs:
  format:
    name: JuliaFormatter check
    # skipped while the repository is private, so that nothing runs before the launch
    if: github.event.repository.visibility == 'public'
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      actions: write # julia-actions/cache prunes the caches it created
      contents: read
    steps:
      - uses: <<PIN actions/checkout>>
        with:
          persist-credentials: false
      - uses: <<PIN julia-actions/setup-julia>>
        with:
          version: '1'
      - uses: <<PIN julia-actions/cache>>
      - name: Format with the pinned JuliaFormatter
        # a formatter release can change the result, so the version is exact
        run: |
          julia --color=yes -e '
            using Pkg
            Pkg.activate(; temp = true)
            Pkg.add(; name = "JuliaFormatter", version = "<<FORMATTER>>")
            using JuliaFormatter
            format(".")'
      - name: Fail on differences
        run: git diff --exit-code
