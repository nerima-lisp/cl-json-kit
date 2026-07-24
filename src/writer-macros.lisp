;;;; src/writer-macros.lisp
;;;;
;;;; The writer's cross-cutting control-flow, named once here as a macro so
;;;; the writer-* logic files read as intent ("with this path pushed", "emit
;;;; this bracketed collection") rather than repeated let/unwind-protect
;;;; bookkeeping.  DO-PROPER-LIST also serves CONVERSION.LISP's alist
;;;; validation, since both walk a bounded proper list the same way.
;;;;
;;;; The bodies reference functions and specials defined in later files
;;;; (SERIALIZATION-ERROR, EMIT-CHARACTER, ...); that is fine because a
;;;; macro's expansion is only evaluated where it is *used*, and the :SERIAL
;;;; system loads those definitions before any use site is compiled.
(in-package #:json-kit)

;;; ---------------------------------------------------------------------
;;; Serialization path and cycle guarding
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
;;; Data-driven string escapes (encode direction)
;;; ---------------------------------------------------------------------
;;; Expands +JSON-SHORT-ESCAPES+ (see data.lisp) into a CASE at compile time;
;;; JSON-UNESCAPE-CHAR in reader-macros.lisp expands the same table for the
;;; decode direction, so the two can never drift apart.
(defmacro json-escape-letter (character)
  "Escape letter for CHARACTER's short escape sequence, or NIL when CHARACTER
has no short escape (so the caller falls back to \", \\ or \\uXXXX)."
  `(case ,character
     ,@(loop for (character-key . letter-char) in +json-short-escapes+
             collect `(,character-key ,letter-char))
     (t nil)))

;;; ---------------------------------------------------------------------
;;; Bounded proper-list traversal
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

(defmacro with-json-brackets ((open close level count) &body body)
  "Emit OPEN, run BODY (which must call EMIT-JSON-MEMBER for each member), then
emit a final pretty-print indent when COUNT is positive and CLOSE.  This is the
one place WRITE-JSON-ARRAY-SEQUENCE, WRITE-JSON-OBJECT, and
WRITE-JSON-ORDERED-OBJECT open and close a JSON aggregate."
  (let ((count-var (gensym "COUNT")))
    `(let ((,count-var ,count))
       (emit-character ,open)
       ,@body
       (when (and *json-pretty* (plusp ,count-var)) (emit-indent ,level))
       (emit-character ,close))))

(defmacro emit-json-member ((index level) &body body)
  "Within a WITH-JSON-BRACKETS body, separate this member from the previous one
with a comma (unless INDEX is zero), indent it for pretty output, then run BODY
to emit the member's content."
  `(progn
     (unless (zerop ,index) (emit-character #\,))
     (when *json-pretty* (emit-indent (1+ ,level)))
     ,@body))
