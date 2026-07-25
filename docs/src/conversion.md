# Conversion Helpers

Because a plain list is always a JSON *array*, converting an alist into a JSON
*object* is an **explicit** step. These helpers provide that bridge, plus an
ordered object representation that preserves member order and duplicate keys.

## Overview

```lisp
(json-kit:make-json-object members &key (max-elements 1000000))

(json-kit:json-object-p value)

(json-kit:json-object-members object)

(json-kit:alist->json-object alist
  &key (duplicate-key-policy :error) (max-elements 1000000))

(json-kit:json-object->alist object
  &key (max-elements 1000000))
```

## `alist->json-object`

Validates a proper, acyclic alist with string keys and returns a JSON object.
The duplicate-key policy accepts `:error` (default), `:first`, `:last`, or
`:preserve`:

- `:error`, `:first`, and `:last` return a **hash table**.
- `:preserve` returns a **`json-object`** whose member order and duplicate keys
  are preserved.

```lisp
(json-kit:stringify
 (json-kit:alist->json-object
  (list (cons "a" 1) (cons "b" 2)))
 :sort-keys t)
;; => "{\"a\":1,\"b\":2}"
```

Because the conversion is explicit, a plain list is never misread as an object:

```lisp
(json-kit:stringify (list (cons 1 2) (cons 3 4)))
;; signals JSON-SERIALIZATION-ERROR — the nested conses are dotted lists,
;; and the list was never asked to become an object.
```

## `make-json-object`, `json-object-p`, `json-object-members`

`make-json-object` constructs the explicit ordered representation directly from
a list of `(key . value)` members. `json-object-p` identifies such a value, and
`json-object-members` returns its ordered alist.

```lisp
(let ((object (json-kit:make-json-object (list (cons "x" 1) (cons "y" 2)))))
  (values (json-kit:json-object-p object)
          (json-kit:json-object-members object)))
;; => T, (("x" . 1) ("y" . 2))
```

The writer accepts a `json-object` wherever it accepts a hash table, but unlike
a hash table it guarantees member order and can carry duplicate keys.

## `json-object->alist`

Accepts a `json-object`, a hash table, or a validated alist and returns an
alist of members.

```lisp
(json-kit:json-object->alist
 (json-kit:make-json-object (list (cons "x" 1))))
;; => (("x" . 1))
```

!!! note "Hash-table conversion does not define pair order"
    Converting a hash table to an alist does not define the order of pairs —
    hash-table iteration order is unspecified. Use a `json-object` (or
    `:sort-keys` when writing) when order matters.

## Round-tripping duplicate members

Duplicate object members survive a full round trip through the explicit
representation:

```lisp
(let* ((text "{\"a\":1,\"a\":2}")
       (members (json-kit:parse text
                  :object-type :alist
                  :duplicate-key-policy :preserve))
       (object (json-kit:alist->json-object
                members
                :duplicate-key-policy :preserve)))
  (json-kit:stringify object))
;; => "{\"a\":1,\"a\":2}"
```

Here [`parse`](reading.md#duplicate-object-keys) with `:preserve` yields an
ordered alist of every pair, `alist->json-object` with `:preserve` wraps it in
a `json-object`, and [`stringify`](writing.md) emits the members in order,
duplicates and all.
