;;;; Reproducible SBCL benchmark harness for cl-json-kit.
(require :asdf)

(require :sb-posix)

(let* ((script (or *load-truename* *compile-file-truename*))
       (default-root
      (uiop:pathname-parent-directory-pathname
        (uiop:pathname-directory-pathname script)))
       (configured-root (uiop:getenv "CL_JSON_KIT_ROOT"))
       (root
      (if configured-root (uiop:ensure-directory-pathname configured-root)
        default-root)))
  (asdf:load-asd (merge-pathnames "cl-json-kit.asd" root))
  (asdf:load-system "cl-json-kit"))

(defpackage #:cl-json-kit/benchmark (:use #:cl)
  (:export #:main))

(in-package #:cl-json-kit/benchmark)

(defconstant +mib+ (* 1024 1024))

(defstruct benchmark name category operation workload input-bytes thunk validator)

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
  (defparameter *operation-filter*
    (environment-choice "BENCH_OPERATIONS" "all"
                        '("all" "parse" "stringify")))
  (defparameter *seed* (environment-integer "BENCH_SEED" 20260724 0)))

(progn
  (defun make-payload (escape-percent)
    (let ((result (make-string +mib+ :initial-element #\a)))
      (when (plusp escape-percent)
        (let ((stride (floor 100 escape-percent)))
          (loop for index from 0 below +mib+ by stride
                do (setf (char result index) #\"))))
      result))
  (defun make-string-json (payload)
    (with-output-to-string (stream)
      (write-char #\" stream)
      (loop for character across payload
            do (when (or (char= character #\")
                         (char= character #\\))
                 (write-char #\\ stream))
               (write-char character stream))
      (write-char #\" stream))))

(defun make-reader-array (count &optional (token "123456789"))
  (with-output-to-string (stream)
    (write-char #\[ stream)
    (loop for index below
          count
          do (when (plusp index)
        (write-char #\, stream)) (write-string token stream))
    (write-char #\] stream)))

(defun make-reader-object (count)
  (with-output-to-string (stream)
    (write-char #\{ stream)
    (loop for index below
          count
          do (when (plusp index)
        (write-char #\, stream)) (format stream "\"key~5,'0D\":123456789" index))
    (write-char #\} stream)))

(defun make-stream-thunk (payload)
  (let ((stream
        (open
          #P"/dev/null"
          :direction
          :output
          :if-exists
          :overwrite
          :external-format
          :utf-8)))
    (values
      (lambda ()
        (json-kit:write-json payload stream)
        (force-output stream))
      stream)))

(progn
  (defun validate-string-value (value expected)
    (unless (and (stringp value) (string= value expected))
      (error "expected the exact source string"))
    t)

  (defun validate-integer-array-value (value expected-count)
    (unless (and (typep value 'simple-vector)
                 (= (length value) expected-count)
                 (every (lambda (element) (eql element 123456789)) value))
      (error "expected a simple vector of ~D copies of 123456789"
             expected-count))
    t)

  (defun validate-float-array-value (value expected-count)
    (unless (and (typep value 'simple-vector)
                 (= (length value) expected-count)
                 (every (lambda (element)
                          (and (typep element 'double-float)
                               (= element 12345.6789d0)))
                        value))
      (error "expected a simple vector of ~D double-float values equal to 12345.6789"
             expected-count))
    t)

  (defun validate-object-value (value expected-count)
    (unless (and (hash-table-p value)
                 (= (hash-table-count value) expected-count)
                 (loop for index below expected-count
                       for key = (format nil "key~5,'0D" index)
                       always
                         (multiple-value-bind (member presentp)
                             (gethash key value)
                           (and presentp (eql member 123456789)))))
      (error "expected a hash table with ~D exact key/value pairs"
             expected-count))
    t)

  (defun validate-benchmarks (benchmarks)
    (dolist (benchmark benchmarks)
      (handler-case
          (let ((validator (benchmark-validator benchmark)))
            (unless validator
              (error "validator is missing"))
            (unless (funcall validator)
              (error "validator returned NIL")))
        (error (condition)
          (error "Benchmark preflight failed for ~A: ~A"
                 (benchmark-name benchmark)
                 condition))))
    t)

  (defun make-benchmarks ()
  (let* ((stringify-enabled
           (member *operation-filter* '("all" "stringify")
                   :test (function string=)))
         (parse-enabled
           (member *operation-filter* '("all" "parse")
                   :test (function string=)))
         (ascii (make-payload 0))
         (escape-1 (make-payload 1))
         (escape-20 (make-payload 20))
         (reader-string (and parse-enabled (make-string-json escape-1)))
         (reader-array (and parse-enabled (make-reader-array 100000)))
         (reader-float-array
           (and parse-enabled (make-reader-array 95325 "12345.6789")))
         (reader-object (and parse-enabled (make-reader-object 50000)))
         (streams nil)
         (benchmarks nil))
    (flet ((add-writer (name payload)
             (let ((stringify-thunk
                     (lambda ()
                       (json-kit:stringify payload))))
               (push
                 (make-benchmark
                   :name (format nil "writer/stringify/~A" name)
                   :category "writer"
                   :operation "stringify"
                   :workload name
                   :input-bytes (length payload)
                   :thunk stringify-thunk
                   :validator
                   (lambda ()
                     (validate-string-value
                       (json-kit:parse (funcall stringify-thunk))
                       payload)))
                 benchmarks))
             (multiple-value-bind (stream-thunk stream)
                 (make-stream-thunk payload)
               (push stream streams)
               (push
                 (make-benchmark
                   :name (format nil "writer/stream/~A" name)
                   :category "writer"
                   :operation "stream"
                   :workload name
                   :input-bytes (length payload)
                   :thunk stream-thunk
                   :validator
                   (lambda ()
                     (validate-string-value
                       (json-kit:parse
                         (with-output-to-string (validation-stream)
                           (json-kit:write-json payload validation-stream)))
                       payload)))
                 benchmarks)))
           (add-reader (name workload input validator)
             (let ((thunk
                     (lambda ()
                       (json-kit:parse input))))
               (push
                 (make-benchmark
                   :name name
                   :category "reader"
                   :operation "parse"
                   :workload workload
                   :input-bytes (length input)
                   :thunk thunk
                   :validator
                   (lambda ()
                     (funcall validator (funcall thunk))))
                 benchmarks))))
      (when stringify-enabled
        (add-writer "ascii-1mib" ascii)
        (add-writer "escape-1pct-1mib" escape-1)
        (add-writer "escape-20pct-1mib" escape-20))
      (when parse-enabled
        (add-reader "reader/string" "string" reader-string
                    (lambda (value)
                      (validate-string-value value escape-1)))
        (add-reader "reader/array" "array" reader-array
                    (lambda (value)
                      (validate-integer-array-value value 100000)))
        (add-reader "reader/float-array" "float-array" reader-float-array
                    (lambda (value)
                      (validate-float-array-value value 95325)))
        (add-reader "reader/object" "object" reader-object
                    (lambda (value)
                      (validate-object-value value 50000))))
      (when parse-enabled
        (let* ((input reader-array)
               (thunk
                 (lambda ()
                   (with-open-stream (stream (make-string-input-stream input))
                     (json-kit:read-json stream)))))
          (push
            (make-benchmark
              :name "reader/read-json-array"
              :category "reader"
              :operation "parse"
              :workload "array/stream"
              :input-bytes (length input)
              :thunk thunk
              :validator
              (lambda ()
                (validate-integer-array-value (funcall thunk) 100000)))
            benchmarks))))
    (values (nreverse benchmarks) streams))))

(defun seconds-since (start end)
  (/ (- end start) (float internal-time-units-per-second 1d0)))

(defun measure-sample (benchmark)
  #+sbcl (sb-ext:gc :full t)
  (let* ((consed-before #+sbcl (sb-ext:get-bytes-consed) #-sbcl 0)
         (started (get-internal-real-time)))
    (funcall (benchmark-thunk benchmark))
    (let* ((ended (get-internal-real-time))
           (consed-after #+sbcl (sb-ext:get-bytes-consed) #-sbcl 0)
           (wall-seconds (seconds-since started ended))
           (throughput (if (plusp wall-seconds)
                           (/ (benchmark-input-bytes benchmark) +mib+ wall-seconds)
                           0d0)))
      (list :wall-seconds wall-seconds
            :throughput throughput
            :consed-bytes (- consed-after consed-before)))))

(progn
  (defstruct (benchmark-rng (:constructor make-benchmark-rng (state))) state)
  (defparameter *benchmark-rng* (make-benchmark-rng *seed*))
  (defparameter *order-records* nil)
  (defun benchmark-random (rng limit)
    (setf (benchmark-rng-state rng)
          (mod (+ (* (benchmark-rng-state rng) 6364136223846793005)
                  1442695040888963407)
               (ash 1 64)))
    (mod (benchmark-rng-state rng) limit))
  (defun shuffled-benchmarks (benchmarks)
    (let ((items (coerce benchmarks 'vector)))
      (loop for index downfrom (1- (length items)) above 0
            for other = (benchmark-random *benchmark-rng* (1+ index))
            do (rotatef (aref items index) (aref items other)))
      (coerce items 'list)))
  (defun round-benchmarks (phase round benchmarks)
    (let ((round-seed (benchmark-rng-state *benchmark-rng*))
          (order (shuffled-benchmarks benchmarks)))
      (push (list :phase phase
                  :round round
                  :seed round-seed
                  :case-ids (mapcar (function benchmark-name) order))
            *order-records*)
      order))
  (defun median (numbers)
    (let* ((sorted (sort (copy-list numbers) (function <)))
           (length (length sorted))
           (middle (floor length 2)))
      (if (oddp length)
          (nth middle sorted)
          (/ (+ (nth (1- middle) sorted) (nth middle sorted)) 2d0))))
  (defun summarize-samples (samples)
    (flet ((values-for (key)
             (mapcar (lambda (sample) (getf sample key)) samples)))
      (let ((wall (values-for :wall-seconds))
            (throughput (values-for :throughput))
            (consed (values-for :consed-bytes)))
        (list :wall-seconds (median wall)
              :wall-seconds-min (reduce (function min) wall)
              :wall-seconds-max (reduce (function max) wall)
              :throughput (median throughput)
              :throughput-min (reduce (function min) throughput)
              :throughput-max (reduce (function max) throughput)
              :consed-bytes (median consed)
              :consed-bytes-min (reduce (function min) consed)
              :consed-bytes-max (reduce (function max) consed)))))
  (defun warm-benchmarks (benchmarks warmup)
    (dotimes (round warmup)
      (dolist (benchmark (round-benchmarks "warmup" round benchmarks))
        (funcall (benchmark-thunk benchmark)))))
  (defun collect-samples (benchmarks sample-count)
    (let ((samples (make-hash-table :test (function eq))))
      (dotimes (round sample-count)
        (dolist (benchmark (round-benchmarks "sample" round benchmarks))
          (push (measure-sample benchmark) (gethash benchmark samples))))
      samples)))

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
  (defun process-wait-with-timeout (process timeout-seconds)
    "Poll PROCESS until it exits or TIMEOUT-SECONDS elapses, without blocking
past the deadline the way SB-EXT:PROCESS-WAIT alone would (it has no timeout
parameter at all -- confirmed empirically, not assumed). Returns T if the
process exited in time, NIL if the deadline was hit."
    (let ((deadline (+ (get-internal-real-time)
                        (* timeout-seconds internal-time-units-per-second))))
      (loop
        (unless (sb-ext:process-alive-p process) (return t))
        (when (> (get-internal-real-time) deadline) (return nil))
        (sleep 0.05))))

  (defun command-output (program arguments &key (timeout-seconds 5))
    "Run PROGRAM with ARGUMENTS and return its trimmed stdout, or \"unknown\" on
any failure or timeout. A process that outlives TIMEOUT-SECONDS is escalated
SIGTERM then SIGKILL against its whole process group, so a hung child (or one
that forks its own children) cannot stall this script indefinitely."
    (handler-case
        (let ((process (sb-ext:run-program program arguments
                                            :output :stream
                                            :error :output
                                            :search t
                                            :wait nil)))
          (unless (process-wait-with-timeout process timeout-seconds)
            (sb-ext:process-kill process sb-posix:sigterm :process-group)
            (unless (process-wait-with-timeout process 2)
              (sb-ext:process-kill process sb-posix:sigkill :process-group)))
          (sb-ext:process-wait process)
          (let ((output (sb-ext:process-output process)))
            (string-trim
             (list #\Space #\Tab #\Newline #\Return)
             (if output (uiop:slurp-stream-string output) ""))))
      (error () "unknown")))
  (defun nonempty-or-unknown (value)
    (if (and (stringp value) (plusp (length value)))
        value
        "unknown"))
  (defun benchmark-source-root ()
    (handler-case
        (truename
         (uiop:ensure-directory-pathname
          (or (uiop:getenv "CL_JSON_KIT_ROOT")
              (uiop:pathname-parent-directory-pathname
               (uiop:pathname-directory-pathname
                (or *load-truename* *compile-file-truename*))))))
      (error () nil)))
  (defun git-value (root &rest arguments)
    (if root
        (nonempty-or-unknown
         (command-output
          "git"
          (append (list "-C" (namestring root)) arguments)))
        "unknown"))
  (defun git-dirty-state (root)
    (if (null root)
        "unknown"
        (let ((status
                (command-output
                 "git"
                 (list "-C" (namestring root)
                       "status" "--porcelain" "--untracked-files=no"))))
          (cond
            ((string= status "unknown") "unknown")
            ((zerop (length status)) "clean")
            (t "dirty")))))
  (defun source-sha256 (root relative-path)
    (handler-case
        (if root
            (let ((path (merge-pathnames relative-path root)))
              (if (probe-file path)
                  (let* ((output
                           (command-output
                            "shasum"
                            (list "-a" "256" (namestring path))))
                         (separator (position #\Space output)))
                    (if separator
                        (subseq output 0 separator)
                        (nonempty-or-unknown output)))
                  "unknown"))
            "unknown")
      (error () "unknown")))
  (defun utc-run-time ()
    (multiple-value-bind (second minute hour day month year)
        (decode-universal-time (get-universal-time) 0)
      (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
              year month day hour minute second)))
  (defun flake-nixpkgs-identity (root)
    (if (null root)
        "unknown"
        (handler-case
            (let* ((lock
                     (json-kit:parse
                      (uiop:read-file-string
                       (merge-pathnames "flake.lock" root))))
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
          (error () "unknown"))))
  (defun cpu-model ()
    (let ((model
            (command-output
             "sysctl"
             (list "-n" "machdep.cpu.brand_string"))))
      (if (or (string= model "unknown") (zerop (length model)))
          (handler-case
              (nonempty-or-unknown (machine-version))
            (error () "unknown"))
          model)))
  (defun benchmark-metadata (sample-count warmup)
    (let ((root (benchmark-source-root)))
      (list
       (list "schema" "cl-json-kit-benchmark")
       (list "schema_version" "2")
       (list "run_utc" (utc-run-time))
       (list "source_root" (if root (namestring root) "unknown"))
       (list "git_head" (git-value root "rev-parse" "HEAD"))
       (list "git_tree" (git-value root "rev-parse" "HEAD^{tree}"))
       (list "git_dirty" (git-dirty-state root))
       (list "nixpkgs_lock" (flake-nixpkgs-identity root))
       (list "hostname"
             (handler-case
                 (nonempty-or-unknown (machine-instance))
               (error () "unknown")))
       (list "cpu" (cpu-model))
       (list "machine"
             (handler-case
                 (nonempty-or-unknown (machine-type))
               (error () "unknown")))
       (list "os"
             (handler-case
                 (nonempty-or-unknown (software-type))
               (error () "unknown")))
       (list "os_version"
             (handler-case
                 (nonempty-or-unknown (software-version))
               (error () "unknown")))
       (list "lisp_implementation"
             (handler-case
                 (nonempty-or-unknown (lisp-implementation-type))
               (error () "unknown")))
       (list "lisp_version"
             (handler-case
                 (nonempty-or-unknown (lisp-implementation-version))
               (error () "unknown")))
       (list "seed" *seed*)
       (list "operations" *operation-filter*)
       (list "warmup_rounds" warmup)
       (list "sample_rounds" sample-count)
       (list "timer"
             (format nil "get-internal-real-time;units-per-second=~D"
                     internal-time-units-per-second))
       (list "allocation_counter"
             #+sbcl "sb-ext:get-bytes-consed"
             #-sbcl "unsupported")
       (list "hash_benchmark_run"
             (source-sha256 root "benchmark/run.lisp"))
       (list "hash_benchmark_competitors"
             (source-sha256 root "benchmark/competitors.lisp"))
       (list "hash_benchmark_readme"
             (source-sha256 root "benchmark/README.md"))
       (list "hash_flake_nix"
             (source-sha256 root "flake.nix"))
       (list "hash_flake_lock"
             (source-sha256 root "flake.lock")))))
  (defun print-tsv-header (sample-count warmup)
    (emit-fields (list "record" "key" "value"))
    (dolist (metadata (benchmark-metadata sample-count warmup))
      (emit-fields (list "meta" (first metadata) (second metadata))))
    (emit-fields
     (list "record" "phase" "round" "round_seed" "case_count" "case_ids"))
    (dolist (order (nreverse *order-records*))
      (emit-fields
       (list "order"
             (getf order :phase)
             (getf order :round)
             (getf order :seed)
             (length (getf order :case-ids))
             (format nil "~{~A~^,~}" (getf order :case-ids)))))
    (emit-fields
     (list "record"
           "name"
           "category"
           "operation"
           "workload"
           "samples"
           "input_bytes"
           "wall_seconds_median"
           "wall_seconds_min"
           "wall_seconds_max"
           "throughput_mib_s_median"
           "throughput_mib_s_min"
           "throughput_mib_s_max"
           "consed_bytes_median"
           "consed_bytes_min"
           "consed_bytes_max"))))

(defun print-result (benchmark sample-count result)
  (format t "result~C~A~C~A~C~A~C~A~C~D~C~D~C~,6F~C~,6F~C~,6F~C~,3F~C~,3F~C~,3F~C~D~C~D~C~D~%"
          #\Tab (benchmark-name benchmark) #\Tab
          (benchmark-category benchmark) #\Tab
          (benchmark-operation benchmark) #\Tab
          (benchmark-workload benchmark) #\Tab
          sample-count #\Tab
          (benchmark-input-bytes benchmark) #\Tab
          (getf result :wall-seconds) #\Tab
          (getf result :wall-seconds-min) #\Tab
          (getf result :wall-seconds-max) #\Tab
          (getf result :throughput) #\Tab
          (getf result :throughput-min) #\Tab
          (getf result :throughput-max) #\Tab
          (round (getf result :consed-bytes)) #\Tab
          (getf result :consed-bytes-min) #\Tab
          (getf result :consed-bytes-max))
  (format *error-output*
          "~35A median ~10,4F s [~,4F, ~,4F]  ~10,2F MiB/s~%"
          (benchmark-name benchmark)
          (getf result :wall-seconds)
          (getf result :wall-seconds-min)
          (getf result :wall-seconds-max)
          (getf result :throughput)))

(defun main ()
  (let ((sample-count (environment-integer "BENCH_ITERATIONS" 5 1))
        (warmup (environment-integer "BENCH_WARMUP" 2 0)))
    (setf *benchmark-rng* (make-benchmark-rng *seed*)
          *order-records* nil)
    (format *error-output*
            "cl-json-kit benchmark: SBCL ~A; operations=~A; seed=~D; samples=~D; warmup=~D; Fisher-Yates every round~%"
            (lisp-implementation-version)
            *operation-filter*
            *seed*
            sample-count
            warmup)
    (multiple-value-bind (benchmarks streams) (make-benchmarks)
      (unwind-protect
           (progn
             (validate-benchmarks benchmarks)
             (warm-benchmarks benchmarks warmup)
             (let ((samples (collect-samples benchmarks sample-count)))
               (print-tsv-header sample-count warmup)
               (dolist (benchmark benchmarks)
                 (print-result benchmark sample-count
                               (summarize-samples
                                 (gethash benchmark samples))))))
        (dolist (stream streams)
          (close stream))))))

(main)
