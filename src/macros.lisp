;;;; src/macros.lisp
;;;;
;;;; Every cross-cutting control-flow shape in the library is named once here
;;;; as a macro, so the logic files read as intent ("with this path pushed",
;;;; "invoke this callback then continue", "walk this proper list") rather than
;;;; as repeated let/unwind-protect/tortoise-and-hare bookkeeping.
;;;;
;;;; The bodies reference functions and specials defined in later files
;;;; (PS-PATH, PARSE-ERROR-HERE, SERIALIZATION-ERROR, ...); that is fine
;;;; because a macro's expansion is only evaluated where it is *used*, and the
;;;; :SERIAL system loads those definitions before any use site is compiled.
(in-package #:json-kit)

;;; ---------------------------------------------------------------------
;;; Reader: JSON path bookkeeping
;;; ---------------------------------------------------------------------
(defmacro with-parser-path ((state component) &body body)
  "Run BODY with COMPONENT pushed onto STATE's error path, then always pop it.
This is how the reader keeps JSON-PARSE-ERROR-PATH pointing at the member or
array index currently being read, even when BODY unwinds via an error."
  (let ((state-var (gensym "STATE"))
        (saved (gensym "SAVED-PATH")))
    `(let* ((,state-var ,state)
            (,saved (ps-path ,state-var)))
       (setf (ps-path ,state-var) (cons ,component ,saved))
       (unwind-protect (progn ,@body)
         (setf (ps-path ,state-var) ,saved)))))

;;; ---------------------------------------------------------------------
;;; Reader: nesting and separator scaffolding
;;; ---------------------------------------------------------------------
(defmacro with-nesting-guard ((state) &body body)
  "Run BODY one nesting level deeper in STATE, signalling before MAX-DEPTH is
exceeded and always restoring the depth on the way out.  This is the single
place PARSE-OBJECT and PARSE-ARRAY manage recursion depth."
  (let ((state-var (gensym "STATE")))
    `(let ((,state-var ,state))
       (when (>= (ps-depth ,state-var) (ps-max-depth ,state-var))
         (parse-error-here ,state-var "shallower nesting"))
       (incf (ps-depth ,state-var))
       (unwind-protect (progn ,@body)
         (decf (ps-depth ,state-var))))))

(defmacro consume-separator-or-finish
    ((state close-char trailing-message separator-message) &body on-close)
  "After one collection element, consume a comma (rejecting a trailing one that
precedes CLOSE-CHAR with TRAILING-MESSAGE) or run ON-CLOSE at CLOSE-CHAR;
anything else is a SEPARATOR-MESSAGE error.  CLOSE-CHAR must be a literal
character so it can serve as a CASE key."
  `(progn
     (skip-whitespace ,state)
     (case (ps-peek ,state)
       (#\,
        (ps-advance ,state)
        (skip-whitespace ,state)
        (when (eql (ps-peek ,state) ,close-char)
          (parse-error-here ,state ,trailing-message)))
       (,close-char ,@on-close)
       (t (parse-error-here ,state ,separator-message)))))

;;; ---------------------------------------------------------------------
;;; Reader: user callbacks in continuation-passing style
;;; ---------------------------------------------------------------------
(defmacro with-json-callback ((result-var state label function &rest arguments)
                              &body continuation)
  "Invoke FUNCTION on ARGUMENTS as the user callback named LABEL, then tail-call
CONTINUATION with RESULT-VAR bound to the result.  A plain error from the
callback is re-signalled as a JSON-PARSE-ERROR at the current position; a
JSON-PARSE-ERROR passes through untouched.  Because INVOKE-JSON-CALLBACK runs
CONTINUATION *outside* the callback's guard, a failure in the continuation is
never misreported as a callback failure."
  `(invoke-json-callback ,state ,label ,function (list ,@arguments)
                         (lambda (,result-var) ,@continuation)))

;;; ---------------------------------------------------------------------
;;; Reader: optional wall-clock timeout
;;; ---------------------------------------------------------------------
(defmacro with-optional-timeout ((timeout-seconds) &body body)
  "Run BODY under an SB-EXT:WITH-TIMEOUT budget of TIMEOUT-SECONDS when it is
non-NIL.  On implementations without SB-EXT:WITH-TIMEOUT, TIMEOUT-SECONDS is
accepted but has no effect, since there is no portable way to interrupt BODY
partway through; the caller's explicit size and depth limits remain the
enforceable bound in that case."
  `(if ,timeout-seconds
       #+sbcl (sb-ext:with-timeout ,timeout-seconds (progn ,@body))
       #-sbcl (progn ,@body)
       (progn ,@body)))

;;; ---------------------------------------------------------------------
;;; Writer: serialization path and cycle guarding
;;; ---------------------------------------------------------------------
(defmacro with-json-path ((component) &body body)
  "Run BODY with COMPONENT pushed onto the dynamic serialization path so a
JSON-SERIALIZATION-ERROR can report where in the value it occurred."
  `(let ((*json-serialization-path* (cons ,component *json-serialization-path*)))
     ,@body))

(defmacro with-active-aggregate ((value) &body body)
  "Run BODY while VALUE is marked as an in-progress aggregate, signalling a
serialization error if VALUE is already being written (a reference cycle).
The mark is always cleared on the way out so shared -- but acyclic -- subtrees
remain writable."
  (let ((value-var (gensym "VALUE")))
    `(let ((,value-var ,value))
       (when (gethash ,value-var *json-active-aggregates*)
         (serialization-error "circular aggregate value"))
       (setf (gethash ,value-var *json-active-aggregates*) t)
       (unwind-protect (progn ,@body)
         (remhash ,value-var *json-active-aggregates*)))))

;;; ---------------------------------------------------------------------
;;; Shared: data-driven string escapes
;;; ---------------------------------------------------------------------
;;; Both macros expand +JSON-SHORT-ESCAPES+ (see data.lisp) into a CASE at
;;; compile time, so the reader and writer share one table with no runtime
;;; lookup cost and no risk of the two directions disagreeing.
(defmacro json-unescape-char (letter)
  "Character named by an escape LETTER following a backslash, or NIL if LETTER
is not a recognised short escape.  `u' is intentionally excluded: it begins a
multi-character \\uXXXX sequence the caller must handle separately."
  `(case ,letter
     (#\" #\") (#\\ #\\) (#\/ #\/)
     ,@(loop for (character . letter-char) in +json-short-escapes+
             collect `(,letter-char ,character))
     (t nil)))

(defmacro json-escape-letter (character)
  "Escape letter for CHARACTER's short escape sequence, or NIL when CHARACTER
has no short escape (so the caller falls back to \", \\ or \\uXXXX)."
  `(case ,character
     ,@(loop for (character-key . letter-char) in +json-short-escapes+
             collect `(,character-key ,letter-char))
     (t nil)))

;;; ---------------------------------------------------------------------
;;; Shared: bounded proper-list traversal
;;; ---------------------------------------------------------------------
(defmacro do-proper-list ((element list &key count improper circular) &body body)
  "Walk LIST as a proper list with Brent's cycle detection, binding ELEMENT to
each car and running BODY, and evaluate to the total element count.

If COUNT is a symbol it is bound, during BODY, to the number of elements
already processed (a 0-based index) so BODY can enforce a size bound.  The
IMPROPER form runs on reaching a dotted tail and the CIRCULAR form runs on
detecting a cycle; both are expected to transfer control (typically by
signalling)."
  (let ((cursor (gensym "CURSOR"))
        (tortoise (gensym "TORTOISE"))
        (power (gensym "POWER"))
        (step (gensym "STEP"))
        (total (gensym "TOTAL"))
        (count-var (or count (gensym "INDEX"))))
    `(let ((,cursor ,list)
           (,tortoise ,list)
           (,power 1)
           (,step 0)
           (,total 0))
       (declare (ignorable ,total))
       (loop
         (when (null ,cursor) (return ,total))
         (unless (consp ,cursor)
           ,@(when improper (list improper))
           (return ,total))
         (let ((,element (car ,cursor))
               (,count-var ,total))
           (declare (ignorable ,element ,count-var))
           ,@body)
         (incf ,total)
         (setf ,cursor (cdr ,cursor))
         (incf ,step)
         (when (eq ,cursor ,tortoise)
           ,@(when circular (list circular))
           (return ,total))
         (when (= ,step ,power)
           (setf ,tortoise ,cursor
                 ,power (* 2 ,power)
                 ,step 0))))))
