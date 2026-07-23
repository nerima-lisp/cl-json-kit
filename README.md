# cl-json-kit

A dependency-free, SBCL-only JSON library for Common Lisp, offering an API
shaped like JavaScript's `JSON.parse`/`JSON.stringify` and Python's `json`
module: two functions, `parse` and `stringify`, with a small set of keyword
arguments that make every design decision explicit instead of guessed.

## Why another JSON library?

Two sibling projects in this organization already had JSON support, and both
had a real weakness:

- One project decided whether a Lisp value was a "JSON object" by *guessing*:
  if it looked like a list of conses, it was serialized as an object. A plain
  array of pairs that happened to be represented as a list of conses could
  therefore be silently mis-serialized as an object instead of an array --
  an ambiguity bug baked into the design.
- The other project separated objects (hash-tables) from arrays (vectors) by
  type, so it had no such ambiguity, but it didn't decode `\uXXXX` UTF-16
  surrogate pairs (so codepoints outside the Basic Multilingual Plane, like
  most emoji, came out wrong) and had no way to bound how long a parse could
  run.

`cl-json-kit` is built to avoid both problems at once:

- **No shape-guessing, ever.** `parse` decides whether `{...}` becomes a
  `hash-table` or an `alist`, and whether `[...]` becomes a `simple-vector`
  or a `list`, at the moment it finishes reading that object/array -- from
  the `:object-type`/`:array-type` arguments alone. `stringify` dispatches
  purely on the Lisp *type* of a value (`hash-table` -> object,
  `vector`/`list` -> array); it never inspects a cons list's contents to
  decide it "looks like" an alist. If you want an alist serialized as an
  object, you say so explicitly with `alist->json-object`.
- **Correct surrogate pair decoding.** A `\uD800`-`\uDBFF` high surrogate
  immediately followed by a `\uDC00`-`\uDFFF` low surrogate escape combines
  into one character outside the BMP (e.g. `😀`).
- **Optional timeout protection.** `parse`'s `:timeout-seconds` wraps the
  whole parse in `sb-ext:with-timeout`.

## Installation

### Nix flake

```
nix build github:nerima-lisp/cl-json-kit
```

Or add it as a flake input and use `packages.<system>.cl-json-kit` /
`devShells.<system>.default`.

### Quicklisp-local / ASDF

Clone this repository somewhere ASDF can find it (e.g. add it to
`CL_SOURCE_REGISTRY` or `~/quicklisp/local-projects/`), then:

```lisp
(asdf:load-system "cl-json-kit")
```

## Usage

```lisp
(json-kit:parse "{\"name\": \"Ada\", \"tags\": [\"a\", \"b\"]}")
;; => a HASH-TABLE, e.g. #<HASH-TABLE ...> with keys :NAME, :TAGS

(json-kit:parse "{\"name\": \"Ada\"}" :object-type :alist :key-type :string)
;; => (("name" . "Ada"))

(json-kit:parse "[1, 2, 3]" :array-type :list)
;; => (1 2 3)

(json-kit:parse "\"\\ud83d\\ude00\"")
;; => "😀"  (one character, decoded from the UTF-16 surrogate pair)

(json-kit:parse "{not json" :context "config.json" :timeout-seconds 1)
;; => signals JSON-KIT:JSON-PARSE-ERROR with
;;    (json-parse-error-context c)  => "config.json"
;;    (json-parse-error-position c) => the offending index

(let ((table (make-hash-table :test #'equal)))
  (setf (gethash "name" table) "Ada")
  (json-kit:stringify table))
;; => "{\"name\":\"Ada\"}"

(json-kit:stringify #(1 2 3))
;; => "[1,2,3]"

;; A plain list of conses is an array of arrays, never an inferred object:
(json-kit:stringify (list (cons 1 2) (cons 3 4)))
;; => "[[1,2],[3,4]]"

;; To write an alist as a JSON object, say so explicitly:
(json-kit:stringify
 (json-kit:alist->json-object (list (cons "a" 1) (cons "b" 2))))
;; => "{\"a\":1,\"b\":2}"

(json-kit:stringify (list 1 2) :pretty t)
;; => "[
;;       1,
;;       2
;;     ]"
```

## API

- `(parse string &key (object-type :hash-table) (array-type :vector) (key-type :keyword) (context "json") timeout-seconds)`
- `(stringify value &key pretty (indent 2))`
- `json-parse-error`, with readers `json-parse-error-position`,
  `json-parse-error-context`, `json-parse-error-text`
- `(alist->json-object alist)` -- wrap an alist so it is written as a JSON
  object.
- `(json-object->alist obj)` -- convert a hash-table (or alist) object back
  into an alist.

See the docstrings on `parse` and `stringify` for the full contract,
including exactly how `t`/`:false`/`:null`/`nil` map to `true`/`false`/`null`
and the empty array.

## Design notes: the object/array type decision

`parse`'s internal object/array readers always read `{...}` as a sequence of
key/value pairs and `[...]` as a sequence of values first; only once reading
is complete do they build a `hash-table`/`alist` or `simple-vector`/`list`
from `:object-type`/`:array-type`. Nothing downstream re-inspects the
resulting Lisp value to guess its intended JSON shape.

Symmetrically, `stringify` dispatches on `typecase`: `hash-table` is always
an object; any non-string `vector` or `list` (proper or dotted) is always an
array, element by element, regardless of whether its elements happen to be
`cons` cells that could be misread as `(key . value)` pairs. This is why
`(stringify (list (cons 1 2) (cons 3 4)))` is `"[[1,2],[3,4]]"`, not
`"{\"1\":2,\"3\":4}"` -- there is no code path in `stringify` that inspects a
list's contents to decide it is "really" an alist. If an alist is meant to
become a JSON object, wrap it first with `alist->json-object`.

## Testing

```
sbcl --script run-tests.lisp
```

or, with Nix:

```
nix flake check
```

## License

MIT. See [LICENSE](LICENSE).
