;;;; run-tests.lisp
;;;;
;;;; Bootstrap script: point ASDF at this checkout plus the local cl-weave
;;;; checkout, load the test system, and run it.

(require :asdf)

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults (or *load-truename*
                               *compile-file-truename*
                               (error "Unable to determine the script location"))))

(defparameter +cl-weave-directory+
  #P"/Users/take/ghq/github.com/nerima-lisp/cl-weave/")

(defun source-registry-entry (directory)
  (format nil "~A//" (namestring directory)))

(defun configure-local-source-registry (directories)
  (let* ((local-registry (format nil "~{~A~^:~}"
                                  (mapcar #'source-registry-entry directories)))
         (existing-registry (uiop:getenv "CL_SOURCE_REGISTRY"))
         (source-registry (if (and existing-registry (plusp (length existing-registry)))
                               (format nil "~A:~A" local-registry existing-registry)
                               local-registry)))
    (setf (uiop:getenv "CL_SOURCE_REGISTRY") source-registry)
    (asdf:initialize-source-registry)
    source-registry))

(let* ((root (script-directory))
       (directories (list root +cl-weave-directory+)))
  (configure-local-source-registry directories)
  (asdf:load-system "cl-json-kit/test")
  (unless (funcall (symbol-function
                    (find-symbol "RUN-TESTS" "CL-JSON-KIT/TEST")))
    (uiop:quit 1))
  (uiop:quit 0))
