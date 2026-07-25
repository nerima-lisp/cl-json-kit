;;;; Reproducible competitor benchmark for string DOM APIs.
(require :asdf)

(dolist (system '(:cl-json-kit :com.inuoe.jzon :jonathan :jsown :yason))
  (asdf:load-system system))

(defpackage #:cl-json-kit-benchmark.competitors (:use #:cl))

(in-package #:cl-json-kit-benchmark.competitors)

(progn
  (defun environment-integer (name default minimum)
    (let ((text (uiop:getenv name)))
      (if (null text)
          default
          (progn
            (unless (and (plusp (length text))
                         (every (lambda (character)
                                  (<= (char-code #\0)
                                      (char-code character)
                                      (char-code #\9)))
                                text))
              (error "~A must contain only decimal digits" name))
            (let ((value (parse-integer text)))
              (if (>= value minimum)
                  value
                  (error "~A must be at least ~D" name minimum)))))))
  (defun environment-choice (name default choices)
    (let ((value (or (uiop:getenv name) default)))
      (if (member value choices :test (function string=))
          value
          (error "~A must be one of ~{~A~^, ~}" name choices))))
  (defparameter *warmup-count* (environment-integer "BENCH_WARMUP" 2 0))
  (defparameter *seed* (environment-integer "BENCH_SEED" 20260724 0))
  (defparameter *operation-filter*
    (environment-choice "BENCH_OPERATIONS" "all" '("all" "parse" "stringify"))))


(defparameter *iteration-count* (environment-integer "BENCH_ITERATIONS" 5 1))

(defstruct adapter name version dom api stringify stringify-input parse object-p object-count object-has-key object-value array-p array-count array-value canonical-parse)

(defun system-version (name)
  (or (asdf:component-version (asdf:find-system name)) "unknown"))

(defun make-payload (length quote-period)
  (let ((result (make-string length)))
    (dotimes (index length result)
      (setf (char result index) (if (and quote-period (zerop (mod index quote-period))) #\"
          (code-char (+ (char-code #\a) (mod index 26))))))))

(defun make-array-json (count)
  (with-output-to-string (stream)
    (write-char #\[ stream)
    (dotimes (index count)
      (when (plusp index)
        (write-char #\, stream))
      (princ index stream))
    (write-char #\] stream)))

(defun make-object-json (count)
  (with-output-to-string (stream)
    (write-char #\{ stream)
    (dotimes (index count)
      (when (plusp index)
        (write-char #\, stream))
      (format stream "\"k~D\":~D" index index))
    (write-char #\} stream)))

(defun yason-stringify (value)
  (with-output-to-string (stream)
    (yason:encode value stream)))

(defun hash-object-value (object key)
  (gethash key object))

(progn
  (progn
  (defun vector-array-p (value)
    (and (vectorp value) (not (stringp value))))
  (defun list-array-value (value index)
    (nth index value)))
  (defun hash-object-has-key (object key)
    (nth-value 1 (gethash key object)))
  (defun jsown-object-p (value)
    (and (consp value) (eq (car value) :obj)))
  (defun jsown-object-count (value)
    (length (cdr value)))
  (defun jsown-object-has-key (object key)
    (not (null (assoc key (cdr object) :test (function string=)))))
  (defun canonical-to-hash-list (value)
    (cond
      ((hash-table-p value)
       (let ((result (make-hash-table :test (function equal))))
         (maphash (lambda (key member)
                    (setf (gethash key result)
                          (canonical-to-hash-list member)))
                  value)
         result))
      ((vector-array-p value)
       (map (quote list) (function canonical-to-hash-list) value))
      (t value)))
  (defun canonical-to-jsown (value)
    (cond
      ((hash-table-p value)
       (cons :obj
             (loop for key being the hash-keys of value
                   using (hash-value member)
                   collect (cons key (canonical-to-jsown member)))))
      ((vector-array-p value)
       (map (quote list) (function canonical-to-jsown) value))
      (t value)))
  (defun canonicalize-hash-vector (value null-value false-value true-value)
    (cond
      ((eq value null-value) :null)
      ((eq value false-value) :false)
      ((eq value true-value) t)
      ((hash-table-p value)
       (maphash (lambda (key member)
                  (setf (gethash key value)
                        (canonicalize-hash-vector
                         member null-value false-value true-value)))
                value)
       value)
      ((vector-array-p value)
       (map-into value
                 (lambda (member)
                   (canonicalize-hash-vector
                    member null-value false-value true-value))
                 value))
      (t value)))
  (defun canonicalize-jonathan
      (value null-value false-value empty-array-value empty-object-value)
    (cond
      ((eq value null-value) :null)
      ((eq value false-value) :false)
      ((eq value empty-array-value) #())
      ((eq value empty-object-value) (make-hash-table :test (function equal)))
      ((hash-table-p value)
       (maphash (lambda (key member)
                  (setf (gethash key value)
                        (canonicalize-jonathan
                         member null-value false-value
                         empty-array-value empty-object-value)))
                value)
       value)
      ((listp value)
       (map (quote vector)
            (lambda (member)
              (canonicalize-jonathan
               member null-value false-value
               empty-array-value empty-object-value))
            value))
      (t value)))
  (defun canonicalize-jsown (value null-value false-value empty-array-value)
    (cond
      ((eq value null-value) :null)
      ((eq value false-value) :false)
      ((eq value empty-array-value) #())
      ((jsown-object-p value)
       (let ((object (make-hash-table :test (function equal))))
         (dolist (member (cdr value) object)
           (setf (gethash (car member) object)
                 (canonicalize-jsown
                  (cdr member) null-value false-value empty-array-value)))))
      ((listp value)
       (map (quote vector)
            (lambda (member)
              (canonicalize-jsown
               member null-value false-value empty-array-value))
            value))
      (t value)))
  (defun make-adapters ()
    (let ((jzon-null (com.inuoe.jzon:parse "null"))
          (jonathan-null (make-symbol "JONATHAN-NULL"))
          (jonathan-false (make-symbol "JONATHAN-FALSE"))
          (jonathan-empty-array (make-symbol "JONATHAN-EMPTY-ARRAY"))
          (jonathan-empty-object (make-hash-table :test (function equal)))
          (jsown-null (make-symbol "JSOWN-NULL"))
          (jsown-false (make-symbol "JSOWN-FALSE"))
          (jsown-empty-array (make-symbol "JSOWN-EMPTY-ARRAY")))
      (list
       (make-adapter
        :name "cl-json-kit"
        :version (system-version :cl-json-kit)
        :dom "hash-table/vector/string; explicit scalar sentinels"
        :api "stringify(value); parse(string, hash-table/vector)"
        :stringify (function json-kit:stringify)
        :stringify-input (function identity)
        :parse (lambda (text)
                 (json-kit:parse text
                                 :object-type :hash-table
                                 :array-type :vector
                                 :null-value :null
                                 :false-value :false
                                 :true-value t))
        :object-p (function hash-table-p)
        :object-count (function hash-table-count)
        :object-has-key (function hash-object-has-key)
        :object-value (function hash-object-value)
        :array-p (function vector-array-p)
        :array-count (function length)
        :array-value (function aref)
        :canonical-parse (lambda (text)
                           (json-kit:parse text
                                           :object-type :hash-table
                                           :array-type :vector
                                           :null-value :null
                                           :false-value :false
                                           :true-value t)))
       (make-adapter
        :name "Jzon"
        :version (system-version :com.inuoe.jzon)
        :dom "hash-table/vector/string; implementation scalar sentinels"
        :api "stringify(value); parse(string)"
        :stringify (function com.inuoe.jzon:stringify)
        :stringify-input (function identity)
        :parse (function com.inuoe.jzon:parse)
        :object-p (function hash-table-p)
        :object-count (function hash-table-count)
        :object-has-key (function hash-object-has-key)
        :object-value (function hash-object-value)
        :array-p (function vector-array-p)
        :array-count (function length)
        :array-value (function aref)
        :canonical-parse (lambda (text)
                           (canonicalize-hash-vector
                            (com.inuoe.jzon:parse text) jzon-null nil t)))
       (make-adapter
        :name "Jonathan"
        :version (system-version :jonathan)
        :dom "hash-table/list/string; configured scalar/container sentinels"
        :api "to-json(value); parse(string :as :hash-table)"
        :stringify (function jonathan:to-json)
        :stringify-input (function canonical-to-hash-list)
        :parse (lambda (text)
                 (let ((jonathan:*null-value* jonathan-null)
                       (jonathan:*false-value* jonathan-false)
                       (jonathan:*empty-array-value* jonathan-empty-array)
                       (jonathan:*empty-object-value* jonathan-empty-object))
                   (jonathan:parse text :as :hash-table)))
        :object-p (function hash-table-p)
        :object-count (function hash-table-count)
        :object-has-key (function hash-object-has-key)
        :object-value (function hash-object-value)
        :array-p (lambda (value) (or (eq value jonathan-empty-array) (listp value)))
        :array-count (lambda (value) (if (eq value jonathan-empty-array) 0 (length value)))
        :array-value (function list-array-value)
        :canonical-parse (lambda (text)
                           (let ((jonathan:*null-value* jonathan-null)
                                 (jonathan:*false-value* jonathan-false)
                                 (jonathan:*empty-array-value* jonathan-empty-array)
                                 (jonathan:*empty-object-value* jonathan-empty-object))
                             (canonicalize-jonathan
                              (jonathan:parse text :as :hash-table)
                              jonathan-null jonathan-false
                              jonathan-empty-array jonathan-empty-object))))
       (make-adapter
        :name "JSOWN"
        :version (system-version :jsown)
        :dom "(:obj (key . value)...)/list/string; configured sentinels"
        :api "to-json(value); parse(string)"
        :stringify (function jsown:to-json)
        :stringify-input (function canonical-to-jsown)
        :parse (lambda (text)
                 (let ((jsown:*parsed-null-value* jsown-null)
                       (jsown:*parsed-false-value* jsown-false)
                       (jsown:*parsed-empty-list-value* jsown-empty-array))
                   (jsown:parse text)))
        :object-p (function jsown-object-p)
        :object-count (function jsown-object-count)
        :object-has-key (function jsown-object-has-key)
        :object-value (function jsown:val)
        :array-p (lambda (value) (or (eq value jsown-empty-array) (listp value)))
        :array-count (lambda (value) (if (eq value jsown-empty-array) 0 (length value)))
        :array-value (function list-array-value)
        :canonical-parse (lambda (text)
                           (let ((jsown:*parsed-null-value* jsown-null)
                                 (jsown:*parsed-false-value* jsown-false)
                                 (jsown:*parsed-empty-list-value* jsown-empty-array))
                             (canonicalize-jsown
                              (jsown:parse text)
                              jsown-null jsown-false jsown-empty-array))))
       (make-adapter
        :name "Yason"
        :version (system-version :yason)
        :dom "hash-table/vector/string; configured boolean/null sentinels"
        :api "encode(value, stream); parse(string)"
        :stringify (function yason-stringify)
        :stringify-input (function identity)
        :parse (lambda (text)
                 (let ((yason:*parse-json-arrays-as-vectors* t)
                       (yason:*parse-json-booleans-as-symbols* t)
                       (yason:*parse-json-null-as-keyword* t))
                   (yason:parse text)))
        :object-p (function hash-table-p)
        :object-count (function hash-table-count)
        :object-has-key (function hash-object-has-key)
        :object-value (function hash-object-value)
        :array-p (function vector-array-p)
        :array-count (function length)
        :array-value (function aref)
        :canonical-parse (lambda (text)
                           (let ((yason:*parse-json-arrays-as-vectors* t)
                                 (yason:*parse-json-booleans-as-symbols* t)
                                 (yason:*parse-json-null-as-keyword* t))
                             (canonicalize-hash-vector
                              (yason:parse text)
                              :null yason:false yason:true)))))))
  (defun make-canonical-adapters (adapters)
    (mapcar
     (lambda (adapter)
       (let ((canonical-parse (adapter-canonical-parse adapter)))
         (make-adapter
          :name (adapter-name adapter)
          :version (adapter-version adapter)
          :dom "hash-table/vector/string; null=:null false=:false true=t"
          :api (format nil "~A; canonical normalization included in timing"
                       (adapter-api adapter))
          :parse canonical-parse
          :object-p (function hash-table-p)
          :object-count (function hash-table-count)
          :object-has-key (function hash-object-has-key)
          :object-value (function hash-object-value)
          :array-p (function vector-array-p)
          :array-count (function length)
          :array-value (function aref)
          :canonical-parse canonical-parse)))
     adapters)))


(progn
  (defun adapter-member (adapter object key)
    (unless (funcall (adapter-object-has-key adapter) object key)
      (error "~A omitted object member ~S" (adapter-name adapter) key))
    (funcall (adapter-object-value adapter) object key))
  (defun validate-stringify (adapter payload)
    (let* ((input (funcall (adapter-stringify-input adapter) payload))
           (json (funcall (adapter-stringify adapter) input))
           (parsed (json-kit:parse json)))
      (unless (and (stringp json) (stringp parsed) (string= payload parsed))
        (error "~A failed stringify correctness gate" (adapter-name adapter)))))
  (defun validate-array (adapter json count)
    (let ((value (funcall (adapter-parse adapter) json))
          (sum 0))
      (unless (funcall (adapter-array-p adapter) value)
        (error "~A returned the wrong native array root type: ~S"
               (adapter-name adapter) (type-of value)))
      (unless (= (funcall (adapter-array-count adapter) value) count)
        (error "~A returned the wrong array length" (adapter-name adapter)))
      (dotimes (index count)
        (let ((actual (funcall (adapter-array-value adapter) value index)))
          (unless (eql actual index)
            (error "~A returned a wrong array element at ~D"
                   (adapter-name adapter) index))
          (incf sum actual)))
      (unless (= sum (/ (* count (1- count)) 2))
        (error "~A returned the wrong array checksum" (adapter-name adapter)))))
  (defun validate-object (adapter json count)
    (let ((value (funcall (adapter-parse adapter) json)))
      (unless (funcall (adapter-object-p adapter) value)
        (error "~A returned the wrong native object root type: ~S"
               (adapter-name adapter) (type-of value)))
      (unless (= (funcall (adapter-object-count adapter) value) count)
        (error "~A returned the wrong object member count" (adapter-name adapter)))
      (dotimes (index count)
        (let* ((key (format nil "k~D" index))
               (actual (adapter-member adapter value key)))
          (unless (eql actual index)
            (error "~A returned a wrong object member for ~A"
                   (adapter-name adapter) key))))))
  (defun validate-string-parse (adapter json expected)
    (let ((actual (funcall (adapter-parse adapter) json)))
      (unless (and (stringp actual) (string= actual expected))
        (error "~A failed string parse correctness gate" (adapter-name adapter)))))
  (defun all-distinct-by-identity-p (values)
    (loop for tail on values
          always (loop for other in (cdr tail)
                       never (eq (car tail) other))))
  (defun validate-scalar-container-identities (adapter &key canonical)
    (let* ((value
             (funcall (adapter-parse adapter)
                      "{\"n\":null,\"f\":false,\"a\":[],\"o\":{},\"t\":true}")))
      (unless (funcall (adapter-object-p adapter) value)
        (error "~A failed identity gate root object type" (adapter-name adapter)))
      (unless (= (funcall (adapter-object-count adapter) value) 5)
        (error "~A failed identity gate object member count" (adapter-name adapter)))
      (let ((null-value (adapter-member adapter value "n"))
            (false-value (adapter-member adapter value "f"))
            (array-value (adapter-member adapter value "a"))
            (object-value (adapter-member adapter value "o"))
            (true-value (adapter-member adapter value "t")))
        (unless (and (funcall (adapter-array-p adapter) array-value)
                     (zerop (funcall (adapter-array-count adapter) array-value)))
          (error "~A failed empty-array native type/count gate" (adapter-name adapter)))
        (unless (and (funcall (adapter-object-p adapter) object-value)
                     (zerop (funcall (adapter-object-count adapter) object-value)))
          (error "~A failed empty-object native type/count gate" (adapter-name adapter)))
        (unless (all-distinct-by-identity-p
                 (list null-value false-value array-value object-value true-value))
          (error "~A conflated null/false/empty-array/empty-object/true"
                 (adapter-name adapter)))
        (when canonical
          (unless (and (eq null-value :null)
                       (eq false-value :false)
                       (eq true-value t)
                       (hash-table-p object-value)
                       (vector-array-p array-value))
            (error "~A failed canonical scalar/container representation gate"
                   (adapter-name adapter))))))))


(progn)

(progn)

(progn)

(progn
  (defstruct benchmark-case adapter workload mode operation input-bytes thunk)
  (defstruct (benchmark-rng (:constructor make-benchmark-rng (state))) state)
  (defun operation-enabled-p (operation)
    (or (string= *operation-filter* "all")
        (string= *operation-filter* operation)))
  (defun next-benchmark-random (rng limit)
    (setf (benchmark-rng-state rng)
          (ldb (byte 64 0)
               (+ (* (benchmark-rng-state rng) 6364136223846793005)
                  1442695040888963407)))
    (mod (benchmark-rng-state rng) limit))
  (defun shuffled-cases (cases rng)
    (let ((items (coerce cases (quote vector))))
      (loop for index downfrom (1- (length items)) above 0
            for other = (next-benchmark-random rng (1+ index))
            do (rotatef (aref items index) (aref items other)))
      (coerce items (quote list))))
  (defun benchmark-case-id (case)
    (let ((adapter (benchmark-case-adapter case)))
      (format nil "~A|~A|~A|~A"
              (adapter-name adapter)
              (benchmark-case-mode case)
              (benchmark-case-operation case)
              (benchmark-case-workload case))))
  (defun median (numbers)
    (let* ((sorted (sort (copy-list numbers) (function <)))
           (length (length sorted))
           (middle (floor length 2)))
      (if (oddp length)
          (nth middle sorted)
          (/ (+ (nth (1- middle) sorted) (nth middle sorted)) 2d0))))
  (defun standard-deviation (numbers)
    (let* ((count (length numbers))
           (mean (/ (reduce (function +) numbers) count)))
      (sqrt (/ (reduce (function +) numbers
                       :key (lambda (number)
                              (expt (- number mean) 2)))
               count))))
  (defun measure-sample (thunk input-bytes)
    #+sbcl (sb-ext:gc :full t)
    (let* (#+sbcl (start-bytes (sb-ext:get-bytes-consed))
           (start-time (get-internal-real-time)))
      (funcall thunk)
      (let* ((end-time (get-internal-real-time))
             #+sbcl (end-bytes (sb-ext:get-bytes-consed))
             (elapsed-ticks (- end-time start-time))
             (seconds (/ elapsed-ticks
                         (float internal-time-units-per-second 1d0)))
             (throughput (if (plusp seconds)
                             (/ input-bytes seconds 1024d0 1024d0)
                             0d0))
             #+sbcl (consed (- end-bytes start-bytes)))
        (list :elapsed-ticks elapsed-ticks
              :wall-seconds seconds
              :throughput throughput
              :consed-bytes #+sbcl consed #-sbcl 0))))
  (defun summarize-samples (samples)
    (flet ((summary (key)
             (let ((numbers (mapcar (lambda (sample) (getf sample key)) samples)))
               (list (median numbers)
                     (reduce (function min) numbers)
                     (reduce (function max) numbers)
                     (standard-deviation numbers)))))
      (list :wall-seconds (summary :wall-seconds)
            :throughput (summary :throughput)
            :consed-bytes (summary :consed-bytes))))
  (defun make-string-json (payload)
    (with-output-to-string (stream)
      (write-char #\" stream)
      (loop for character across payload
            do (when (or (char= character #\") (char= character #\\))
                 (write-char #\\ stream))
               (write-char character stream))
      (write-char #\" stream)))
  (defun make-benchmark-cases (adapters canonical-adapters ascii quotes-1pct
                               quotes-20pct array-json object-json string-json)
    (let ((cases nil))
      (flet ((add (adapter workload mode operation input thunk)
               (push (make-benchmark-case
                      :adapter adapter
                      :workload workload
                      :mode mode
                      :operation operation
                      :input-bytes (length input)
                      :thunk thunk)
                     cases)))
        (when (operation-enabled-p "stringify")
          (dolist (description (list (list "string/ascii" ascii)
                                     (list "string/quotes-1pct" quotes-1pct)
                                     (list "string/quotes-20pct" quotes-20pct)))
            (dolist (adapter adapters)
              (let ((case-adapter adapter)
                    (payload (second description)))
                (add case-adapter (first description) "native" "stringify" payload
                     (lambda ()
                       (funcall (adapter-stringify case-adapter)
                                (funcall (adapter-stringify-input case-adapter)
                                         payload))))))))
        (when (operation-enabled-p "parse")
          (dolist (description (list (list "array/integer" array-json)
                                     (list "object/integer" object-json)
                                     (list "string/escaped" string-json)))
            (dolist (adapter adapters)
              (let ((case-adapter adapter)
                    (json (second description)))
                (add case-adapter (first description) "native" "parse" json
                     (lambda () (funcall (adapter-parse case-adapter) json)))))
            (dolist (adapter canonical-adapters)
              (let ((case-adapter adapter)
                    (json (second description)))
                (add case-adapter (first description) "canonical" "parse" json
                     (lambda () (funcall (adapter-parse case-adapter) json)))))))
        (nreverse cases))))
  (defun order-record (phase round round-seed ordered-cases)
    (list :phase phase
          :round round
          :seed round-seed
          :case-ids (mapcar (function benchmark-case-id) ordered-cases)))
  (defun warm-cases (cases rng)
    (let ((orders nil))
      (dotimes (round *warmup-count* (nreverse orders))
        (let* ((round-seed (benchmark-rng-state rng))
               (ordered-cases (shuffled-cases cases rng)))
          (push (order-record "warmup" round round-seed ordered-cases) orders)
          (dolist (case ordered-cases)
            (funcall (benchmark-case-thunk case)))))))
  (defun collect-samples (cases rng)
    (let ((samples (make-hash-table :test (function eq)))
          (orders nil)
          (raw-samples nil))
      (dotimes (round *iteration-count*)
        (let* ((round-seed (benchmark-rng-state rng))
               (ordered-cases (shuffled-cases cases rng)))
          (push (order-record "sample" round round-seed ordered-cases) orders)
          (loop for case in ordered-cases
                for order-index from 0
                for sample = (measure-sample (benchmark-case-thunk case)
                                             (benchmark-case-input-bytes case))
                do (push sample (gethash case samples))
                   (push (list :round round
                               :round-seed round-seed
                               :order-index order-index
                               :case case
                               :sample sample)
                         raw-samples))))
      (values samples (nreverse orders) (nreverse raw-samples)))))


(progn
  (defun tsv-field (value)
    (let ((text (princ-to-string (or value "unknown"))))
      (with-output-to-string (stream)
        (loop for character across text
              do (case character
                   (#\Tab (write-string "\\t" stream))
                   (#\Newline (write-string "\\n" stream))
                   (#\Return (write-string "\\r" stream))
                   (#\\ (write-string "\\\\" stream))
                   (t (write-char character stream)))))))
  (defun emit-fields (fields)
    (loop for field in fields
          for first = t then nil
          do (unless first (write-char #\Tab))
             (princ (tsv-field field)))
    (terpri))
  (defun command-output (program arguments)
    (handler-case
        (string-trim
         (list #\Space #\Tab #\Newline #\Return)
         (uiop:run-program (cons program arguments)
                           :output :string
                           :error-output nil))
      (error () "unknown")))
  (defun nonempty-or-unknown (value)
    (if (and (stringp value) (plusp (length value)))
        value
        "unknown"))
  (defun git-value (&rest arguments)
    (nonempty-or-unknown (command-output "git" arguments)))
  (defun git-dirty-state ()
    (let ((status (command-output "git" (list "status" "--porcelain"))))
      (cond
        ((string= status "unknown") "unknown")
        ((zerop (length status)) "clean")
        (t "dirty"))))
  (defun source-sha256 (path)
    (if (probe-file path)
        (let* ((output (command-output "shasum" (list "-a" "256" path)))
               (separator (position #\Space output)))
          (if separator
              (subseq output 0 separator)
              (nonempty-or-unknown output)))
        "unknown"))
  (defun utc-run-time ()
    (multiple-value-bind (second minute hour day month year)
        (decode-universal-time (get-universal-time) 0)
      (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
              year month day hour minute second)))
  (defun flake-nixpkgs-identity ()
    (handler-case
        (let* ((lock (json-kit:parse (uiop:read-file-string "flake.lock")))
               (nodes (gethash "nodes" lock))
               (root-name (gethash "root" lock))
               (root-node (gethash root-name nodes))
               (inputs (gethash "inputs" root-node))
               (nixpkgs-name (gethash "nixpkgs" inputs))
               (node (gethash nixpkgs-name nodes))
               (locked (gethash "locked" node)))
          (format nil "~A;~A;~A;~A"
                  (or (gethash "type" locked) "unknown")
                  (or (gethash "owner" locked) "unknown")
                  (or (gethash "repo" locked) "unknown")
                  (or (gethash "rev" locked)
                      (gethash "narHash" locked)
                      "unknown")))
      (error () "unknown")))
  (defun cpu-model ()
    (let ((model (command-output "sysctl"
                                 (list "-n" "machdep.cpu.brand_string"))))
      (if (or (string= model "unknown") (zerop (length model)))
          (nonempty-or-unknown (machine-version))
          model)))
  (defun benchmark-metadata ()
    (append
     (list
      (list "schema" "cl-json-kit-competitor-benchmark")
      (list "schema_version" "3")
      (list "run_utc" (utc-run-time))
      (list "source_root"
            (handler-case (namestring (truename "."))
              (error () "unknown")))
      (list "git_head" (git-value "rev-parse" "HEAD"))
      (list "git_tree" (git-value "rev-parse" "HEAD^{tree}"))
      (list "git_dirty" (git-dirty-state))
      (list "nixpkgs_lock" (flake-nixpkgs-identity))
      (list "hostname"
            (handler-case (nonempty-or-unknown (machine-instance))
              (error () "unknown")))
      (list "cpu_model" (cpu-model))
      (list "machine_type" (nonempty-or-unknown (machine-type)))
      (list "os" (nonempty-or-unknown (software-type)))
      (list "os_version" (nonempty-or-unknown (software-version)))
      (list "lisp_implementation"
            (nonempty-or-unknown (lisp-implementation-type)))
      (list "lisp_version"
            (nonempty-or-unknown (lisp-implementation-version)))
      (list "seed" *seed*)
      (list "operations" *operation-filter*)
      (list "warmup_rounds" *warmup-count*)
      (list "sample_rounds" *iteration-count*)
      (list "timer_units_per_second" internal-time-units-per-second)
      (list "allocation_counter"
            #+sbcl "sb-ext:get-bytes-consed"
            #-sbcl "unsupported"))
     (mapcar
      (lambda (path)
        (list (format nil "sha256:~A" path)
              (source-sha256 path)))
      (list "cl-json-kit.asd"
            "src/package.lisp"
            "src/data.lisp"
            "src/reader-macros.lisp"
            "src/writer-macros.lisp"
            "src/conditions.lisp"
            "src/parser-state.lisp"
            "src/reader-strings.lisp"
            "src/reader-numbers.lisp"
            "src/reader-collections.lisp"
            "src/reader.lisp"
            "src/reader-stream.lisp"
            "src/writer-state.lisp"
            "src/writer-scalars.lisp"
            "src/writer-collections.lisp"
            "src/writer.lisp"
            "src/conversion.lisp"
            "benchmark/competitors.lisp"
            "benchmark/run.lisp"
            "benchmark/README.md"
            "flake.nix"
            "flake.lock"))))
  (defun emit-order-row (order)
    (emit-fields
     (list "order"
           (getf order :phase)
           (getf order :round)
           (getf order :seed)
           (length (getf order :case-ids))
           (format nil "~{~A~^,~}" (getf order :case-ids)))))
  (defun emit-result-row (case samples)
    (let* ((adapter (benchmark-case-adapter case))
           (summary (summarize-samples samples))
           (wall (getf summary :wall-seconds))
           (throughput (getf summary :throughput))
           (consed (getf summary :consed-bytes)))
      (emit-fields
       (list
        "result"
        (adapter-name adapter)
        (adapter-version adapter)
        (adapter-dom adapter)
        (adapter-api adapter)
        (benchmark-case-mode case)
        (benchmark-case-operation case)
        (benchmark-case-workload case)
        (length samples)
        (benchmark-case-input-bytes case)
        (first wall)
        (second wall)
        (third wall)
        (fourth wall)
        (first throughput)
        (second throughput)
        (third throughput)
        (fourth throughput)
        (first consed)
        (second consed)
        (third consed)
        (fourth consed)))))
  (defun emit-report (cases samples orders raw-samples)
    (emit-fields (list "record" "key" "value"))
    (dolist (metadata (benchmark-metadata))
      (emit-fields (list "meta" (first metadata) (second metadata))))
    (emit-fields
     (list "record" "phase" "round" "round_seed" "case_count" "case_ids"))
    (dolist (order orders)
      (emit-order-row order))
    (emit-fields
     (list "record"
           "phase"
           "round"
           "round_seed"
           "order_index"
           "case_id"
           "library"
           "version"
           "dom"
           "api"
           "mode"
           "operation"
           "workload"
           "input_bytes"
           "elapsed_ticks"
           "wall_seconds"
           "throughput_mib_s"
           "consed_bytes"))
    (dolist (raw-sample raw-samples)
      (let* ((case (getf raw-sample :case))
             (sample (getf raw-sample :sample))
             (adapter (benchmark-case-adapter case)))
        (emit-fields
         (list "sample"
               "sample"
               (getf raw-sample :round)
               (getf raw-sample :round-seed)
               (getf raw-sample :order-index)
               (benchmark-case-id case)
               (adapter-name adapter)
               (adapter-version adapter)
               (adapter-dom adapter)
               (adapter-api adapter)
               (benchmark-case-mode case)
               (benchmark-case-operation case)
               (benchmark-case-workload case)
               (benchmark-case-input-bytes case)
               (getf sample :elapsed-ticks)
               (getf sample :wall-seconds)
               (getf sample :throughput)
               (getf sample :consed-bytes)))))
    (emit-fields
     (list
      "record"
      "library"
      "version"
      "dom"
      "api"
      "mode"
      "operation"
      "workload"
      "samples"
      "input_bytes"
      "wall_seconds_median"
      "wall_seconds_min"
      "wall_seconds_max"
      "wall_seconds_stddev"
      "throughput_mib_s_median"
      "throughput_mib_s_min"
      "throughput_mib_s_max"
      "throughput_mib_s_stddev"
      "consed_bytes_median"
      "consed_bytes_min"
      "consed_bytes_max"
      "consed_bytes_stddev"))
    (dolist (case cases)
      (emit-result-row case (gethash case samples)))))

(defun run ()
  (let* ((adapters (make-adapters))
         (canonical-adapters (make-canonical-adapters adapters))
         (ascii (make-payload (* 1024 1024) nil))
         (quotes-1pct (make-payload (* 1024 1024) 100))
         (quotes-20pct (make-payload (* 1024 1024) 5))
         (array-count 150000)
         (object-count 80000)
         (array-json (make-array-json array-count))
         (object-json (make-object-json object-count))
         (string-value quotes-20pct)
         (string-json (make-string-json string-value)))
    (format
     *error-output*
     "SBCL ~A; operations=~A; seed=~D; adapters=~D~%"
     (lisp-implementation-version)
     *operation-filter*
     *seed*
     (length adapters))
    (when (operation-enabled-p "stringify")
      (dolist (adapter adapters)
        (validate-stringify adapter ascii)
        (validate-stringify adapter quotes-1pct)
        (validate-stringify adapter quotes-20pct)
        (format *error-output* "correct stringify: ~A ~A~%"
                (adapter-name adapter)
                (adapter-version adapter))))
    (when (operation-enabled-p "parse")
      (dolist (adapter adapters)
        (validate-array adapter array-json array-count)
        (validate-object adapter object-json object-count)
        (validate-string-parse adapter string-json string-value)
        (validate-scalar-container-identities adapter)
        (format *error-output* "correct native parse: ~A ~A~%"
                (adapter-name adapter)
                (adapter-version adapter)))
      (dolist (adapter canonical-adapters)
        (validate-array adapter array-json array-count)
        (validate-object adapter object-json object-count)
        (validate-string-parse adapter string-json string-value)
        (validate-scalar-container-identities adapter :canonical t)
        (format *error-output* "correct canonical parse: ~A ~A~%"
                (adapter-name adapter)
                (adapter-version adapter))))
    (let* ((cases
             (make-benchmark-cases
              adapters
              canonical-adapters
              ascii
              quotes-1pct
              quotes-20pct
              array-json
              object-json
              string-json))
           (rng (make-benchmark-rng *seed*))
           (warmup-orders (warm-cases cases rng)))
      (format
       *error-output*
       "cases=~D; samples=~D; warmups=~D; Fisher-Yates every round~%"
       (length cases)
       *iteration-count*
       *warmup-count*)
      (multiple-value-bind (samples sample-orders raw-samples)
          (collect-samples cases rng)
        (emit-report cases
                     samples
                     (append warmup-orders sample-orders)
                     raw-samples)))))

(run)
