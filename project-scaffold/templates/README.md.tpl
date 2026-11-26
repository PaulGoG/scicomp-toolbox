# <<PKG>>.jl

TODO: one paragraph on what the package computes, the equations or the method behind it,
and the unit system of its interfaces (SI unless stated otherwise).

```
<<PKG>>/
├── src/                # the package
<<TREE_SCRIPTS>>├── test/               # unit tests and static QA
├── bench/              # benchmarks, kept out of the test suite
├── docs/               # Documenter sources
├── activate.jl         # activates and instantiates the project
└── Project.toml
```

The [full tree](#full-tree) is at the end.

## Setup

Julia <<JULIA>> or later. Every environment activates and instantiates itself, so a fresh
clone needs no manual step:

```bash
julia -i activate.jl                        # REPL in the project environment
```

## Entry points

```bash
<<ENTRY_SCRIPTS>>julia -e 'include("activate.jl"); Pkg.test()'  # test suite, static QA included
julia bench/benchmarks.jl                   # benchmarks
julia docs/make.jl                          # documentation, built into docs/build/
```

## Status

| Component | State |
| :--- | :--- |
| `<<PKG>>` | scaffold: the module is empty |

## How to cite

```bibtex
@software{<<PKG>>,
  author = {<<AUTHORS_BIBTEX>>},
  title = {<<PKG>>.jl},
  year = {<<YEAR>>},
  url = {https://github.com/<<USER>>/<<PKG>>.jl}
}
```

## Full tree

<details>
<summary>Every directory and entry file</summary>

```
<<PKG>>/
├── .github/
│   ├── dependabot.yml      # weekly updates of actions and Julia environments; off until the launch
│   └── workflows/
│       ├── CI.yml          # tests on the compat floor and the stable release, coverage, documentation
│       └── Format.yml      # JuliaFormatter gate
├── .gitignore
├── .JuliaFormatter.toml
├── CITATION.cff
├── LICENSE
├── Project.toml
├── README.md
├── activate.jl             # activates and instantiates the project
├── bench/
│   ├── Project.toml
│   ├── activate.jl
│   └── benchmarks.jl       # BenchmarkTools suite
<<FULL_TREE_CONFIGS>>├── docs/
│   ├── Project.toml
│   ├── activate.jl
│   ├── make.jl
│   └── src/
│       └── index.md
<<FULL_TREE_SCRIPTS>>├── src/
│   └── <<PKG>>.jl
└── test/
    ├── Project.toml
    ├── activate.jl
    └── runtests.jl         # Aqua, JET on the stable release, unit tests
```

</details>
