;;; framework.lisp — CLOS-based demo framework for CLXCB demos.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; Design, in one paragraph: a DEMO is a CLOS object with a lifecycle
;;; (START, STOP) and a body (DEMO-BODY).  The transport -- how the demo
;;; gets a live connection -- is a mixin (XCB-MIXIN) with one method,
;;; CALL-WITH-CONTEXT.  What the demo shows is its application, an
;;; XD:APPLICATION (see application.lisp): an xact TOPLEVEL whose kind
;;; (:MANAGED, :UNDECORATED, :OVERRIDE-REDIRECT or :ROOT) says how it
;;; deals with the window manager.  The demo instance only knows its
;;; running application, so STOP can ask it to close (XACT:REQUEST-CLOSE):
;;; the request arrives as an event, and the application's own quit
;;; interactor ends the run.
;;;
;;; Adding a new demo means writing a file whose first form is
;;;
;;;     (xd:define-demo :my-demo (:wm-title "My Demo" :app my-app)
;;;       ...body...)
;;;
;;; and whose remaining top-level forms define the application class and
;;; whatever functions the body needs.  DEMO-BODY receives the demo
;;; instance and the live connection; there is no `*conn*` global to
;;; remember, and no boilerplate close-protocol setup to forget.

(in-package #:xcb-demos)


;; Compile-time state
;;
;; DEFINE-DEMO runs at macro-expansion time in the compiling image, and
;; consults these to decide which number a demo gets.  They must exist
;; during compilation, not just at load; hence the EVAL-WHEN.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *demo-numbers*
    (let ((ht (make-hash-table :test 'eq)))
      (loop for (name . num) in '((:quickstart . 1)
                                  (:basic-window . 2)
                                  (:turtle . 3)
                                  (:turtle-viewer . 3)
                                  (:slideshow . 4)
                                  (:xeyes . 5)
                                  (:xclock . 6)
                                  (:xsnow . 7)
                                  (:xroach . 8)
                                  (:xneko . 9)
                                  (:oneko . 9)
                                  (:color-picker . 10)
                                  (:xviewer . 11)
                                  (:image-viewer . 11)
                                  (:thermometer . 12))
            do (setf (gethash name ht) num))
      ht)
    "Map from demo keyword to its assigned number.  Persists for the
     life of the image, so recompiling one demo file does not renumber
     it.")
  (defvar *demo-counter* 12
    "Highest demo number assigned so far."))

(defvar *registry* (make-hash-table :test 'eq)
  "Map from demo keyword to the canonical demo instance.")


;; The demo lifecycle
;;
;; A DEMO is a singleton: one instance per demo, registered under a
;; keyword, retrieved by FIND-DEMO, and dispatched to by all the
;; top-level entry points.  Nothing in the framework requires that,
;; but the demo bodies assume it: their file-locals are shared, and
;; they never instantiate themselves.

(defclass demo ()
  ((name       :initarg :name
               :reader demo-name
               :documentation "Keyword, e.g. :XEYES.")
   (number     :initform nil
               :accessor demo-number
               :documentation "Integer, assigned at registration.")
   (options    :initform (make-hash-table :test 'eq)
               :reader demo-options
               :documentation "Maps option keyword to the value set for the
               next run, by SET-DEMO-OPTIONS or START-WITH-OPTIONS before
               START.  Absent keys fall through to the option's declared
               default.  Options live on the instance, not in dynamic
               bindings, because the demo body runs on its own thread,
               which does not inherit the caller's bindings.  The table is
               cleared when a run ends, so options apply to one run only.
               See options.lisp.")
   (app-class  :initarg :app-class
               :initform nil
               :reader demo-app-class
               :documentation "The name of the demo's application class,
               from DEFINE-DEMO's :APP, or NIL.  Its slots declare the
               demo's options; see DEMO-OPTION-SPECS.")
   (option-keys :initarg :option-keys
               :initform '()
               :documentation "DEFINE-DEMO's :OPTIONS: the initargs of
               the application slots that are options, each a keyword or
               (KEY &key RESOURCE-NAME RESOURCE-CLASS).")
   (option-specs :initform :unbuilt
               :documentation "Cache for DEMO-OPTION-SPECS, built from
               the application class on first use.")
   (resource-name :initarg :resource-name
               :initform nil
               :documentation "The application's X resource name, as in
               \"xclock.background: navy\".  NIL means the demo's name in
               lower case; see DEMO-RESOURCE-NAME.")
   (resource-class :initarg :resource-class
               :initform nil
               :documentation "The application's X resource class, as in
               \"XClock.background: navy\".  NIL means the resource name
               in Xt class style; see DEMO-RESOURCE-CLASS.")
   (resource-database :initform nil
               :accessor demo-resource-database
               :documentation "The user's X resources (clXrm database)
               for the current run: the RESOURCE_MANAGER property xrdb
               loads, or ~/.Xdefaults.  Read by CALL-WITH-CONTEXT on the
               demo thread when the demo declares options, NIL otherwise
               and between runs.  DEMO-OPTION falls back to it.")
   (thread     :initform nil
               :accessor demo-thread
               :documentation "The background thread, or NIL.")
   (application :initform nil
               :accessor demo-application
               :documentation "The running application, made by
               MAKE-APPLICATION, or NIL between runs.  STOP asks it to
               close.  :STOP when STOP came before it was made.")
   (wm-title   :initarg :wm-title
               :initform nil
               :accessor demo-wm-title
               :documentation "Title for the application's window.  If
               NIL, DEMO-NAME is used, capitalised.")
   (wm-class   :initarg :wm-class
               :initform nil
               :accessor demo-wm-class
               :documentation "WM_CLASS instance part.  If NIL, DEMO-NAME
               is used, downcased.")))

;; Options from the application class
;;
;; A demo's options are slots of its application class: the slot's first
;; keyword initarg is the option's key, its initform the default, and
;; its :TYPE and :DOCUMENTATION the option's.  A :DEFAULT-INITARGS entry
;; for the key overrides the initform, which is how a demo gives an
;; inherited option such as APPLICATION's WIDTH a default of its own.
;; DEFINE-DEMO's :OPTIONS names the options by key, and so picks the
;; slots that are options; a slot such as a backing pixmap stays private.
;; The specs are built on first use, not when DEFINE-DEMO is loaded,
;; because the class is defined further down the demo's file.

(defun %direct-slot-property (class slotd reader)
  "The first value READER gives for SLOTD's direct slot definitions,
   most specific class first, skipping NIL and T (no type)."
  (dolist (c (c2mop:class-precedence-list class))
    (let ((dsd (find (c2mop:slot-definition-name slotd) (c2mop:class-direct-slots c)
                     :key #'c2mop:slot-definition-name)))
      (when dsd
        (let ((v (funcall reader dsd)))
          (unless (member v '(nil t))
            (return v)))))))

(defun %app-option-specs (demo)
  (let ((class (find-class (demo-app-class demo))))
    (c2mop:ensure-finalized class)
    (loop for entry in (slot-value demo 'option-keys)
          append
          (destructuring-bind (key &key resource-name resource-class)
              (if (consp entry) entry (list entry))
            (check-type key keyword)
            (let ((esd (find key (c2mop:class-slots class)
                             :test #'member :key #'c2mop:slot-definition-initargs)))
              (unless esd
                (error "~A: no slot of ~S has the initarg ~S for an option."
                       (demo-name demo) (class-name class) key))
              (let* ((initfn (or (third (assoc key (c2mop:class-default-initargs class)))
                                 (c2mop:slot-definition-initfunction esd)))
                     (rname (or resource-name (xrm:resource-name-for key)))
                     (rclass (or resource-class (xrm:resource-class-for rname))))
                (list key
                      (list :default-function (or initfn (constantly nil))
                            :type (%direct-slot-property
                                   class esd #'c2mop:slot-definition-type)
                            :documentation (%direct-slot-property
                                            class esd (lambda (d) (documentation d t)))
                            :resource-name rname
                            :resource-class rclass))))))))

(defun demo-option-specs (demo)
  "Plist of KEY -> spec plist (:DEFAULT-FUNCTION :TYPE :DOCUMENTATION
   :RESOURCE-NAME :RESOURCE-CLASS) for the options DEMO accepts, in
   declaration order, built from its application class.  Empty for a
   demo without one.  DEMO is anything FIND-DEMO accepts."
  (let* ((demo (find-demo demo))
         (cached (slot-value demo 'option-specs)))
    (if (eq cached :unbuilt)
        (setf (slot-value demo 'option-specs)
              (and (demo-app-class demo) (%app-option-specs demo)))
        cached)))

(defun make-application (demo conn &rest initargs)
  "A fresh instance of DEMO's application class on CONN, with INITARGS,
   then its options (DEMO-OPTION-PLIST), its title, and its WM class and
   resource class (WM_CLASS) as initargs.  It becomes DEMO-APPLICATION, which STOP asks to close."
  (let* ((name (demo-name demo))
         (app (apply #'make-instance (demo-app-class demo)
                     :connection conn
                     (append initargs
                             (demo-option-plist demo)
                             (list :title (or (demo-wm-title demo)
                                              (string-capitalize (symbol-name name)))
                                   :wm-class (or (demo-wm-class demo)
                                                 (string-downcase (symbol-name name)))
                                   :resource-class (demo-resource-class demo))))))
    ;; STOP came first: the run ends as soon as its loop starts.
    (when (eq (demo-application demo) :stop)
      (setf (xact:toplevel-closing-p app) t))
    (setf (demo-application demo) app)))

(defun demo-resource-name (demo)
  "The application name DEMO's X resources are looked up under, e.g.
   \"xclock\" or \"xviewer\"."
  (or (slot-value demo 'resource-name)
      (string-downcase (symbol-name (demo-name demo)))))

(defun demo-resource-class (demo)
  "The application class DEMO's X resources are looked up under, e.g.
   \"XClock\" (given by DEFINE-DEMO's :RESOURCE-CLASS) or, by default,
   the resource name in Xt style: \"XViewer\" for xviewer."
  (or (slot-value demo 'resource-class)
      (xrm:resource-class-for
       (xrm:resource-name-for (demo-resource-name demo)))))

(defmethod print-object ((d demo) stream)
  (print-unreadable-object (d stream :type t :identity nil)
    (format stream "~A~@[ #~D~]~:[~; RUNNING~]"
            (demo-name d)
            (demo-number d)
            (demo-running-p d))))

;; Each demo file defines a method on its own concrete demo class.
;; The method receives the instance and the live connection.  Its
;; return value is discarded; the demo is over when it returns.

(defgeneric demo-body (demo conn)
  (:documentation "Run DEMO's body with CONN the live XCB connection.
   Returns when the demo decides to stop, or when the body errors out."))

(defmethod demo-body ((d demo) conn)
  (declare (ignore conn))
  (error "~A does not define a DEMO-BODY method."
         (class-name (class-of d))))

(defgeneric demo-cleanup (demo conn)
  (:documentation "Release any per-run resources DEMO acquired.  Called
   by CALL-WITH-CONTEXT on unwind, before the connection is closed.  The
   default does nothing; mixins that allocate resources add :AFTER
   methods.")
  (:method ((d demo) conn)
    (declare (ignore conn)) nil))

;; "Context" is whatever CALL-WITH-CONTEXT opens and hands to
;; DEMO-BODY.  For XCB demos, that is an XCB connection.  Splitting
;; this into its own generic means a demo could one day be backed by
;; something else (a fake connection for tests, a pooled connection
;; for a demo that reconnects) without touching DEMO-BODY or the
;; lifecycle code.

(defgeneric call-with-context (demo thunk)
  (:documentation "Open DEMO's transport context and call THUNK on it.
   THUNK takes one argument, the context, and its return value is
   discarded.  Whatever cleanup is needed must happen on unwind."))

(defgeneric demo-running-p (demo)
  (:documentation "True while DEMO's body is running on its thread."))

(defmethod demo-running-p ((d demo))
  (let ((thread (demo-thread d)))
    (and thread (bt:thread-alive-p thread) t)))

(defgeneric start (demo)
  (:documentation
   "Start DEMO on a background thread and return the demo instance."))

(defgeneric stop (demo &key timeout)
  (:documentation "Ask DEMO to stop and wait up to TIMEOUT seconds for it."))

(defmethod start ((d demo))
  "Start DEMO on a background thread and return the demo instance.
   If DEMO is already running, it is stopped first, so a second START
   is not an error but a restart."
  (when (demo-running-p d)
    (stop d))
  (setf (demo-application d) nil
        (demo-thread d)
        (bt:make-thread
         (lambda ()
           (unwind-protect
                (call-with-context
                 d
                 (lambda (context)
                   (demo-body d context)))
             ;; Options apply to one run: the next START without new
             ;; options gets the declared defaults again.
             (clrhash (demo-options d))
             (setf (demo-application d) nil)))
         :name (string (demo-name d))))
  d)

(defmethod start ((name symbol))
  (start (find-demo name)))

(defmethod start ((number integer))
  (start (find-demo number)))

(defmethod stop ((d demo) &key (timeout 5))
  "Ask DEMO to stop and wait up to TIMEOUT seconds for it.

   The request is an event: XACT:REQUEST-CLOSE on the running
   application, whose loop then ends as if its window had been closed.
   Returns T when the thread exited cleanly, :TIMED-OUT when the join
   timed out, or NIL if DEMO was not running."
  (let ((thread (demo-thread d)))
    (unless (and thread (bt:thread-alive-p thread))
      (setf (demo-thread d) nil)
      (return-from stop nil))
    (let ((app (demo-application d)))
      (if (typep app 'xact:toplevel)
          (xact:request-close app :display (or (demo-display d) (uiop:getenv "DISPLAY")))
          (setf (demo-application d) :stop)))
    (if (null timeout)
        (progn
          (ignore-errors (bt:join-thread thread))
          (setf (demo-thread d) nil)
          t)
        (let ((deadline (+ (get-internal-real-time)
                           (* timeout internal-time-units-per-second))))
          (loop
            (cond
              ((not (bt:thread-alive-p thread))
               (ignore-errors (bt:join-thread thread))
               (setf (demo-thread d) nil)
               (return t))
              ((> (get-internal-real-time) deadline)
               (setf (demo-thread d) nil)
               (format *error-output*
                       "~&Warning: ~A did not exit within ~Ds.~%"
                       (demo-name d) timeout)
               (return :timed-out))
              (t
               (sleep 0.02))))))))

(defmethod stop ((name symbol) &key (timeout 5))
  (stop (find-demo name) :timeout timeout))

(defmethod stop ((number integer) &key (timeout 5))
  (stop (find-demo number) :timeout timeout))


;; Transport mixins
;;
;; X11-MIXIN is the X-specific transport-independent part: it names
;; the display the demo should connect to.  A hypothetical CLX-backed
;; demo would mix in X11-MIXIN too, and provide its own
;; CALL-WITH-CONTEXT.
;;
;; XCB-MIXIN is the XCB-backed transport: a function-shaped
;; CALL-WITH-CONTEXT that opens an XCB connection for the lifetime of
;; the body, and closes it on unwind.

(defclass x11-mixin ()
  ((display :initarg :display
            :initform nil
            :accessor demo-display
            :documentation "The DISPLAY string to connect to, or NIL
            to use $DISPLAY.")))

(defclass xcb-mixin (x11-mixin) ())

(defmethod call-with-context ((d xcb-mixin) thunk)
  (xcb:call-with-x-connection
   (lambda (conn)
     ;; The user's X resources, read once per run on the demo thread, and
     ;; only by demos that have options to look up in them.  A failure
     ;; here must not stop the demo: it just runs on defaults.
     (when (demo-option-specs d)
       (setf (demo-resource-database d)
             (handler-case (xrm:default-resources conn)
               (error (e)
                 (warn "~A: could not read X resources: ~A" (demo-name d) e)
                 nil))))
     (unwind-protect
          (funcall thunk conn)
       (demo-cleanup d conn)
       (setf (demo-resource-database d) nil)))
   :display (or (demo-display d) (uiop:getenv "DISPLAY"))))


;; The demo base class

(defclass xcb-demo (demo xcb-mixin) ())


;; Registry

(defun %demo-number (name)
  "Return the demo number for NAME, allocating one the first time NAME
   is seen.  If a package for this demo already exists in the image,
   its DEMO<N> nickname is the authoritative source; this makes a
   recompile of one demo file preserve the number the previous compile
   assigned."
  (or (gethash name *demo-numbers*)
      (let ((existing (find-package
                       (format nil "XCB-DEMOS.~A"
                               (symbol-name name)))))
        (when existing
          (dolist (nick (package-nicknames existing))
            (when (and (> (length nick) 4)
                       (string-equal nick "DEMO" :end1 4 :end2 4)
                       (every #'digit-char-p (subseq nick 4)))
              (let ((n (parse-integer nick :start 4)))
                (setf (gethash name *demo-numbers*) n)
                (return-from %demo-number n))))))
      (setf (gethash name *demo-numbers*) (incf *demo-counter*))))

(defun register-demo (name instance)
  "Register INSTANCE as the canonical demo for NAME.  If NAME was
   already registered, INSTANCE inherits its number; otherwise it is
   assigned a new one.  Returns INSTANCE."
  (let ((existing (gethash name *registry*)))
    (setf (demo-number instance)
          (if existing
              (demo-number existing)
              (%demo-number name))
          (gethash name *registry*) instance)
    (case name
      (:xviewer       (setf (gethash :image-viewer *registry*) instance))
      (:image-viewer  (setf (gethash :xviewer *registry*) instance))
      (:turtle        (setf (gethash :turtle-viewer *registry*) instance))
      (:turtle-viewer (setf (gethash :turtle *registry*) instance))
      (:xneko         (setf (gethash :oneko *registry*) instance))
      (:oneko         (setf (gethash :xneko *registry*) instance)))
    instance))

(defun find-demo (name)
  "Return the canonical demo instance for NAME.  NAME may be a demo
   instance (returned unchanged), an integer (demo number), a keyword
   (looked up in the registry), or any other symbol (its name is used,
   or resolved as DEMO<N>)."
  (etypecase name
    (demo name)
    (integer
     (or (loop for d being the hash-values of *registry*
               when (eql (demo-number d) name)
                 return d)
         (error "No demo numbered ~D" name)))
    (symbol
     (let ((key (intern (symbol-name name) :keyword)))
       (or (gethash key *registry*)
           (let* ((str (symbol-name name))
                  (num (when (and (> (length str) 4)
                                  (string-equal str "DEMO" :end1 4 :end2 4)
                                  (every #'digit-char-p (subseq str 4)))
                         (parse-integer str :start 4))))
             (and num (find-demo num)))
           (error "No demo registered under ~S" name))))))

(defun list-demos ()
  "Return all registered demos, sorted by demo number."
  (sort (delete-duplicates
         (loop for d being the hash-values of *registry* collect d))
        #'< :key #'demo-number))


;; DEFINE-DEMO Macro
;;
;; The macro's job is to create the per-demo package
;; (which is what gives the demo file its own namespace for
;; file-locals), define the concrete demo class, define the DEMO-BODY
;; method, and register an instance.  All the interesting work is in
;; the methods and mixins above.

;; Recursively walk FORM, replacing any symbol whose home package is in
;; FROM-PKGS with a symbol of the same name interned in TO-PKG.
;; Preserves package qualifiers for symbols from other packages (such as
;; COMMON-LISP, XCB, or KEYWORD).
(defun %rehome-symbols (form from-pkgs to-pkg)
  (cond
    ((symbolp form)
     (let ((pkg (symbol-package form)))
       (if (and pkg (member pkg from-pkgs))
           (multiple-value-bind (existing status)
               (find-symbol (symbol-name form) to-pkg)
             (declare (ignorable status))
             (if existing
                 ;; Already accessible -- interned directly or inherited
                 ;; from a used package.  Reuse it either way; this is
                 ;; what makes DEFPACKAGE's later USE-PACKAGE a no-op for
                 ;; this name instead of a conflict.
                 existing
                 (intern (symbol-name form) to-pkg)))
           form)))
    ((consp form)
     (cons (%rehome-symbols (car form) from-pkgs to-pkg)
           (%rehome-symbols (cdr form) from-pkgs to-pkg)))
    (t form)))

(defun %collect-earmuff-symbols (form target-pkg)
  "Return a list of unique symbols in FORM whose names start and end with *
   and whose home package is TARGET-PKG."
  (let ((result nil))
    (labels ((walk (x)
               (cond
                 ((symbolp x)
                  (let ((name (symbol-name x)))
                    (when (and (> (length name) 1)
                               (char= (char name 0) #\*)
                               (char= (char name (1- (length name))) #\*)
                               (eq (symbol-package x) target-pkg))
                      (pushnew x result))))
                 ((consp x)
                  (walk (car x))
                  (walk (cdr x))))))
      (walk form))
    (nreverse result)))

(defmacro define-demo (name (&rest initargs) &body body)
  "Define a demo called NAME (a keyword).

   INITARGS are initargs for the demo instance; the useful ones are
   :WM-TITLE and :WM-CLASS (the title and WM_CLASS MAKE-APPLICATION gives
   the application's window), :RESOURCE-NAME, :RESOURCE-CLASS and
   :DISPLAY.  How the window deals with the window manager is the
   application class's business: its :KIND (see XACT:TOPLEVEL).

   :MIXINS is special: it is a list of additional superclasses for the
   demo's class, not an initarg.  Each entry must be a symbol in a
   package that already exists when the form is read — in practice,
   write it fully qualified, XD:SOME-MIXIN rather than SOME-MIXIN,
   because the demo's own package does not exist
   until this form creates it.

   :APP and :OPTIONS are special too.  :APP names the demo's
   application class, which the body instantiates with
   (XD:MAKE-APPLICATION D CONN ...).  :OPTIONS lists the per-run
   options, by the initargs of the slots of that class that hold them,
   each a keyword or

       (KEY &key RESOURCE-NAME RESOURCE-CLASS)

   An option is declared with ordinary slot options:

       (width :initarg :width :initform 164 :type (integer 1)
              :documentation \"window width in pixels\")

   The option's key is the slot's initarg.  The initform is its
   default, evaluated each time the option is read without a value
   having been set.  :TYPE, if given, is checked by (SETF DEMO-OPTION);
   it also tells the command-line parser how to convert a string (see
   PARSE-DEMO-OPTIONS).  The body reads options with (DEMO-OPTION D
   KEY), or all of them as a plist with (DEMO-OPTION-PLIST D), which is
   what MAKE-APPLICATION passes as initargs.

   An option not given by the caller is looked up in the user's X
   resources before its default is used, as an Xt program does: with
   \"XClock.background: navy\" loaded by xrdb, xclock's :BACKGROUND is
   \"navy\".  RESOURCE-NAME defaults to the key in Xt style (:FONT-SIZE
   is fontSize), RESOURCE-CLASS to its class (FontSize).  The
   application's own name and class are the :RESOURCE-NAME and
   :RESOURCE-CLASS initargs (default: the demo's name, e.g. xclock, and
   its class-style form, e.g. Xclock).

   BODY is the demo body, run on a background thread by START.  It has
   two variables in scope: D, the demo instance, and CONN, the live
   XCB connection.

   The demo's package exports RUN, shorthand for
   (XD:START-WITH-OPTIONS NAME ...), START, the same as RUN, and STOP and
   MAIN, shorthands for XD:STOP and XD:MAIN on this demo.

   This form must be the first toplevel form of the demo's file.  It
   expands to a DEFPACKAGE and an IN-PACKAGE, so every form after it
   in the file is read in the demo's own package; that package is the
   demo's namespace for its file-local globals, which is the only
   reason it exists."

  (check-type name keyword)
  (let* ((name-str    (symbol-name name))
         (class-str   (concatenate 'string name-str "-DEMO"))
         (pkg-name    (format nil "XCB-DEMOS.~A" name-str))
         (number      (%demo-number name))
         (nick-1      (format nil "DEMO~D" number))
         (nick-2      (format nil "XCB-DEMO~D" number))
         (pkg         (let ((p (or (find-package pkg-name)
                                   (make-package pkg-name
                                                 :nicknames (list nick-1 nick-2)))))
                        (shadow '("RUN" "START" "STOP" "MAIN") p)
                        (use-package '(#:cl #:xcb-demos #:xcb-const) p)
                        p))
         ;; :MIXINS, :APP and :OPTIONS are not initargs; split them out.
         (mixins      (getf initargs :mixins))
         (app         (getf initargs :app))
         (options     (getf initargs :options))
         (real-init   (loop for (k v) on initargs by #'cddr
                            unless (member k '(:mixins :app :options))
                              append (list k v)))
         (superclasses (list* 'xcb-demo mixins))
         (demo-class  (intern class-str pkg))
         (run-sym     (intern "RUN" pkg))
         (start-sym   (intern "START" pkg))
         (stop-sym    (intern "STOP" pkg))
         (main-sym    (intern "MAIN" pkg))
         (d-param     (gensym "DEMO-INSTANCE"))
         (conn-param  (gensym "CONN"))
         (from-pkgs   (remove pkg
                              (delete-duplicates
                               (remove nil (list *package*
                                                 (find-package "COMMON-LISP-USER")
                                                 (find-package "XCB-DEMOS"))))))
         (rehomed-body (%rehome-symbols body from-pkgs pkg))
         ;; The whole form is read before its IN-PACKAGE takes effect, so
         ;; the application class and its slot names are rehomed just
         ;; like the body.
         (app-class   (%rehome-symbols app from-pkgs pkg))
         (option-keys (%rehome-symbols options from-pkgs pkg))
         (earmuffs    (%collect-earmuff-symbols rehomed-body pkg))
         (d-syms      (delete-duplicates
                       (list (intern "D" *package*)
                             (intern "D" pkg)
                             (intern "D" (find-package "XCB-DEMOS"))
                             (intern "D" (find-package "COMMON-LISP-USER")))))
         (conn-syms   (delete-duplicates
                       (list (intern "CONN" *package*)
                             (intern "CONN" pkg)
                             (intern "CONN" (find-package "XCB-DEMOS"))
                             (intern "CONN" (find-package "COMMON-LISP-USER"))))))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (unless (find-package ,pkg-name)
           (let ((p (make-package ,pkg-name
                                  :nicknames (list ,nick-1 ,nick-2))))
             (shadow '("RUN" "START" "STOP" "MAIN") p)
             (use-package '(#:cl #:xcb-demos #:xcb-const) p))))

       (defpackage ,pkg-name
         (:nicknames ,nick-1 ,nick-2)
         (:use #:cl #:xcb-demos #:xcb-const)
         (:shadow #:run #:start #:stop #:main)
         (:export #:run #:start #:stop #:main))

       (in-package ,pkg-name)

       ,@(when earmuffs `((declaim (special ,@earmuffs))))

       (defclass ,demo-class ,superclasses ())

       (defmethod demo-body ((,d-param ,demo-class) ,conn-param)
         (declare (ignorable ,conn-param))
         (let (,@(loop for sym in d-syms
                       collect `(,sym ,d-param))
               ,@(loop for sym in conn-syms
                       collect `(,sym ,conn-param)))
           (declare (ignorable ,@d-syms ,@conn-syms))
           ,@rehomed-body))

       (defun ,run-sym (&rest options)
         "Start this demo with OPTIONS, a plist of the demo's declared
          options, and return its instance.  Shorthand for
          (XD:START-WITH-OPTIONS ,name ...), defined here so the demo's
          own package has a short entry point."
         (apply #'xcb-demos:start-with-options ,name options))

       (defun ,start-sym (&rest options)
         "The same as RUN."
         (apply #',run-sym options))

       (defun ,stop-sym (&key (timeout 5))
         "Stop this demo and wait up to TIMEOUT seconds for its thread to
          exit.  Shorthand for (XD:STOP ,name)."
         (xcb-demos:stop ,name :timeout timeout))

       (defun ,main-sym (&optional (args (uiop:command-line-arguments)))
         "Start this demo with the options in ARGS, command-line style, and
          block until it finishes.  Shorthand for (XD:MAIN ,name)."
         (xcb-demos:main ,name args))

       (xcb-demos::register-demo
        ,name
        (make-instance ',demo-class
                       :name ,name
                       :app-class ',app-class
                       :option-keys ',option-keys
                       ,@real-init)))))


;; REPL helpers

(defmacro with-repl-interrupt-handler (&body body)
  "Run BODY with Ctrl+C caught and turned into a normal unwind to the
   REPL, rather than a descent into the debugger.  Only interactive
   interrupts are caught; real errors propagate as usual."
  `(handler-case (with-user-abort:with-user-abort ,@body)
     (with-user-abort:user-abort (c)
       (declare (ignore c))
       (format *error-output*
               "~&Interrupt received; returning to the REPL.~%")
       nil)))

;; (defmacro with-repl-interrupt-handler (&body body)
;;   "Run BODY with Ctrl+C caught and turned into a normal unwind to the
;;    REPL, rather than a descent into the debugger.  Only interactive
;;    interrupts are caught; real errors propagate as usual."
;;   #+sbcl
;;   `(handler-case (progn ,@body)
;;      (sb-sys:interactive-interrupt (c)
;;        (declare (ignore c))
;;        (format *error-output*
;;                "~&Interrupt received; returning to the REPL.~%")
;;        nil))
;;   #-sbcl
;;   `(progn ,@body))

(defmacro ignoring-errors (&body body)
  "Run each form in BODY, discarding any error it signals, and
   continue with the next.  Unlike (ignore-errors (progn ...)), a
   failure in one form does not skip the rest.  Intended for
   best-effort teardown sequences."
  `(progn
     ,@(loop for form in body
             collect `(ignore-errors ,form))))
