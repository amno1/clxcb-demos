;;; options.lisp — per-run demo options and a small command-line front end.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; A demo's options are slots of its application class, declared with
;;; ordinary slot options, and named by their initargs in its DEFINE-DEMO
;;; form:
;;;
;;;     (xd:define-demo :xclock (:undecorated-window
;;;                              :app clock-widget
;;;                              :options (:width :background ...))
;;;       (run-xclock d conn))
;;;
;;;     (defclass clock-widget (xd:application)
;;;       ((bg-opt :initarg :background :initform nil
;;;                :type (or null string integer)
;;;                :documentation "Background colour.")
;;;        ...)
;;;       (:default-initargs :width 164 :height 164))
;;;
;;; The body makes the application with XD:MAKE-APPLICATION, which passes
;;; the options' values for this run as initargs.
;;;
;;; A caller sets them before a run, from the REPL,
;;;
;;;     (demo6:run :width 300 :background "MidnightBlue")
;;;
;;; or from a shell, through MAIN and PARSE-DEMO-OPTIONS:
;;;
;;;     sbcl ... --eval '(xd:main :xclock)' --end-toplevel-options -- --width 300
;;;
;;; or from the user's X resources, as for any Xt program:
;;;
;;;     echo 'XClock.background: MidnightBlue' | xrdb -merge
;;;
;;; An option's value is, in order: what the caller set for this run,
;;; else the user's resources (read by CALL-WITH-CONTEXT through clXrm),
;;; else the declared default.
;;;
;;; Options apply to one run.  The table is cleared when the run ends
;;; (see START), so a later run without options gets the defaults back
;;; instead of whatever the previous caller asked for.
;;;
;;; Types are checks, not coercions: (SETF DEMO-OPTION) rejects a value
;;; of the wrong type and never converts it.  Converting strings is the
;;; command-line parser's job and nobody else's.

(in-package #:xcb-demos)

;;; Specs and values

(defun %option-spec (demo key)
  (let ((spec (getf (demo-option-specs demo) key :missing)))
    (when (eq spec :missing)
      (error "~A has no option ~S.  Its options are: ~{~S~^ ~}"
             (demo-name demo) key (demo-option-keys demo)))
    spec))

(defun demo-option-keys (demo)
  "Return the keywords of DEMO's declared options, in declaration order."
  (loop for (key) on (demo-option-specs demo) by #'cddr collect key))

(defun demo-option-default (demo key)
  "Return the declared default of DEMO's option KEY, evaluating its
   DEFAULT form now."
  (funcall (getf (%option-spec demo key) :default-function)))

(defun demo-option-resource (demo key)
  "Look option KEY up in DEMO's X resources for this run, converted to
   the option's type.  Returns (VALUES VALUE FOUND-P).  A resource value
   of the wrong type is warned about and ignored (see
   CLXRM/XT:LOOKUP-RESOURCE-VALUE)."
  (let ((spec (%option-spec demo key)))
    (xrm:lookup-resource-value (demo-resource-database demo)
                                     (list (demo-resource-name demo))
                                     (list (demo-resource-class demo))
                                     (getf spec :resource-name)
                                     (getf spec :resource-class)
                                     (getf spec :type))))

(defun demo-option (demo key)
  "Return DEMO's value for option KEY: the value set for this run if
   any, else the user's X resources (e.g. \"XClock.background: navy\"),
   else the option's declared default.  The second value says which:
   :ARGUMENT, :RESOURCE or :DEFAULT.  Signals an error if KEY is not one
   of DEMO's declared options."
  (let* ((spec (%option-spec demo key))
         (xt-option (xrm:make-option
                     key
                     :resource-name (getf spec :resource-name)
                     :resource-class (getf spec :resource-class)
                     :default (demo-option-default demo key)
                     :type (getf spec :type)))
         (plist (multiple-value-bind (value set-p) (gethash key (demo-options demo))
                  (when set-p (list key value)))))
    (xrm:lookup-option (demo-resource-database demo)
                             (list (demo-resource-name demo))
                             (list (demo-resource-class demo))
                             (list xt-option)
                             key
                             plist)))

(defun (setf demo-option) (value demo key)
  "Set DEMO's option KEY to VALUE for its next run.  Signals an error if
   KEY is not a declared option, or if VALUE is not of the option's
   declared type.  The value is stored as given, never converted."
  (let ((type (getf (%option-spec demo key) :type)))
    (when (and type (not (typep value type)))
      (error "Option ~S of ~A expects a value of type ~S, got ~S."
             key (demo-name demo) type value)))
  (setf (gethash key (demo-options demo)) value))

(defun set-demo-options (demo &rest plist)
  "Set several options of DEMO at once, as a series of
   (SETF DEMO-OPTION) calls.  DEMO may be anything FIND-DEMO accepts.
   Returns the demo instance."
  (let ((d (find-demo demo)))
    (unless (evenp (length plist))
      (error "Odd number of option arguments for ~A: ~S" (demo-name d) plist))
    (loop for (k v) on plist by #'cddr
          do (setf (demo-option d k) v))
    d))

(defun demo-option-plist (demo)
  "Return a plist of every declared option of DEMO with its value for
   this run, set or default.  Handy for applying to a function whose
   keyword parameters mirror the options."
  (loop for key in (demo-option-keys demo)
        append (list key (demo-option demo key))))

(defun %doc-summary (doc)
  "DOC's first sentence, on one line: an option's help comes from its
   slot's documentation, which may go on to say more."
  (when doc
    (let* ((words (uiop:split-string doc :separator '(#\Space #\Tab #\Newline)))
           (flat  (format nil "~{~A~^ ~}" (remove "" words :test #'string=)))
           (end   (search ". " flat)))
      (if end (subseq flat 0 (1+ end)) flat))))

(defun demo-option-help (demo)
  "Return a list of strings describing DEMO's options, one per option,
   for a help panel or --help.  DEMO is anything FIND-DEMO accepts."
  (loop with demo = (find-demo demo)
        with *print-pretty* = nil
        for (key spec) on (demo-option-specs demo) by #'cddr
        collect (format nil "  --~(~A~)~@[ ~A~]~@[ (type ~S)~] (default: ~S; resource ~A.~A)"
                        key
                        (%doc-summary (getf spec :documentation))
                        (getf spec :type)
                        (ignore-errors (demo-option-default demo key))
                        (demo-resource-class demo)
                        (getf spec :resource-name))))

(defgeneric normalize-demo-options (demo options)
  (:documentation "Normalize OPTIONS for DEMO before applying them.
   By default returns OPTIONS unchanged."))

(defmethod normalize-demo-options (demo options)
  (declare (ignore demo))
  options)

(defun start-with-options (demo &rest options)
  "Start DEMO for one run with OPTIONS, a plist of its declared options.
   A running instance is stopped first.  Options left out take their
   declared defaults: nothing carries over from an earlier run.
   Returns the demo instance."
  (let* ((d (find-demo demo))
         (normalized (normalize-demo-options d options)))
    (when (demo-running-p d)
      (stop d))
    (clrhash (demo-options d))
    (apply #'set-demo-options d normalized)
    (start d)))

;;; Command line

(defun %boolean-type-p (type)
  (and type (subtypep type 'boolean) (subtypep 'boolean type)))

(defun %convert-option-string (string type)
  "Convert STRING, an option value from the command line, to TYPE, the
   same way an X resource value is converted (see
   CLXRM/XT:CONVERT-RESOURCE-STRING), or signal an error."
  (multiple-value-bind (value ok-p) (xrm:convert-resource-string string type)
    (unless ok-p
      (error "~S is not a valid ~S." string type))
    value))

(defun parse-demo-options (demo strings)
  "Parse STRINGS, a list of command-line arguments, against DEMO's
   option specs, and return a plist for SET-DEMO-OPTIONS.  Option :FOO
   is written --foo VALUE or --foo=VALUE.  Boolean options (declared
   with :TYPE BOOLEAN) are written --foo or --no-foo.  Values are
   converted according to the option's :TYPE (see
   %CONVERT-OPTION-STRING); untyped options keep the string.  Returns
   :HELP instead of a plist when STRINGS contains --help or -h.
   Signals an error for an unknown option or a bad value."
  (let* ((d (find-demo demo))
         (specs (demo-option-specs d))
         (result '())
         ;; A bare "--" separates the Lisp's own arguments from the
         ;; program's, and SBCL passes it through; it carries no option.
         (strings (remove "--" strings :test #'string=)))
    (loop
      (when (null strings) (return))
      (let ((arg (pop strings)))
        (when (member arg '("--help" "-h") :test #'string=)
          (return-from parse-demo-options :help))
        (unless (and (> (length arg) 2) (string= "--" arg :end2 2))
          (error "Unexpected argument ~S; options are written --name value." arg))
        (let* ((eq-pos (position #\= arg))
               (name   (subseq arg 2 eq-pos))
               (inline (and eq-pos (subseq arg (1+ eq-pos))))
               (key    (intern (string-upcase name) :keyword))
               (spec   (getf specs key :missing)))
          (cond
            ;; --no-foo for a boolean foo
            ((and (eq spec :missing)
                  (> (length name) 3)
                  (string-equal "no-" name :end2 3)
                  (let ((bspec (getf specs (intern (string-upcase (subseq name 3)) :keyword))))
                    (and bspec (%boolean-type-p (getf bspec :type)))))
             (when inline
               (error "--~A takes no value." name))
             (setf (getf result (intern (string-upcase (subseq name 3)) :keyword)) nil))
            ((eq spec :missing)
             (error "~A has no option --~A.  Try --help." (demo-name d) name))
            ;; --foo for a boolean foo (or --foo=true/false)
            ((and (%boolean-type-p (getf spec :type)) (null inline))
             (setf (getf result key) t))
            (t
             (let ((value (or inline
                              (if strings
                                  (pop strings)
                                  (error "--~A needs a value." name)))))
               (setf (getf result key)
                     (%convert-option-string value (getf spec :type)))))))))
    result))

(defun main (demo &optional (args (uiop:command-line-arguments)))
  "Command-line entry point: parse ARGS (by default the process's
   command-line arguments) against DEMO's options, start it, and wait
   for it to finish; Ctrl+C stops it.  --help prints the options and returns.  A bad
   option prints a message and the options to *ERROR-OUTPUT* and
   returns NIL; the process's exit status is the caller's business."
  (let* ((d (find-demo demo))
         (plist (handler-case (parse-demo-options d args)
                  (error (e)
                    (format *error-output* "~&~A~%~%Options:~%~{~A~%~}"
                            e (demo-option-help d))
                    (return-from main nil)))))
    (when (eq plist :help)
      (format t "~&Options for ~(~A~):~%~{~A~%~}" (demo-name d) (demo-option-help d))
      (return-from main nil))
    (handler-case (apply #'start-with-options d plist)
      (error (e)
        (format *error-output* "~&~A~%" e)
        (return-from main nil)))
    ;; Ctrl+C in the terminal stops the demo the way XD:STOP does, so it
    ;; cleans up after itself, instead of landing in the debugger (or,
    ;; under --non-interactive, printing a backtrace and quitting).
    (handler-case
        (with-user-abort:with-user-abort
          (when (demo-thread d)
            (bt:join-thread (demo-thread d))))
      (with-user-abort:user-abort ()
        (format *error-output* "~&Interrupted; stopping ~(~A~).~%" (demo-name d))
        (stop d)))
    d))
