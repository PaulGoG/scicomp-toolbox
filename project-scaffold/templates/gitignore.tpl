# manifests are not tracked: an environment is resolved where it runs, within the
# [compat] bounds of its Project.toml
Manifest*.toml
<<IGNORE_RUNS>>
# documentation build
docs/build/

# coverage artifacts
*.jl.cov
*.jl.*.cov
*.jl.mem
lcov.info

# editor and OS metadata
*.swp
*~
.DS_Store
.vscode/
.idea/
