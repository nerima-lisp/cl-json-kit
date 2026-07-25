# Installation

`cl-json-kit` has **no external Common Lisp runtime dependencies**. Only the
test system additionally uses [`cl-weave`](https://github.com/takeokunn/cl-weave).

## With Nix

The repository is a Nix flake. To build the ASDF system:

```sh
nix build github:nerima-lisp/cl-json-kit
```

The flake also exposes per-system attributes:

```sh
# Build the library for the current system.
nix build .#cl-json-kit

# Run the test suite as a reproducible derivation.
nix flake check

# Enter a devShell with SBCL and the competitor JSON libraries
# used by the benchmark harness.
nix develop

# Build this documentation site (Material for MkDocs, fully offline).
nix build .#docs
```

The `devShells.<system>.default` shell preloads Jzon, Jonathan, JSOWN, and
Yason so `benchmark/competitors.lisp` can compare against them. See
[Benchmarks](benchmarks.md).

## With ASDF

Put the repository where ASDF can find it — for example under
`~/common-lisp/` or a directory on your `CL_SOURCE_REGISTRY` — then load it:

```lisp
(asdf:load-system "cl-json-kit")
```

Everything a caller needs is exported from the single `json-kit` package. A
typical session either uses the fully qualified `json-kit:` prefix or adds a
nickname:

```lisp
(use-package :json-kit)       ; or reference symbols as json-kit:parse, etc.
```

## Supported runtime

`cl-json-kit` targets **SBCL** first and is written in portable Common Lisp
elsewhere. The only implementation-specific behavior is the optional
`:timeout-seconds` wall-clock safeguard, which uses `sb-ext:with-timeout` on
SBCL and is a portable no-op on other implementations — the explicit size and
depth [limits](security.md) remain the safeguards there.

## Verifying the install

A quick REPL round-trip confirms the system is loaded:

```lisp
(json-kit:stringify (json-kit:parse "[1,2,3]"))
;; => "[1,2,3]"
```

To run the test suite from a checkout:

```sh
sbcl --script run-tests.lisp
```

or, reproducibly, with Nix:

```sh
nix flake check
```
