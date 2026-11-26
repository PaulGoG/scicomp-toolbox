# Tests of the RunProvenance package. Digests are compared with the test vectors of
# FIPS 180-4 and with a digest of the whole file; the recorded commit with the answer of
# the git command line, which the package does not use. Projects and repositories are
# made in mktempdir().

using RunProvenance
using RunProvenance:
    accelerator,
    accelerator_records,
    environment_record,
    git_record,
    host_record,
    input_record,
    julia_record,
    main,
    manifest_path,
    sha256_hex
using Test
using Aqua
using ExplicitImports
using JET
using SHA: sha256
using TOML: TOML

# Git reads neither the configuration of the user nor that of the system here.
ENV["GIT_CONFIG_GLOBAL"] = Sys.iswindows() ? "NUL" : "/dev/null"
ENV["GIT_CONFIG_NOSYSTEM"] = "1"

const VALUE_TYPES = Union{String, Int, Bool, Vector{String}, Vector{Dict{String, Any}}}
const VERSIONED_MANIFEST = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"

function git_run(dir::AbstractString, args::AbstractString...)
    argv = collect(args)
    run(
        pipeline(
            `git -C $dir -c user.name=Test -c user.email=test@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false $argv`;
            stdout = devnull,
            stderr = devnull,
        ),
    )
    return nothing
end

head_of(dir) = String(strip(read(`git -C $dir rev-parse HEAD`, String)))
digest(text) = bytes2hex(sha256(text))

"""
    project_directory(files...) -> String

Temporary directory holding `Project.toml` and the given `name => content` files.
"""
function project_directory(files::Pair...)
    dir = realpath(mktempdir())
    write(joinpath(dir, "Project.toml"), "name = \"Run\"\n")
    for (name, content) in files
        mkpath(dirname(joinpath(dir, name)))
        write(joinpath(dir, name), content)
    end
    return dir
end

function file_with(content)
    path = joinpath(mktempdir(), "input.bin")
    write(path, content)
    return path
end

@testset "RunProvenance" begin
    @testset "Static QA" begin
        Aqua.test_all(RunProvenance)
        @test ExplicitImports.check_no_implicit_imports(RunProvenance) === nothing
        @test ExplicitImports.check_no_stale_explicit_imports(RunProvenance) === nothing
        @test ExplicitImports.check_all_explicit_imports_via_owners(RunProvenance) ===
              nothing
        report = JET.report_package(RunProvenance; target_modules = (RunProvenance,))
        reports = JET.get_reports(report)
        isempty(reports) || show(stdout, MIME"text/plain"(), report)
        @test isempty(reports)
    end

    @testset "SHA-256" begin
        # FIPS 180-4, examples of SHA-256
        @test sha256_hex(file_with("")) ==
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        @test sha256_hex(file_with("abc")) ==
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        @test sha256_hex(
            file_with("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        ) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        # longer than any read buffer, with a remainder
        bytes = UInt8[(i * 31) % 251 for i in 1:(3 * 2 ^ 20 + 7)]
        @test sha256_hex(file_with(bytes)) == bytes2hex(sha256(bytes))
    end

    @testset "host and Julia" begin
        host = host_record()
        @test sort!(collect(keys(host))) == [
            "arch",
            "cpu_model",
            "cpu_threads",
            "hostname",
            "machine",
            "os",
            "total_memory_bytes",
        ]
        @test host["hostname"] == gethostname()
        @test host["cpu_threads"] === Sys.CPU_THREADS
        @test host["total_memory_bytes"] === Int(Sys.total_memory())
        @test host["cpu_model"] == strip(host["cpu_model"]) && !isempty(host["cpu_model"])
        @test (host["os"], host["arch"], host["machine"]) ==
              (string(Sys.KERNEL), string(Sys.ARCH), Sys.MACHINE)

        julia = julia_record()
        @test sort!(collect(keys(julia))) == [
            "blas_libraries",
            "blas_threads",
            "distributed_workers",
            "julia_commit",
            "julia_interactive_threads",
            "julia_threads",
            "julia_version",
            "versioninfo",
        ]
        @test julia["julia_version"] == string(VERSION)
        @test julia["julia_threads"] === Threads.nthreads(:default)
        @test julia["julia_interactive_threads"] === Threads.nthreads(:interactive)
        @test julia["distributed_workers"] === 0
        @test julia["blas_threads"] isa Int && julia["blas_threads"] >= 1
        @test julia["blas_libraries"] isa Vector{String} &&
              !isempty(julia["blas_libraries"])
        @test all(!occursin('/', name) for name in julia["blas_libraries"])
        @test occursin("Julia Version $(VERSION)", julia["versioninfo"])
    end

    @testset "environment" begin
        bare = project_directory()
        project = joinpath(bare, "Project.toml")
        @test manifest_path(project) === nothing
        @test environment_record(project) == Dict("project_file" => "Project.toml")

        resolved = project_directory("Manifest.toml" => "# resolved\n")
        record = environment_record(joinpath(resolved, "Project.toml"))
        @test record == Dict(
            "project_file" => "Project.toml",
            "manifest_file" => "Manifest.toml",
            "manifest_sha256" => digest("# resolved\n"),
        )
        @test manifest_path(joinpath(resolved, "Project.toml")) ==
              joinpath(resolved, "Manifest.toml")
        # a directory stands for its project file
        @test environment_record(resolved) == record

        # Julia takes the manifest of its own version first
        both = project_directory(
            "Manifest.toml" => "# any\n",
            VERSIONED_MANIFEST => "# this version\n",
        )
        record = environment_record(both)
        @test record["manifest_file"] == VERSIONED_MANIFEST
        @test record["manifest_sha256"] == digest("# this version\n")

        named = project_directory("JuliaProject.toml" => "name = \"Run\"\n")
        @test environment_record(named)["project_file"] == "JuliaProject.toml"

        workspace = project_directory(
            "env/Project.toml" => "name = \"Env\"\n",
            "env/Manifest.toml" => "# env\n",
        )
        nested = environment_record(joinpath(workspace, "env"); root = workspace)
        @test nested["project_file"] == "env/Project.toml"
        @test nested["manifest_file"] == "env/Manifest.toml"

        @test_throws ArgumentError environment_record(joinpath(bare, "absent.toml"))
        @test_throws ArgumentError environment_record(mktempdir())
    end

    @testset "git" begin
        root = realpath(mktempdir())
        @test git_record(root) == Dict{String, Any}()
        git_run(root, "init")
        @test git_record(root) == Dict{String, Any}()
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "src", "a.jl"), "a = 1\n")
        git_run(root, "add", "-A")
        git_run(root, "commit", "-m", "feat: first version")
        commit = head_of(root)
        @test length(commit) == 40
        @test git_record(root) == Dict("gitcommit" => commit)
        @test git_record(joinpath(root, "src")) == Dict("gitcommit" => commit)
        # an untracked file leaves the tree clean, a change to a tracked one does not
        write(joinpath(root, "notes.txt"), "x\n")
        @test git_record(root)["gitcommit"] == commit
        write(joinpath(root, "src", "a.jl"), "a = 2\n")
        @test git_record(root)["gitcommit"] == commit * "-dirty"
        git_run(root, "commit", "-am", "fix: value")
        @test git_record(root)["gitcommit"] == head_of(root) != commit
        # a new file counts once it is staged
        git_run(root, "add", "notes.txt")
        @test git_record(root)["gitcommit"] == head_of(root) * "-dirty"
    end

    @testset "inputs" begin
        root = project_directory("data/catalogue.csv" => "id,mass\n1,1.4\n")
        record = input_record(joinpath(root, "data", "catalogue.csv"); root)
        @test record == Dict(
            "path" => "data/catalogue.csv",
            "bytes" => 14,
            "sha256" => digest("id,mass\n1,1.4\n"),
        )
        outside = file_with("abc")
        @test startswith(input_record(outside; root)["path"], "../")
        @test_throws "absent.csv" input_record(joinpath(root, "absent.csv"); root)
        @test_throws ArgumentError input_record(joinpath(root, "data"); root)
    end

    @testset "provenance" begin
        root = project_directory(
            "Manifest.toml" => "# resolved\n",
            "data/catalogue.csv" => "id,mass\n1,1.4\n",
        )
        git_run(root, "init")
        git_run(root, "add", "-A")
        git_run(root, "commit", "-m", "feat: first version")
        input = joinpath(root, "data", "catalogue.csv")
        record = provenance(; project = joinpath(root, "Project.toml"), inputs = [input])
        @test record isa Dict{String, Any}
        @test all(value isa VALUE_TYPES for value in values(record))
        for part in (host_record(), environment_record(root), git_record(root))
            @test all(record[key] == value for (key, value) in part)
        end
        @test record["julia_version"] == string(VERSION)
        @test record["gitcommit"] == head_of(root)
        @test record["manifest_sha256"] == digest("# resolved\n")
        @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", record["timestamp_utc"])
        @test record["inputs"] == [input_record(input; root)]
        @test record["accelerators"] == Dict{String, Any}[]
        expected = union(
            keys(host_record()),
            keys(julia_record()),
            ["project_file", "manifest_file", "manifest_sha256", "gitcommit"],
            ["timestamp_utc", "inputs", "accelerators"],
        )
        @test sort!(collect(keys(record))) == sort!(collect(expected))
        # the record survives TOML
        @test TOML.parse(sprint(io -> TOML.print(io, record; sorted = true))) == record

        # a directory as project is also the root; inputs may be any iterable
        by_directory = provenance(; project = root, inputs = (input,))
        @test by_directory["project_file"] == "Project.toml"
        @test by_directory["inputs"][1]["path"] == "data/catalogue.csv"
        # another root moves every relative path
        above = provenance(; project = root, root = dirname(root), inputs = [input])
        @test above["project_file"] == basename(root) * "/Project.toml"
        @test above["inputs"][1]["path"] == basename(root) * "/data/catalogue.csv"
        @test !haskey(above, "gitcommit")
        # for a dictionary that DrWatson tags itself
        untagged = provenance(; project = root, git = false)
        @test !haskey(untagged, "gitcommit")
        @test sort!(collect(keys(untagged))) ==
              sort!(setdiff(collect(expected), ["gitcommit"]))
        @test_throws ArgumentError provenance(; project = root, inputs = ["absent.csv"])

        # the active project, without arguments
        active = provenance()
        @test active["inputs"] == Dict{String, Any}[]
        @test active["project_file"] == basename(Base.active_project())
    end

    @testset "accelerators" begin
        # no backend package is loaded in this environment
        @test accelerator(Val(:cuda)) === nothing
        @test accelerator(Val(:unknown)) === nothing
        @test accelerator_records() == Dict{String, Any}[]
    end

    @testset "no active project" begin
        # a session whose load path holds the module but no project: 0 when provenance()
        # throws an ArgumentError, 3 when the session has a project after all
        packages = mktempdir()
        mkpath(joinpath(packages, "RunProvenance", "src"))
        cp(
            pathof(RunProvenance),
            joinpath(packages, "RunProvenance", "src", "RunProvenance.jl"),
        )
        code = """
            using RunProvenance
            Base.active_project() === nothing || exit(3)
            try
                provenance()
            catch err
                exit(err isa ArgumentError ? 0 : 4)
            end
            exit(5)
            """
        environment = copy(ENV)
        environment["JULIA_LOAD_PATH"] =
            join([packages, "@stdlib"], Sys.iswindows() ? ';' : ':')
        delete!(environment, "JULIA_PROJECT")
        command = setenv(`$(Base.julia_cmd()) --startup-file=no -e $code`, environment)
        @test run(ignorestatus(command)).exitcode == 0
    end

    @testset "writing" begin
        record = provenance(; project = project_directory())
        dir = mktempdir()
        path = joinpath(dir, "provenance.toml")
        @test write_provenance(path, record) == abspath(path)
        @test TOML.parsefile(path) == record
        text = read(path, String)
        @test issorted(first.(split.(filter(contains(" = "), split(text, '\n')), " = ")))
        @test_throws "provenance.toml" write_provenance(path, Dict("a" => 1))
        @test read(path, String) == text
        @test_throws ArgumentError write_provenance(
            joinpath(dir, "absent", "p.toml"),
            record,
        )
    end

    @testset "manifest snapshot" begin
        project = project_directory(VERSIONED_MANIFEST => "# this version\n")
        dir = mktempdir()
        copy = snapshot_manifest(dir; project)
        @test copy == joinpath(dir, VERSIONED_MANIFEST)
        @test read(copy, String) == "# this version\n"
        @test snapshot_manifest(dir; project = joinpath(project, "Project.toml")) == copy
        other = project_directory(VERSIONED_MANIFEST => "# another\n")
        @test_throws ArgumentError snapshot_manifest(dir; project = other)
        @test read(copy, String) == "# this version\n"
        @test snapshot_manifest(mktempdir(); project = project_directory()) === nothing
        @test_throws ArgumentError snapshot_manifest(joinpath(dir, "absent"); project)
    end

    @testset "command line" begin
        root = project_directory("data/a.csv" => "1\n", "data/b.csv" => "2\n")
        output(args) =
            (io = IOBuffer(); record = main(args; io); (record, String(take!(io))))
        a, b = joinpath(root, "data", "a.csv"), joinpath(root, "data", "b.csv")
        record, text = output(["--project", root, "--input", a, "--input", b])
        @test TOML.parse(text) == record
        @test [entry["path"] for entry in record["inputs"]] == ["data/a.csv", "data/b.csv"]
        @test record["project_file"] == "Project.toml"
        record, _ =
            output(["--project", joinpath(root, "Project.toml"), "--root", dirname(root)])
        @test record["project_file"] == basename(root) * "/Project.toml"
        # the project of the working directory
        record, _ = cd(() -> output(String[]), joinpath(root, "data"))
        @test record["project_file"] == "Project.toml"

        out = joinpath(mktempdir(), "provenance.toml")
        record, text = output(["--project", root, "--out", out])
        @test occursin("Provenance written to", text) && occursin(out, text)
        @test TOML.parsefile(out) == record
        @test_throws ArgumentError main(["--project", root, "--out", out]; io = devnull)

        _, usage = output(["--help"])
        @test occursin("run-provenance", usage) && occursin("--input", usage)
        @test_throws ArgumentError main(["--colour"]; io = devnull)
        @test_throws ArgumentError main(["--input"]; io = devnull)
        @test_throws ArgumentError main(["--project", root, "extra"]; io = devnull)
        @test_throws ArgumentError main(
            ["--project", joinpath(root, "absent")];
            io = devnull,
        )
        empty = mktempdir()
        if Base.current_project(empty) === nothing
            @test_throws "no project found" cd(() -> main(String[]; io = devnull), empty)
        end
    end
end
