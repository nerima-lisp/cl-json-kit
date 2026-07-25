;;;; src/writer.lisp
;;;;
;;;; The public writing API: WRITE-JSON to a stream and STRINGIFY to a string.
;;;; Both establish the writer's dynamic configuration, validate options, and
;;;; delegate the actual traversal to WRITE-JSON-VALUE.
(in-package #:json-kit)

(defun resolve-json-output-stream (designator)
  "Resolve a stream DESIGNATOR (NIL, T, or a stream) to an open character
output stream, signalling a serialization error otherwise."
  (let ((stream
          (cond
            ((null designator) *standard-output*)
            ((eq designator t) *terminal-io*)
            ((streamp designator) designator)
            (t (error 'json-serialization-error
                      :message "STREAM must be an output stream designator")))))
    (unless (open-stream-p stream)
      (error 'json-serialization-error :message "STREAM must designate an open stream"))
    (unless (output-stream-p stream)
      (error 'json-serialization-error :message "STREAM must designate an output stream"))
    (multiple-value-bind (character-stream-p certain-p)
        (subtypep (stream-element-type stream) 'character)
      (unless (and certain-p character-stream-p)
        (error 'json-serialization-error
               :message "STREAM must designate a character output stream")))
    stream))

(defun write-json (value stream
                   &key pretty (indent 2) sort-keys
                     (null-value +json-null+) (false-value +json-false+) number-encoder
                     (max-depth +default-maximum-serialization-depth+)
                     (max-elements +default-maximum-serialization-elements+)
                     (max-output-length +default-maximum-output-length+))
  "Serialize VALUE as JSON to STREAM and return VALUE."
  (let ((*json-output-stream* (resolve-json-output-stream stream))
        (*json-output-count* 0)
        (*json-maximum-output-length* max-output-length)
        (*json-maximum-depth* max-depth)
        (*json-maximum-elements* max-elements)
        (*json-pretty* pretty)
        (*json-indent* indent)
        (*json-sort-keys* sort-keys)
        (*json-null-value* null-value)
        (*json-false-value* false-value)
        (*json-number-encoder* (resolve-number-encoder number-encoder))
        (*json-active-aggregates* nil)
        (*json-serialization-path* nil))
    (validate-writer-options indent max-depth max-elements max-output-length)
    (write-json-value value 0)
    value))

(defun stringify (value
                  &rest arguments
                  &key pretty indent sort-keys null-value false-value number-encoder
                    max-depth max-elements max-output-length
                  &allow-other-keys)
  "Serialize VALUE as JSON and return it as a fresh string.  Accepts every
WRITE-JSON keyword."
  (declare (ignore pretty indent sort-keys null-value false-value number-encoder
                   max-depth max-elements max-output-length))
  (with-output-to-string (stream)
    (apply #'write-json value stream arguments)))
