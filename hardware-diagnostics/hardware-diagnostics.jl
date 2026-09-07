#!/usr/bin/env julia
# Entry point of the hardware-diagnostics tool. Activates the package environment,
# loads the accelerator packages selected by the configuration (their package
# extensions attach the GPU backends), then runs discovery, cross-engine verification,
# the benchmark stages and the exports.
#
#   julia run.jl hardware-diagnostics [options]      (see --help)

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using HardwareDiagnostics

# Invalid options and configurations are reported as one line, without a stack trace.
const CONFIG = try
    configure(ARGS, @__DIR__)
catch err
    err isa ArgumentError || rethrow()
    println(stderr, "hardware-diagnostics: ", err.msg)
    exit(2)
end
CONFIG === nothing && exit(0)
const LOADED_BACKENDS = load_accelerator_packages(CONFIG.gpu_backend)
run_diagnostics(CONFIG; base_dir = @__DIR__, loaded_backends = LOADED_BACKENDS)
