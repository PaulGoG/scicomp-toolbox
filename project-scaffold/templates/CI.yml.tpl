name: CI

on:
  push:
    branches: [<<BRANCH>>]
    tags: ['*']
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ startsWith(github.ref, 'refs/pull/') }}

jobs:
  test:
    name: Julia ${{ matrix.version }} - ${{ matrix.os }}
    # skipped while the repository is private, so that nothing runs before the launch
    if: github.event.repository.visibility == 'public'
    runs-on: ${{ matrix.os }}
    timeout-minutes: 60
    permissions:
      actions: write # julia-actions/cache prunes the caches it created
      contents: read
    strategy:
      fail-fast: false
      matrix:
        # the compat floor of Project.toml and the current stable release
        version: ['min', '1']
        os: [ubuntu-latest]
    steps:
      - uses: <<PIN actions/checkout>>
        with:
          persist-credentials: false
      - uses: <<PIN julia-actions/setup-julia>>
        with:
          version: ${{ matrix.version }}
      - uses: <<PIN julia-actions/cache>>
      - uses: <<PIN julia-actions/julia-buildpkg>>
      - uses: <<PIN julia-actions/julia-runtest>>
      - uses: <<PIN julia-actions/julia-processcoverage>>
      - uses: <<PIN codecov/codecov-action>>
        with:
          files: lcov.info
          token: ${{ secrets.CODECOV_TOKEN }}
          fail_ci_if_error: false
  docs:
    name: Documentation
    if: github.event.repository.visibility == 'public'
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      actions: write # julia-actions/cache prunes the caches it created
      contents: write # the built site is pushed to gh-pages
      statuses: write # the deployment reports its state on the commit
    steps:
      - uses: <<PIN actions/checkout>>
      - uses: <<PIN julia-actions/setup-julia>>
        with:
          version: '1'
      - uses: <<PIN julia-actions/cache>>
      - uses: <<PIN julia-actions/julia-buildpkg>>
      - uses: <<PIN julia-actions/julia-docdeploy>>
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          DOCUMENTER_KEY: ${{ secrets.DOCUMENTER_KEY }}
