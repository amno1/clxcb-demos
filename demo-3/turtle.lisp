;;; turtle.lisp — a viewer for Lisp turtle drawings in CLXCB.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; Self-contained: defines the TURTLE package and the viewer application.
;;;
;;; Runs a Lisp file with turtle drawing commands, or opens a file dialog
;;; to choose one, and displays the resulting picture.
;;;
;;; Drawing files are ordinary Lisp.  Each file is evaluated in its own
;;; programmatically generated package (TURTLE-XXXX) using :CL and :TURTLE,
;;; so scripts require zero package boilerplate:
;;;
;;;     (pen-down)
;;;     (forward 100)
;;;     (heading 90)
;;;     (forward 100)
;;;
;;; The active script package is kept in *CURRENT-SCRIPT-PACKAGE* and is
;;; automatically deleted when switching drawings or upon exiting the viewer,
;;; leaving zero garbage in the Common Lisp image.
;;;
;;; Keys:
;;;   o        choose a drawing file
;;;   r        reload the current drawing
;;;   ?        print help
;;;   q / Esc  exit

(defpackage #:turtle
  (:use #:cl)
  (:export #:forward
           #:backward
           #:back
           #:heading
           #:turn
           #:left
           #:right
           #:pen-up
           #:pen-down
           #:circle
           #:reset-turtle
           #:color
           #:fill-color
           #:width
           #:begin-shape
           #:fill-shape
           #:set-position
           #:goto
           #:set-x
           #:set-y
           #:home
           #:stroke-batch
           #:stroke-batch-p
           #:make-stroke-batch
           #:stroke-batch-color
           #:stroke-batch-width
           #:stroke-batch-segments
           #:fill-polygon
           #:fill-polygon-p
           #:make-fill-polygon
           #:fill-polygon-color
           #:fill-polygon-points
           #:turtle-all-segments
           #:turtle-elements
           #:*turtle*
           #:call-with-new-turtle
           #:run-drawing-file
           #:*current-script-package*
           #:delete-script-package
           #:reset))

(in-package #:turtle)

(defstruct stroke-batch
  (color "black")
  (width 1)
  (segments '()))

(defstruct fill-polygon
  (color "black")
  (points '()))

(defstruct turtle
  (x 200.0)
  (y 200.0)
  (heading 0.0)                 ; degrees, 0 = up, + = clockwise
  (pen-down t)
  (color "black")
  (fill-color "black")
  (width 1)
  (shape-mode nil)
  (shape-points '())
  (elements '()))

(defvar *turtle* nil
  "The turtle the drawing commands act on.  Bound by
   CALL-WITH-NEW-TURTLE while a drawing file is loading.")

(defun add-segment (turtle x1 y1 x2 y2)
  "Add a line segment to TURTLE's current stroke batch."
  (let ((cur (car (turtle-elements turtle)))
        (col (turtle-color turtle))
        (wid (turtle-width turtle)))
    (if (and (stroke-batch-p cur)
             (equal (stroke-batch-color cur) col)
             (= (stroke-batch-width cur) wid))
        (push (make-instance 'xcb::segment :x1 x1 :y1 y1 :x2 x2 :y2 y2)
              (stroke-batch-segments cur))
        (let ((batch (make-stroke-batch
                      :color col
                      :width wid
                      :segments (list (make-instance 'xcb::segment
                                                     :x1 x1 :y1 y1 :x2 x2 :y2 y2)))))
          (push batch (turtle-elements turtle))))))

(defun forward (distance)
  "Move DISTANCE forward.  Draws a segment if the pen is down, or records
   a vertex if in shape mode."
  (let* ((rad   (* (turtle-heading *turtle*) (/ pi 180.0)))
         (old-x (turtle-x *turtle*))
         (old-y (turtle-y *turtle*))
         (new-x (+ old-x (* distance (sin rad))))
         (new-y (+ old-y (* distance (cos rad)))))
    (if (turtle-shape-mode *turtle*)
        (progn
          (unless (turtle-shape-points *turtle*)
            (push (cons old-x old-y) (turtle-shape-points *turtle*)))
          (push (cons new-x new-y) (turtle-shape-points *turtle*)))
        (when (turtle-pen-down *turtle*)
          (add-segment *turtle* (round old-x) (round old-y)
                                (round new-x) (round new-y))))
    (setf (turtle-x *turtle*) new-x
          (turtle-y *turtle*) new-y)))

(defun backward (distance)
  "Move DISTANCE backward."
  (forward (- distance)))

(declaim (inline back))
(defun back (distance)
  "Move the turtle backward by DISTANCE units. Alias for BACKWARD."
  (backward distance))

(defun heading (&optional degrees)
  "Get or set the absolute heading.  0 = up, + = clockwise, - = anticlockwise."
  (if degrees
      (setf (turtle-heading *turtle*) (mod (float degrees 1.0) 360.0))
      (turtle-heading *turtle*)))

(defun turn (degrees)
  "Turn relative to current heading: + clockwise, - anticlockwise."
  (heading (+ (heading) degrees)))

(defun left (degrees)
  "Turn DEGREES counter-clockwise."
  (turn (- degrees)))

(defun right (degrees)
  "Turn DEGREES clockwise."
  (turn degrees))

(defun pen-up   () (setf (turtle-pen-down *turtle*) nil))
(defun pen-down () (setf (turtle-pen-down *turtle*) t))

(defun circle (radius &optional (extent 360) (clockwise t) (steps 64))
  "Draw an arc of RADIUS centered at the turtle's current position.
   EXTENT is the angle in degrees (default 360).
   CLOCKWISE is T for clockwise (to turtle's right), NIL for counter-clockwise (to turtle's left).
   STEPS is the number of linear segments for a full 360-degree circle."
  (let* ((num-segments (max 1 (round (* steps (/ (abs extent) 360.0)))))
         (cx (turtle-x *turtle*))
         (cy (turtle-y *turtle*))
         (h (turtle-heading *turtle*))
         (start-angle (if clockwise h (- h extent)))
         (step-angle (/ (float extent 1.0) num-segments))
         (prev-rad (* start-angle (/ pi 180.0)))
         (prev-x (+ cx (* radius (sin prev-rad))))
         (prev-y (+ cy (* radius (cos prev-rad)))))
    (if (turtle-shape-mode *turtle*)
        (progn
          (unless (turtle-shape-points *turtle*)
            (push (cons prev-x prev-y) (turtle-shape-points *turtle*)))
          (loop for i from 1 to num-segments
                for cur-angle = (+ start-angle (* i step-angle))
                for cur-rad = (* cur-angle (/ pi 180.0))
                for cur-x = (+ cx (* radius (sin cur-rad)))
                for cur-y = (+ cy (* radius (cos cur-rad)))
                do (push (cons cur-x cur-y) (turtle-shape-points *turtle*))))
        (when (turtle-pen-down *turtle*)
          (loop for i from 1 to num-segments
                for cur-angle = (+ start-angle (* i step-angle))
                for cur-rad = (* cur-angle (/ pi 180.0))
                for cur-x = (+ cx (* radius (sin cur-rad)))
                for cur-y = (+ cy (* radius (cos cur-rad)))
                do (add-segment *turtle* (round prev-x) (round prev-y)
                                        (round cur-x) (round cur-y))
                   (setf prev-x cur-x
                         prev-y cur-y))))))

(defun reset-turtle ()
  "Reset turtle position to center (200, 200), heading 0, pen down, default colors."
  (when *turtle*
    (setf (turtle-x *turtle*) 200.0
          (turtle-y *turtle*) 200.0
          (turtle-heading *turtle*) 0.0
          (turtle-pen-down *turtle*) t
          (turtle-color *turtle*) "black"
          (turtle-fill-color *turtle*) "black"
          (turtle-width *turtle*) 1
          (turtle-shape-mode *turtle*) nil
          (turtle-shape-points *turtle*) nil)))

(defun reset ()
  "Reset turtle position to center (200, 200), heading 0, pen down, default colors."
  (reset-turtle))

(defun set-position (new-x new-y)
  "Move the turtle directly to (NEW-X, NEW-Y).
   Draws a segment if the pen is down and not in shape mode.
   Records a vertex if in shape mode."
  (let ((old-x (turtle-x *turtle*))
        (old-y (turtle-y *turtle*))
        (target-x (float new-x 1.0))
        (target-y (float new-y 1.0)))
    (if (turtle-shape-mode *turtle*)
        (progn
          (unless (turtle-shape-points *turtle*)
            (push (cons old-x old-y) (turtle-shape-points *turtle*)))
          (push (cons target-x target-y) (turtle-shape-points *turtle*)))
        (when (turtle-pen-down *turtle*)
          (add-segment *turtle* (round old-x) (round old-y)
                                (round target-x) (round target-y))))
    (setf (turtle-x *turtle*) target-x
          (turtle-y *turtle*) target-y)))

(declaim (inline goto))
(defun goto (new-x new-y)
  "Move the turtle directly to (NEW-X, NEW-Y). Alias for SET-POSITION."
  (set-position new-x new-y))

(defun set-x (new-x)
  "Move the turtle horizontally to NEW-X."
  (set-position new-x (turtle-y *turtle*)))

(defun set-y (new-y)
  "Move the turtle vertically to NEW-Y."
  (set-position (turtle-x *turtle*) new-y))

(defun home ()
  "Move turtle to the center (200, 200) and pointing up (heading 0)."
  (setf (turtle-heading *turtle*) 0.0)
  (set-position 200.0 200.0))

(defun color (&optional c)
  "Get or set the current pen color (and default fill color)."
  (if c
      (progn
        (when *turtle*
          (setf (turtle-color *turtle*) c
                (turtle-fill-color *turtle*) c))
        c)
      (and *turtle* (turtle-color *turtle*))))

(defun fill-color (&optional c)
  "Get or set the fill color."
  (if c
      (progn
        (when *turtle*
          (setf (turtle-fill-color *turtle*) c))
        c)
      (and *turtle* (turtle-fill-color *turtle*))))

(defun width (&optional w)
  "Get or set the line width in pixels."
  (if w
      (progn
        (when *turtle*
          (setf (turtle-width *turtle*) (max 1 (round w))))
        w)
      (and *turtle* (turtle-width *turtle*))))

(defun begin-shape ()
  "Begin recording vertices for a filled polygon."
  (when *turtle*
    (setf (turtle-shape-mode *turtle*) t
          (turtle-shape-points *turtle*) nil)))

(defun fill-shape (&optional color)
  "Finish recording vertices and emit a filled polygon element with COLOR (defaulting
   to current fill-color or turtle color)."
  (when (and *turtle* (turtle-shape-mode *turtle*))
    (let ((pts (nreverse (turtle-shape-points *turtle*)))
          (col (or color (turtle-fill-color *turtle*) (turtle-color *turtle*))))
      (when (and pts (>= (length pts) 3))
        (push (make-fill-polygon :color col :points pts)
              (turtle-elements *turtle*))))
    (setf (turtle-shape-mode *turtle*) nil
          (turtle-shape-points *turtle*) nil)))

(defun turtle-all-segments (elements)
  "Extract all segments from drawing ELEMENTS list."
  (loop for el in elements
        when (stroke-batch-p el)
        append (stroke-batch-segments el)))

(defun turtle-segments (turtle)
  "Extract all segments from TURTLE."
  (turtle-all-segments (turtle-elements turtle)))

(defun call-with-new-turtle (fn &optional thunk)
  "Call THUNK with *TURTLE* bound to a fresh turtle and return the drawing
   elements in chronological order (oldest first).
   Supports both (call-with-new-turtle thunk) and legacy (call-with-new-turtle drawfn thunk)."
  (let ((actual-thunk (or thunk fn))
        (*turtle* (make-turtle)))
    (funcall actual-thunk)
    (when (turtle-shape-mode *turtle*)
      (fill-shape))
    (let ((elems (nreverse (turtle-elements *turtle*))))
      (dolist (el elems)
        (when (stroke-batch-p el)
          (setf (stroke-batch-segments el)
                (nreverse (stroke-batch-segments el)))))
      elems)))

(defvar *current-script-package* nil
  "The dynamic package created for the currently running or loaded script, or NIL.")

(defun delete-script-package ()
  "Delete *CURRENT-SCRIPT-PACKAGE* if it exists, and reset the variable to NIL."
  (when *current-script-package*
    (let ((pkg (if (packagep *current-script-package*)
                   *current-script-package*
                   (find-package *current-script-package*))))
      (when (and pkg (package-name pkg))
        (ignore-errors (delete-package pkg))))
    (setf *current-script-package* nil)))

(defun run-drawing-file (pathname)
  "Load PATHNAME with a fresh turtle and return the list of drawing elements
   it produces, in scene coordinates, oldest first.

   Evaluates the script in its own unique, programmatically generated package
   with a gensymed name prefixed by TURTLE- that uses :CL and :TURTLE.
   The package is kept in *CURRENT-SCRIPT-PACKAGE* until the drawing is switched
   or the viewer exits, at which point it is deleted."
  (let* ((new-pkg (make-package (gensym "TURTLE-") :use '(#:cl #:turtle)))
         (success nil))
    (unwind-protect
         (multiple-value-prog1
             (call-with-new-turtle
              (lambda ()
                (let ((*package* new-pkg))
                  (load pathname))))
           (setf success t)
           ;; Delete previous script package upon successful load of the new one
           (delete-script-package)
           (setf *current-script-package* new-pkg))
      (unless success
        (when (and new-pkg (package-name new-pkg))
          (ignore-errors (delete-package new-pkg)))))))


;;; The Viewer Application

(in-package #:cl-user)

(declaim (ftype function run-turtle-viewer render-drawing
                load-drawing reload-drawing pick-drawing-file))

(xd:define-demo :turtle
    (:wm-title "CLXCB Turtle Viewer"
     :wm-class "clxcb-turtle"
     :resource-class "Turtle"
     :app turtle-viewer
     :options (:width :height :x :y :geometry :file :scene))
  (format t "~&========================================~%")
  (format t "   CLXCB Turtle Viewer (demo3)           ~%")
  (format t "========================================~%")
  (run-turtle-viewer d conn))

(defconstant +scene-size+ 400
  "The turtle draws in a +SCENE-SIZE+ x +SCENE-SIZE+ coordinate space;
   the window scales it to fit, so headings and distances keep their
   relative proportions at any window size.")

(defparameter *default-drawing-file*
  (asdf:system-relative-pathname "clxcb-demos" "demo-3/scenes/snowflake.lisp")
  "The default drawing file loaded when no :FILE option is passed.")

(defparameter *standard-colors*
  '(("black"            . (0 0 0))
    ("white"            . (255 255 255))
    ("red"              . (255 0 0))
    ("green"            . (0 128 0))
    ("lime"             . (0 255 0))
    ("blue"             . (0 0 255))
    ("yellow"           . (255 255 0))
    ("cyan"             . (0 255 255))
    ("aqua"             . (0 255 255))
    ("magenta"          . (255 0 255))
    ("fuchsia"          . (255 0 255))
    ("orange"           . (255 165 0))
    ("brown"            . (165 42 42))
    ("tan"              . (210 180 140))
    ("salmon"           . (250 128 114))
    ("purple"           . (128 0 128))
    ("gray"             . (128 128 128))
    ("grey"             . (128 128 128))
    ("lightgray"        . (211 211 211))
    ("lightgrey"        . (211 211 211))
    ("darkgray"         . (169 169 169))
    ("darkgrey"         . (169 169 169))
    ("pink"             . (255 192 203))
    ("navy"             . (0 0 128))
    ("maroon"           . (128 0 0))
    ("olive"            . (128 128 0))
    ("teal"             . (0 128 128))
    ("silver"           . (192 192 192))
    ("gold"             . (255 215 0))
    ("royal blue"       . (65 105 225))
    ("royalblue"        . (65 105 225))
    ("deep sky blue"    . (0 191 255))
    ("deepskyblue"      . (0 191 255))
    ("sky blue"         . (135 206 235))
    ("skyblue"          . (135 206 235))
    ("light sky blue"   . (135 206 250))
    ("lightskyblue"     . (135 206 250))
    ("light cyan"       . (224 255 255))
    ("lightcyan"        . (224 255 255))
    ("ice blue"         . (217 240 255))
    ("alice blue"       . (240 248 255))
    ("aliceblue"        . (240 248 255))
    ("azure"            . (240 255 255))
    ("cornflower blue"  . (100 149 237))
    ("cornflowerblue"   . (100 149 237))
    ("dodger blue"      . (30 144 255))
    ("dodgerblue"       . (30 144 255))
    ("steel blue"       . (70 130 180))
    ("steelblue"        . (70 130 180)))
  "Standard color names mapped to (R G B) triples in [0, 255].")

(defparameter *logo-colors*
  #(;; 0: black, 1: blue, 2: lime, 3: cyan
    (0 0 0) (0 0 255) (0 255 0) (0 255 255)
    ;; 4: red, 5: magenta, 6: yellow, 7: white
    (255 0 0) (255 0 255) (255 255 0) (255 255 255)
    ;; 8: brown, 9: tan, 10: green, 11: aqua
    (165 42 42) (210 180 140) (0 128 0) (0 255 255)
    ;; 12: salmon, 13: purple, 14: orange, 15: gray
    (250 128 114) (128 0 128) (255 165 0) (128 128 128))
  "The 16 standard Logo turtle graphics color codes.")

(defun parse-hex-color (str)
  "Parse '#RGB' or '#RRGGBB' into (r g b) in [0, 255], or NIL on failure."
  (when (and (stringp str) (plusp (length str)) (char= (char str 0) #\#))
    (let ((hex (subseq str 1)))
      (cond
        ((= (length hex) 6)
         (let ((val (parse-integer hex :radix 16 :junk-allowed t)))
           (when val
             (list (ldb (byte 8 16) val)
                   (ldb (byte 8 8) val)
                   (ldb (byte 8 0) val)))))
        ((= (length hex) 3)
         (let ((r (digit-char-p (char hex 0) 16))
               (g (digit-char-p (char hex 1) 16))
               (b (digit-char-p (char hex 2) 16)))
           (when (and r g b)
             (list (+ (* r 16) r)
                   (+ (* g 16) g)
                   (+ (* b 16) b)))))
        (t nil)))))

(defun resolve-color (v color-spec)
  "Convert COLOR-SPEC (string, symbol, or integer) to an X11 pixel value for V's screen.
   Results are cached in (viewer-color-cache v)."
  (or (gethash color-spec (viewer-color-cache v))
      (let* ((conn   (xact:widget-connection v))
             (screen (xd:app-screen v))
             (visual (xcb:find-root-visual screen))
             (key    color-spec)
             (pixel
              (cond
                ;; Direct integer pixel (> 15) or standard Logo index (0..15)
                ((integerp color-spec)
                 (if (and (>= color-spec 0) (< color-spec 16))
                     (destructuring-bind (r g b) (aref *logo-colors* color-spec)
                       (xcb:rgb->pixel visual r g b))
                     color-spec))
                ;; String or symbol name
                (t
                 (let* ((name-raw (string-downcase (string color-spec)))
                        (name     (string-trim '(#\Space #\Tab #\Newline) name-raw))
                        (hex-rgb  (parse-hex-color name)))
                   (cond
                     ;; Hex color #RRGGBB or #RGB
                     (hex-rgb
                      (destructuring-bind (r g b) hex-rgb
                        (xcb:rgb->pixel visual r g b)))
                     ;; Standard color table lookup
                     ((assoc name *standard-colors* :test #'string-equal)
                      (destructuring-bind (r g b)
                          (cdr (assoc name *standard-colors* :test #'string-equal))
                        (xcb:rgb->pixel visual r g b)))
                     ;; Query X server via alloc-named-color
                     (t
                      (handler-case
                          (let* ((cmap   (xcb:default-colormap screen))
                                 (cookie (xcb::alloc-named-color conn cmap name))
                                 (reply  (xcb::alloc-named-color-reply conn cookie)))
                            (slot-value reply 'xcb::pixel))
                        (error ()
                          (xcb:black-pixel screen))))))))))
        (setf (gethash key (viewer-color-cache v)) pixel)
        pixel)))

(defclass turtle-viewer (xd:application)
  ((gc           :initform nil :accessor viewer-gc)
   (done         :initform nil :accessor viewer-done
                 :documentation "Set by the quit key binding, polled by
                 the event loop.")
   (elements     :initform nil :accessor viewer-elements
                 :documentation "The turtle's drawing elements (stroke batches
                 and filled polygons), in scene coordinates, oldest first.
                 Replaced when a new file is loaded; NIL means 'nothing drawn yet'.")
   (color-cache  :initform (make-hash-table :test 'equal)
                 :accessor viewer-color-cache
                 :documentation "Cache mapping color-spec to resolved X11 pixel values.")
   (scene-opt    :initarg :scene
                 :initform nil
                 :type (or null string symbol)
                 :accessor viewer-scene-opt
                 :documentation "Scene name keyword or string.")
   (drawing-file :initarg :file
                 :initform nil
                 :type (or null string pathname symbol)
                 :accessor viewer-drawing-file
                 :documentation "Pathname or scene keyword of the file currently loaded,
                 or NIL.  RELOAD-DRAWING re-loads it; the file dialog
                 uses its directory as the default.")
   (keymap       :initform (make-hash-table :test 'eql)
                 :reader viewer-keymap
                 :documentation "Numeric X keysym -> function of no
                 arguments, filled by SETUP-KEYBINDINGS."))
  (:default-initargs :width 600 :height 600))

(defmethod viewer-segments ((v turtle-viewer))
  (turtle:turtle-all-segments (viewer-elements v)))

(defmethod (setf viewer-segments) (segs (v turtle-viewer))
  (setf (viewer-elements v) (list (turtle:make-stroke-batch :segments segs))))

(defun render-drawing (v)
  "Clear V's window to white, then render its drawing elements
   (filled polygons and stroke batches) in chronological order.
   Scene coordinates are scaled to fit the window by FIT-TRANSFORM."
  (let ((conn (xact:widget-connection v))
        (win  (xact:widget-window v))
        (gc   (viewer-gc v)))
    (when (and win gc)
      (let ((w (xact:widget-width v))
            (h (xact:widget-height v)))
        ;; White background.
        (let ((white (xcb:white-pixel (xd:app-screen v))))
          (xcb::change-gc conn gc #x4 :foreground white)
          (xcb::poly-fill-rectangle
           conn win gc
           (list (make-instance 'xcb::rectangle
                                :x 0 :y 0 :width w :height h))))
        ;; Render elements in chronological order
        (let* ((tr (xd:fit-transform +scene-size+ +scene-size+ w h))
               (elements (viewer-elements v)))
          (dolist (el elements)
            (cond
              ((turtle:fill-polygon-p el)
               (let* ((pts (turtle:fill-polygon-points el))
                      (color-pixel (resolve-color v (turtle:fill-polygon-color el))))
                 (when (and pts (>= (length pts) 3))
                   (let ((pixel-points
                           (mapcar (lambda (pt)
                                     (multiple-value-bind (px py)
                                         (xd:transform-point tr (car pt) (cdr pt))
                                       (make-instance 'xcb::point :x px :y py)))
                                   pts)))
                     (xcb::change-gc conn gc #x4 :foreground color-pixel)
                     (xcb::fill-poly conn win gc 0 0 pixel-points)))))
              ((turtle:stroke-batch-p el)
               (let* ((segs (turtle:stroke-batch-segments el))
                      (color-pixel (resolve-color v (turtle:stroke-batch-color el)))
                      (lw (max 1 (round (turtle:stroke-batch-width el)))))
                 (when segs
                   (let ((pixel-segs (xd:transform-segments tr segs)))
                     (when pixel-segs
                       (xcb::change-gc conn gc (logior #x4 #x10)
                                       :foreground color-pixel
                                       :line-width lw)
                       (xcb::poly-segment conn win gc pixel-segs)))))))))))))

(defmethod xact:draw ((v turtle-viewer) surface)
  (declare (ignore surface))
  (render-drawing v))

(defun resolve-scene-path (spec)
  "Resolve SPEC (keyword, symbol, string, or pathname) to a scene file pathname."
  (when spec
    (let ((name (typecase spec
                  (symbol (string-downcase (symbol-name spec)))
                  (string spec)
                  (pathname (return-from resolve-scene-path spec))
                  (t (return-from resolve-scene-path nil)))))
      (cond
        ;; Exact existing file
        ((and (stringp name) (probe-file name))
         (pathname name))
        ;; In demo-3/scenes/ directory with exact name
        ((probe-file (asdf:system-relative-pathname "clxcb-demos"
                                                    (format nil "demo-3/scenes/~A" name)))
         (asdf:system-relative-pathname "clxcb-demos" (format nil "demo-3/scenes/~A" name)))
        ;; In demo-3/scenes/ directory with .lisp extension
        ((probe-file (asdf:system-relative-pathname "clxcb-demos"
                                                    (format nil "demo-3/scenes/~A.lisp" name)))
         (asdf:system-relative-pathname "clxcb-demos" (format nil "demo-3/scenes/~A.lisp" name)))
        ;; Aliases
        ((member name '("triangle" "sierpinski-triangle" "gasket") :test #'string=)
         (asdf:system-relative-pathname "clxcb-demos" "demo-3/scenes/sierpinski-triangle.lisp"))
        ((member name '("sierpinski" "curve" "sierpinski-curve") :test #'string=)
         (asdf:system-relative-pathname "clxcb-demos" "demo-3/scenes/sierpinski.lisp"))
        ((member name '("snowflake" "koch" "koch-snowflake") :test #'string=)
         (asdf:system-relative-pathname "clxcb-demos" "demo-3/scenes/snowflake.lisp"))
        ((member name '("star" "square" "square-and-star") :test #'string=)
         (asdf:system-relative-pathname "clxcb-demos" "demo-3/scenes/square-and-star.lisp"))
        (t
         (or (probe-file spec)
             (asdf:system-relative-pathname "clxcb-demos"
                                            (format nil "demo-3/scenes/~A.lisp" name))))))))

(defun load-drawing (v pathname)
  "Run PATHNAME and install its drawing elements in V.  Reports failures but
   keeps the previous drawing in that case, so a typo in an edit does
   not blank the window."
  (let* ((actual-path (or (resolve-scene-path pathname) pathname)))
    (handler-case
        (let ((elements (turtle:run-drawing-file actual-path)))
          (setf (viewer-elements v)     elements
                (viewer-drawing-file v) (pathname actual-path)
                (xact:widget-dirty-p v) t)
          (format t "~&Loaded ~A: ~D drawing element~:P~%"
                  (file-namestring actual-path) (length elements))
          (render-drawing v))
      (error (e)
        (format *error-output* "~&Could not load ~A: ~A~%" actual-path e)))))

(defun reload-drawing (v)
  (if (viewer-drawing-file v)
      (load-drawing v (viewer-drawing-file v))
      (format t "~&No drawing file loaded.  Press o to choose one.~%")))

(defun pick-drawing-file (v)
  "Open a file dialog for a Lisp drawing file, and load it."
  (handler-case
      (let* ((default  (or (and (viewer-drawing-file v)
                                (uiop:pathname-directory-pathname
                                 (pathname (viewer-drawing-file v))))
                           (and (probe-file *default-drawing-file*)
                                (uiop:pathname-directory-pathname *default-drawing-file*))
                           (uiop:getcwd)))
             (selected (org.shirakumo.file-select:existing
                         :title   "Choose Turtle Drawing File"
                         :filter  "lisp"
                         :default default)))
        (when selected
          (load-drawing v selected)))
    (error (e)
      (format *error-output* "~&File dialog failed: ~A~%" e))))

(defparameter *help-text*
  '("o        choose a drawing file"
    "r        reload the current drawing"
    "?        print this help"
    "q / Esc  exit")
  "The viewer's controls, printed at startup and by the ? key.")

(defun print-help ()
  (format t "~&Turtle Viewer controls:~%~{  ~A~%~}" *help-text*)
  (finish-output))

(defun setup-keybindings (v)
  (flet ((bind (ks fn) (setf (gethash ks (viewer-keymap v)) fn)))
    (bind +xk-q-small+   (lambda () (setf (viewer-done v) t)))
    (bind +xk-q-capital+ (lambda () (setf (viewer-done v) t)))
    (bind +xk-escape+    (lambda () (setf (viewer-done v) t)))
    (bind +xk-o-small+   (lambda () (pick-drawing-file v)))
    (bind +xk-o-capital+ (lambda () (pick-drawing-file v)))
    (bind +xk-r-small+   (lambda () (reload-drawing v)))
    (bind +xk-r-capital+ (lambda () (reload-drawing v)))
    (bind +xk-question+  #'print-help)))

(defun setup-window (v position-p)
  "Create V's window with a white background, and its GC.  With
   POSITION-P, the position was asked for and also goes to the window
   manager; otherwise the WM places the window as it likes."
  (let* ((conn  (xact:widget-connection v))
         (white (xcb:white-pixel (xd:app-screen v)))
         (win   (xd:realize-application
                 v :x 100 :y 100
                   :background-pixel white
                   :event-mask (logior +event-mask-exposure+
                                       +event-mask-key-press+
                                       +event-mask-structure-notify+)))
         (gc    (xcb:generate-id conn)))
    (setf (viewer-gc v) gc)
    (xcb::create-gc conn gc win #x4 :foreground 0)
    (when position-p
      (xd:set-placement-hints v))))

(defun viewer-event (v ev)
  "Handle EV, an XCB event that no interactor claimed: keys through the
   keymap, exposes, resizes, and the close button."
  (typecase ev
    (xcb::key-press
     (let ((ks (xact:xcb-event-keysym (xact:widget-connection v) ev)))
       (when ks
         (let ((fn (gethash ks (viewer-keymap v))))
           (when fn (funcall fn))))))
    (xcb::expose
     (render-drawing v))
    (xcb::configure-notify
     (let ((w (slot-value ev 'xcb::width))
           (h (slot-value ev 'xcb::height)))
       (when (and (plusp w) (plusp h)
                  (or (/= w (xact:widget-width v))
                      (/= h (xact:widget-height v))))
         (setf (xact:widget-width v)  w
               (xact:widget-height v) h)
         (render-drawing v))))
    (xcb::client-message
     (when (xcb:wm-delete-window-message-p (xact:widget-connection v) ev)
       (setf (viewer-done v) t)))
    (xcb::destroy-notify
     (setf (viewer-done v) t))
    (t nil)))

(defun event-loop (v)
  "Run V's loop.  The quit interactor answers Escape and the close
   button; the keymap answers the rest."
  (let* ((win  (xact:widget-window v))
         (quit (make-instance 'xact:quit-interactor :window win)))
    (xact:widget-add-interactor v quit)
    (xact:run-widget v win
                     :stop-when (lambda ()
                                  (or (viewer-done v)
                                      (xact:quit-requested-p quit)))
                     :on-other-event (lambda (ev) (viewer-event v ev))
                     :idle-sleep 0.05)))

(defun teardown (v)
  (turtle:delete-script-package)
  (let ((conn (xact:widget-connection v)))
    (when (viewer-gc v)
      (ignore-errors (xcb::free-gc conn (viewer-gc v)))
      (setf (viewer-gc v) nil))
    (xact:unrealize v)))


;;; Entry points

(defun run-turtle-viewer (d conn)
  "Run the viewer: one TURTLE-VIEWER made from D's options."
  (let ((v (xd:make-application d conn)))
    (setup-keybindings v)
    (setup-window v (xd:resolve-placement v))
    (xcb::map-window conn (xact:widget-window v))

    ;; Drain the initial map / configure / expose burst, so the
    ;; window is at its real size before the first render.
    (loop for i from 0 below 64
          for ev = (xcb:poll-for-event conn)
          while ev
          do (typecase ev
                (xcb::configure-notify
                 (let ((w (slot-value ev 'xcb::width))
                       (h (slot-value ev 'xcb::height)))
                   (when (and (plusp w) (plusp h))
                     (setf (xact:widget-width v)  w
                           (xact:widget-height v) h))))
                (t nil)))

    (print-help)

    ;; If :SCENE or :FILE was given, load it; otherwise load the default drawing
    ;; if it exists, or open the file dialog.
    (let ((file (or (viewer-scene-opt v)
                    (viewer-drawing-file v)
                    (and (probe-file *default-drawing-file*)
                         *default-drawing-file*))))
      (if file
          (load-drawing v file)
          (pick-drawing-file v)))

    (unwind-protect
         (event-loop v)
      (teardown v))
    t))

(defmethod xd:normalize-demo-options ((d turtle-demo) options)
  "Allow scene shortcuts like (demo3:run :triangle), (demo3:run :snowflake),
   or (demo3:run :triangle :width 800) in addition to (demo3:run :file :triangle)."
  (cond
    ((null options) nil)
    ;; Odd length, e.g. (demo3:run :triangle) or (demo3:run :triangle :width 800)
    ((oddp (length options))
     (list* :file (first options) (rest options)))
    ;; Even length, but first argument is not a declared option keyword
    ((let ((first (first options)))
       (and (not (member first (xd:demo-option-keys d)))))
     (list* :file (first options) (rest options)))
    (t options)))
