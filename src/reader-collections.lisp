;;;; src/reader-collections.lisp
;;;;
;;;; The recursive core: value dispatch, object and array parsing, and the
;;;; continuation-passing callback plumbing they lean on.
;;;;
;;;; Design note (the whole point of this library): PARSE-OBJECT always reads
;;;; "{...}" as key/value pairs and PARSE-ARRAY always reads "[...]" as values.
;;;; Whether the pairs become a HASH-TABLE or an ALIST, and the values a
;;;; SIMPLE-VECTOR or a LIST, is decided once here from :OBJECT-TYPE /
;;;; :ARRAY-TYPE -- never guessed later by inspecting already-built Lisp data.
(in-package #:json-kit)

;;; ---------------------------------------------------------------------
;;; User callbacks (continuation-passing)
;;; ---------------------------------------------------------------------
(defun callback-failure-expectation (label condition)
  "The bounded \"expected\" text describing a user callback LABEL that failed
with CONDITION."
  (let ((diagnostic
          (handler-case
              (safe-diagnostic-snippet
               (format nil "~A: ~A" (type-of condition) condition))
            (error () (safe-diagnostic-snippet (type-of condition))))))
    (format nil "successful ~A callback (cause: ~A)" label diagnostic)))

(defun invoke-json-callback (state label function arguments continuation)
  "Apply FUNCTION to ARGUMENTS as the user callback LABEL, then tail-call
CONTINUATION with the result.  A JSON-PARSE-ERROR from the callback is
re-signalled unchanged; any other error becomes a located parse error.  The
callback runs under the error guard but CONTINUATION does not, so a failure in
the continuation is never misattributed to the callback."
  (funcall continuation
           (handler-case (apply function arguments)
             (json-parse-error (condition) (error condition))
             (error (condition)
               (parse-error-here state (callback-failure-expectation label condition))))))

(defun json-key->lisp-key (key-string state)
  "Map a raw JSON KEY-STRING through the user KEY-DECODER, requiring a string
result; with no decoder the key is returned unchanged."
  (if (ps-key-decoder state)
      (with-json-callback (converted state "KEY-DECODER" (ps-key-decoder state) key-string)
        (unless (stringp converted)
          (parse-error-here state "KEY-DECODER callback returning a string"))
        converted)
      key-string))

;;; ---------------------------------------------------------------------
;;; Value dispatch
;;; ---------------------------------------------------------------------
(defun parse-value (state)
  "Parse any single JSON value at the cursor, after leading whitespace."
  (skip-whitespace state)
  (let ((character (ps-peek state)))
    (unless character (parse-error-here state "JSON value"))
    (cond
      ((char= character #\") (parse-json-string state))
      ((char= character #\{) (parse-object state))
      ((char= character #\[) (parse-array state))
      ((or (ascii-json-digit-p character) (char= character #\-)) (parse-number state))
      ((char= character #\t) (parse-literal state "true" (ps-true-value state)))
      ((char= character #\f) (parse-literal state "false" (ps-false-value state)))
      ((char= character #\n) (parse-literal state "null" (ps-null-value state)))
      (t (parse-error-here state "JSON value")))))

;;; ---------------------------------------------------------------------
;;; Objects
;;; ---------------------------------------------------------------------
(defun record-object-member (state result seen converted-key value present-p prior)
  "Add CONVERTED-KEY/VALUE to the accumulating object under the current
DUPLICATE-KEY-POLICY, updating the SEEN table, and return the (possibly new)
RESULT accumulator.  For :HASH-TABLE, RESULT is the table itself; for :ALIST it
is the reversed member list being consed.  SEEN is NIL on the fast path (a
HASH-TABLE object under :LAST needs no duplicate tracking); REMEMBER then does
nothing, since a repeat key simply overwrites the table entry."
  (flet ((alist-p () (eq (ps-object-type state) :alist))
         (remember (key cell) (when seen (setf (gethash key seen) cell))))
    (ecase (ps-duplicate-key-policy state)
      (:preserve (cons (cons converted-key value) result))
      (:first
       (when present-p (return-from record-object-member result))
       (cond
         ((alist-p)
          (let ((pair (cons converted-key value)))
            (remember converted-key pair)
            (cons pair result)))
         (t (setf (gethash converted-key result) value)
            (remember converted-key t)
            result)))
      ((:last :error)
       (cond
         ((not (alist-p))
          (setf (gethash converted-key result) value)
          (remember converted-key t)
          result)
         (present-p (setf (cdr prior) value) result)
         (t (let ((pair (cons converted-key value)))
              (remember converted-key pair)
              (cons pair result))))))))

(defun read-object-member (state result seen)
  "Read one \"key\":value pair at the cursor and fold it into RESULT via
RECORD-OBJECT-MEMBER, mutating SEEN as a side effect (and signalling if
DUPLICATE-KEY-POLICY is :ERROR and the key repeats).  Returns the (possibly
new) RESULT accumulator, exactly as RECORD-OBJECT-MEMBER does."
  (skip-whitespace state)
  (unless (eql (ps-peek state) #\")
    (parse-error-here state "object key string"))
  (let* ((key (parse-json-string state))
         (converted-key (with-parser-path (state key)
                          (json-key->lisp-key key state))))
    (multiple-value-bind (prior present-p)
        (if seen (gethash converted-key seen) (values nil nil))
      (when (and present-p (eq (ps-duplicate-key-policy state) :error))
        (with-parser-path (state key)
          (parse-error-here state "unique object key")))
      (skip-whitespace state)
      (expect-char state #\:)
      (skip-whitespace state)
      (let ((value (with-parser-path (state key) (parse-value state))))
        (record-object-member state result seen converted-key value present-p prior)))))

(defun parse-object (state)
  "Parse a JSON object into a HASH-TABLE or an ALIST per :OBJECT-TYPE."
  (with-nesting-guard (state)
    (expect-char state #\{)
    (skip-whitespace state)
    ;; Fast path: a HASH-TABLE object under :LAST just overwrites on a repeat
    ;; key, so it needs no separate SEEN table -- saving that allocation and a
    ;; gethash/sethash per member, which dominates parsing a large object.
    (let* ((fast-last-p (and (eq (ps-object-type state) :hash-table)
                             (eq (ps-duplicate-key-policy state) :last)))
           (result (when (eq (ps-object-type state) :hash-table)
                     (make-hash-table :test #'equal)))
           (seen (unless fast-last-p (make-hash-table :test #'equal)))
           (count 0))
      (unless (eql (ps-peek state) #\})
        (loop
          (when (>= count (ps-max-object-members state))
            (parse-error-here state "fewer object members"))
          (incf count)
          (setf result (read-object-member state result seen))
          (consume-separator-or-finish
              (state #\} "object member" "comma or closing brace")
            (return))))
      (expect-char state #\})
      (let ((object (if (eq (ps-object-type state) :alist)
                        (nreverse result)
                        result)))
        (if (ps-object-hook state)
            (with-json-callback (hooked state "OBJECT-HOOK" (ps-object-hook state) object)
              hooked)
            object)))))

;;; ---------------------------------------------------------------------
;;; Arrays
;;; ---------------------------------------------------------------------
(defun parse-array (state)
  "Parse a JSON array into a SIMPLE-VECTOR or a LIST per :ARRAY-TYPE."
  (with-nesting-guard (state)
    (let ((vector-p (eq (ps-array-type state) :vector)))
      (expect-char state #\[)
      (skip-whitespace state)
      (let ((elements (when vector-p
                        (make-array 0 :adjustable t :fill-pointer 0)))
            (count 0)
            (saved-path (ps-path state))
            ;; One reused cons instead of WITH-PARSER-PATH's fresh cons per
            ;; element: the error path only ever reads (PS-PATH STATE)
            ;; synchronously and PARSE-ERROR-HERE copies it, so mutating this
            ;; frame's index between elements is safe and saves an allocation
            ;; per element -- the difference between O(n) and zero path conses
            ;; for a million-element array.
            (path-frame nil))
        (unless (eql (ps-peek state) #\])
          (setf path-frame (cons 0 saved-path))
          (unwind-protect
               (loop
                 (when (>= count (ps-max-array-elements state))
                   (parse-error-here state "fewer array elements"))
                 (skip-whitespace state)
                 (setf (car path-frame) count
                       (ps-path state) path-frame)
                 (let ((value (parse-value state)))
                   (setf (ps-path state) saved-path)
                   (if vector-p
                       (vector-push-extend value elements)
                       (push value elements)))
                 (incf count)
                 (consume-separator-or-finish
                     (state #\] "array value" "comma or closing bracket")
                   (return)))
            (setf (ps-path state) saved-path)))
        (expect-char state #\])
        (let ((array (if vector-p
                         (coerce elements 'simple-vector)
                         (nreverse elements))))
          (if (ps-array-hook state)
              (with-json-callback (hooked state "ARRAY-HOOK" (ps-array-hook state) array)
                hooked)
              array))))))
