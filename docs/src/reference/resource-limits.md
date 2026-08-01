# Resource Limits and Security

`cl-json-kit` is designed to be given **untrusted input**. Every reader and
writer entry point enforces finite bounds by default, and the bounds are
applied *before* untrusted input can grow without limit.

## Default limits

| Operation | Limit | Default | Unit / scope |
| --- | --- | ---: | --- |
| read | `max-input-length` | 16 Mi | characters in the complete input |
| read | `max-string-length` | 1 Mi | decoded characters in one string |
| read | `max-number-length` | 1024 | characters in one number token |
| read | `max-exact-exponent` | 10,000 | absolute decimal scale used by exact numeric fallback |
| read | `max-array-elements` | 1,000,000 | elements in one array |
| read | `max-object-members` | 1,000,000 | members in one object |
| read / write | `max-depth` | 512 | nested arrays / objects |
| write | `max-elements` | 1,000,000 | aggregate elements and members |
| write | `max-output-length` | 16 Mi | emitted characters |

*Mi = mebi (2²⁰).*

## Boundary semantics

Every limit **accepts exactly the configured boundary and rejects the next
unit**. There is no off-by-one ambiguity:

```lisp
(json-kit:parse "\"1234\""  :max-string-length 4)  ; => "1234"
(json-kit:parse "\"12345\"" :max-string-length 4)  ; signals JSON-PARSE-ERROR

(json-kit:parse "[1]"   :max-array-elements 1)      ; => #(1)
(json-kit:parse "[1,2]" :max-array-elements 1)      ; signals JSON-PARSE-ERROR

(json-kit:stringify "abc" :max-output-length 5)     ; => "\"abc\""
(json-kit:stringify "abc" :max-output-length 4)     ; signals a serialization error
```

## Choosing limits for the trust boundary

The defaults are conservative but generic. **Choose limits for your workload
and trust boundary rather than relying on the defaults for everything.** A
public HTTP endpoint accepting request bodies should typically set much tighter
`max-input-length`, `max-depth`, `max-array-elements`, and `max-object-members`
than an internal tool reading trusted configuration.

Tighter bounds cost nothing and shrink the resources an adversary can force you
to spend before the parse is rejected.

## The exact-numeric fallback

When decoding a non-integer number, the built-in decoder maps ordinary values
to `double-float`. If float conversion overflows or underflows, it falls back
to an exact integer or ratio rather than rejecting an otherwise valid JSON
number — for example, `1e400` becomes an exact integer.

`max-exact-exponent` bounds the absolute decimal scale used by that fallback.
It must be a non-negative integer and prevents an untrusted exponent from
requesting an enormous `expt` computation. If you never want the exact fallback
to do significant work, keep this small.

## The SBCL timeout safeguard

On SBCL, `:timeout-seconds` adds a wall-clock guard around a parse using
`sb-ext:with-timeout`:

```lisp
(json-kit:parse untrusted-input :timeout-seconds 2)
```

!!! warning "The timeout supplements, it does not replace, the size limits"
    - On non-SBCL implementations, `:timeout-seconds` is a **portable no-op** —
      the explicit size and depth limits remain the only safeguards.
    - Even on SBCL, interruption timing follows SBCL's timeout semantics and
      does not replace the size and depth limits. Keep the structural limits
      tight regardless of the timeout.

## Bounded diagnostics

The library's error reports are themselves bounded: attacker-influenced
strings, paths, and expected-value descriptions are truncated and escaped
before they reach a condition slot, so logging an error cannot echo an
unbounded or control-character-laden payload. See
[Error Handling](conditions.md#bounded-diagnostics-as-a-security-property).

## Thread safety

The reader keeps no global mutable state: each `parse` / `parse-prefix` /
`read-json` call works through its own freshly allocated parser state. The
writer's configuration lives in dynamic (`defvar`) special variables, but
`write-json` and `stringify` `let`-bind every one of them fresh on every call,
so concurrent calls on separate threads never see each other's bindings.
Independent calls on independent data from different threads need no external
locking. You are still responsible for your own synchronization if multiple
threads write to the *same* stream, or read/mutate the *same* hash table or
`json-object`, concurrently. See the
[FAQ](../guide/troubleshooting.md#is-cl-json-kit-thread-safe) for more detail.

## What the limits do not cover

- **Encoding attacks** belong to the stream / external-format layer. The API
  operates on characters, not octets; validate and decode bytes before they
  reach `cl-json-kit`. See [RFC 8259 Scope](rfc-8259.md).
- **Semantic validation** (schema, required keys, value ranges) is the
  application's responsibility. `cl-json-kit` guarantees a well-formed,
  bounded parse — not that the parsed document means what you expect.
