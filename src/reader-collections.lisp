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
(defun parse-value-at-current (state)
  "Parse one JSON value starting at the current cursor without skipping whitespace."
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

(defun parse-value (state)
  "Parse one JSON value after skipping leading RFC JSON whitespace."
  (skip-whitespace state)
  (parse-value-at-current state))

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
      (let ((value (with-parser-path (state key) (parse-value-at-current state))))
        (record-object-member state result seen converted-key value present-p prior)))))

(defun parse-object (state)
  "Parse a JSON object into a HASH-TABLE or an ALIST per :OBJECT-TYPE."
  (with-nesting-guard (state)
    (expect-char state #\{)
    (skip-whitespace state)
    (let* ((fast-last-p (and (eq (ps-object-type state) :hash-table)
                             (eq (ps-duplicate-key-policy state) :last)))
           (key-decoder (when fast-last-p (ps-key-decoder state)))
           (max-members (ps-max-object-members state))
           (result (when (eq (ps-object-type state) :hash-table)
                     (make-hash-table :test (function equal) :rehash-size 2.0)))
           (seen
             (unless (or fast-last-p
                         (and (eq (ps-object-type state) :alist)
                              (eq (ps-duplicate-key-policy state) :preserve)))
               (make-hash-table :test (function equal))))
           (count 0))
      (labels ((parse-fast-last-members ()
                 ;; The default HASH-TABLE/:LAST case can overwrite duplicates
                 ;; directly, so this loop stays free of the representation and
                 ;; duplicate-policy dispatch that READ-OBJECT-MEMBER carries.
                 (let* ((saved-path (ps-path state))
                        (path-frame (cons nil saved-path)))
                   (unwind-protect
                        (loop
                          (when (>= count max-members)
                            (parse-error-here state "fewer object members"))
                          (incf count)
                          (unless (eql (ps-peek state) #\")
                            (parse-error-here state "object key string"))
                          (let* ((key (parse-json-string state))
                                 (converted-key
                                   (if key-decoder
                                       (progn
                                         (setf (car path-frame) key
                                               (ps-path state) path-frame)
                                         (prog1 (json-key->lisp-key key state)
                                           (setf (ps-path state) saved-path)))
                                       key)))
                            (skip-whitespace state)
                            (expect-char state #\:)
                            (setf (car path-frame) key
                                  (ps-path state) path-frame
                                  (gethash converted-key result) (parse-value state)
                                  (ps-path state) saved-path))
                          (consume-separator-or-finish
                              (state #\} "object member" "comma or closing brace")
                            (return)))
                     (setf (ps-path state) saved-path))))
               (parse-general-members ()
                 (loop
                   (when (>= count max-members)
                     (parse-error-here state "fewer object members"))
                   (incf count)
                   (setf result (read-object-member state result seen))
                   (consume-separator-or-finish
                       (state #\} "object member" "comma or closing brace")
                     (return)))))
        (unless (eql (ps-peek state) #\})
          (if fast-last-p
              (parse-fast-last-members)
              (parse-general-members))))
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
      (let ((elements nil)
            (chunks nil)
            (chunk nil)
            (chunk-position 0)
            (count 0)
            (max-elements (ps-max-array-elements state))
            (saved-path (ps-path state))
            ;; One reused cons instead of WITH-PARSER-PATH per element.
            (path-frame nil))
        (labels ((grow-chunk (value)
                   (when (= chunk-position (length chunk))
                     (push chunk chunks)
                     (setf chunk (make-array 256)
                           chunk-position 0))
                   (setf (svref chunk chunk-position) value)
                   (incf chunk-position))
                 (promote-to-chunk (value)
                   ;; The 257th vector element: move ELEMENTS into a fresh 512-element CHUNK.
                   (setf chunk (make-array 512))
                   (loop for prior in elements
                         for index downfrom 255
                         do (setf (svref chunk index) prior))
                   (setf elements nil
                         chunk-position 257
                         (svref chunk 256) value))
                 (collect-element (value)
                   (if vector-p
                       (cond
                         (chunk (grow-chunk value))
                         ((< count 256) (push value elements))
                         (t (promote-to-chunk value)))
                       (push value elements))))
          (unless (eql (ps-peek state) #\])
            (setf path-frame (cons 0 saved-path))
            (unwind-protect
                 (loop
                   (when (>= count max-elements)
                     (parse-error-here state "fewer array elements"))
                   (setf (car path-frame) count
                         (ps-path state) path-frame)
                   (let ((value (parse-value-at-current state)))
                     (setf (ps-path state) saved-path)
                     (collect-element value))
                   (incf count)
                   (consume-separator-or-finish
                       (state #\] "array value" "comma or closing bracket")
                     (return)))
              (setf (ps-path state) saved-path))))
        (expect-char state #\])
        (let ((array
                (if vector-p
                    (if chunk
                        (if (and (= count 512)
                                 (null chunks)
                                 (= chunk-position (length chunk)))
                            chunk
                            (let ((result (make-array count))
                                  (offset 0))
                              (dolist (completed (nreverse chunks))
                                (replace result completed :start1 offset)
                                (incf offset (length completed)))
                              (replace result chunk
                                       :start1 offset
                                       :end2 chunk-position)
                              result))
                        (coerce (nreverse elements) (quote simple-vector)))
                    (nreverse elements))))
          (if (ps-array-hook state)
              (with-json-callback (hooked state "ARRAY-HOOK" (ps-array-hook state) array)
                hooked)
              array))))))
