;;;; src/reader-macros.lisp
;;;;
;;;; The reader's cross-cutting control-flow, named once here as a macro so
;;;; the reader-* logic files read as intent ("with this path pushed", "invoke
;;;; this callback then continue") rather than repeated let/unwind-protect
;;;; bookkeeping.
;;;;
;;;; The bodies reference functions and specials defined in later files
;;;; (PS-PATH, PARSE-ERROR-HERE, ...); that is fine because a macro's
;;;; expansion is only evaluated where it is *used*, and the :SERIAL system
;;;; loads those definitions before any use site is compiled.
(in-package #:json-kit)

;;; ---------------------------------------------------------------------
;;; JSON path bookkeeping
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
;;; Nesting and separator scaffolding
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
;;; User callbacks in continuation-passing style
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
;;; Optional wall-clock timeout
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
;;; Data-driven string escapes (decode direction)
;;; ---------------------------------------------------------------------
;;; Expands +JSON-SHORT-ESCAPES+ (see data.lisp) into a CASE at compile time;
;;; JSON-ESCAPE-LETTER in writer-macros.lisp expands the same table for the
;;; encode direction, so the two can never drift apart.
(defmacro json-unescape-char (letter)
  "Character named by an escape LETTER following a backslash, or NIL if LETTER
is not a recognised short escape.  `u' is intentionally excluded: it begins a
multi-character \\uXXXX sequence the caller must handle separately."
  `(case ,letter
     (#\" #\") (#\\ #\\) (#\/ #\/)
     ,@(loop for (character . letter-char) in +json-short-escapes+
             collect `(,letter-char ,character))
     (t nil)))

;;; ---------------------------------------------------------------------
;;; Callback-designator coercion
;;; ---------------------------------------------------------------------
;;; Lives here (rather than in WRITER-MACROS.LISP) only because this file
;;; loads first; the pattern itself is not reader-specific -- RESOLVE-PARSER-
;;; CALLBACK (reader.lisp, one call per KEY-DECODER/NUMBER-DECODER/OBJECT-HOOK/
;;; ARRAY-HOOK) and RESOLVE-NUMBER-ENCODER (writer-state.lisp) both coerce a
;;; NIL/function/fbound-symbol designator the same way and previously
;;; re-wrote this three-branch COND by hand in each place.
(defmacro resolve-callback-designator (designator on-invalid)
  "DESIGNATOR coerced to a function: NIL passes through as NIL, a function
passes through unchanged, and an fbound symbol becomes its SYMBOL-FUNCTION.
Anything else evaluates ON-INVALID instead -- typically the caller's own
located error form -- rather than returning a value."
  (let ((designator-var (gensym "DESIGNATOR")))
    `(let ((,designator-var ,designator))
       (cond
         ((null ,designator-var) nil)
         ((functionp ,designator-var) ,designator-var)
         ((and (symbolp ,designator-var) (fboundp ,designator-var))
          (symbol-function ,designator-var))
         (t ,on-invalid)))))

(defmacro call-with-forwarded-parse-keywords (function &rest leading-arguments)
  "Call FUNCTION with LEADING-ARGUMENTS followed by every keyword in
+PARSE-KEYWORDS+, each forwarded from a same-named lexical variable already
bound in the caller.  PARSE uses this so a new entry in +PARSE-KEYWORDS+ never
needs a second, hand-written forwarding edit here.  +PARSE-KEYWORDS+ is looked
up via SYMBOL-VALUE, not referenced directly, because READER-MACROS.LISP loads
before PARSER-STATE.LISP defines it; only this macro's *expansion* -- compiled
later, once a caller like PARSE is compiled -- ever needs its value."
  `(funcall ,function ,@leading-arguments
            ,@(loop for keyword in (symbol-value '+parse-keywords+)
                    append (list keyword (intern (symbol-name keyword))))))
