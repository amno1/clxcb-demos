;;; demo-9/xneko.lisp — XNeko port for CLXCB.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; A port of the classic X11 xneko / oneko demo.  A small cat runs
;;; across the screen chasing the mouse pointer and cycling through
;;; eighteen animation states.  The cat window is override-redirect
;;; and (when the SHAPE extension is available) is clipped to the
;;; sprite's mask so the silhouette is non-rectangular.
;;;
;;; Sprites are read at startup from DEMO-9/BITMAPS/<variant>/
;;; (bodies) and DEMO-9/BITMASKS/<variant>/ (masks).  Cursor
;;; bitmaps come from DEMO-9/CURSORS/.
;;;
;;; As in oneko, the variant's cursor, a mouse for the cats, a bone
;;; for the dog, is the cat window's cursor, and by default the root
;;; window's too, so the pointer the cat chases looks like its prey
;;; (:ROOT-CURSOR NIL keeps the desktop's own).  The root cursor is put
;;; back when the demo exits.
;;;
;;; Controls:
;;;   Alt+q  or  Ctrl+q     exit

(xd:define-demo :xneko
    (:resource-class "XNeko"
     :app xneko
     :options (:variant :foreground :background :speed :idle :interval :shape
               :tofocus :x-offset :y-offset :root-cursor :verbose))
  (format t "~&========================================~%")
  (format t "   CLXCB XNeko (demo9)                 ~%")
  (format t "========================================~%")
  (run-xneko d conn))

;;; State constants

(defconstant +bitmap-width+  32)
(defconstant +bitmap-height+ 32)
(defconstant +max-tick+      9999)

;;; Neko state indices, matching the C enum.
;; EVAL-WHEN: the state dispatch below reads these with #. at compile
;; time, which not every Lisp allows for a plain DEFCONSTANT.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +neko-stop+    0)
  (defconstant +neko-jare+    1)
  (defconstant +neko-kaki+    2)
  (defconstant +neko-akubi+   3)
  (defconstant +neko-sleep+   4)
  (defconstant +neko-awake+   5)
  (defconstant +neko-u-move+  6)
  (defconstant +neko-d-move+  7)
  (defconstant +neko-l-move+  8)
  (defconstant +neko-r-move+  9)
  (defconstant +neko-ul-move+ 10)
  (defconstant +neko-ur-move+ 11)
  (defconstant +neko-dl-move+ 12)
  (defconstant +neko-dr-move+ 13)
  (defconstant +neko-u-togi+  14)
  (defconstant +neko-d-togi+  15)
  (defconstant +neko-l-togi+  16)
  (defconstant +neko-r-togi+  17))

;;; durations, in ticks.
(defconstant +neko-stop-time+  4)
(defconstant +neko-jare-time+  10)
(defconstant +neko-kaki-time+  4)
(defconstant +neko-akubi-time+ 6)
(defconstant +neko-awake-time+ 3)
(defconstant +neko-togi-time+  10)
;; Ticks between two self-raises:
;; DEFAULT_RAISE_WAIT in oneko.c
;; ~2s at the default interval
(defconstant +raise-wait+ 16)


;;; Per-variant defaults (from AnimalDefaultsDataTable)

(defparameter *variant-defaults*
  '((:neko   :speed 13 :idle 6 :interval 125000 :off-x 0  :off-y 0  :cursor "mouse")
    (:tora   :speed 16 :idle 6 :interval 125000 :off-x 0  :off-y 0  :cursor "mouse")
    (:dog    :speed 10 :idle 6 :interval 125000 :off-x 0  :off-y 0  :cursor "bone")
    (:bsd    :speed 16 :idle 6 :interval 300000 :off-x 22 :off-y 20 :cursor "bsd")
    (:sakura :speed 13 :idle 6 :interval 125000 :off-x 0  :off-y 0  :cursor "card")
    (:tomoyo :speed 10 :idle 6 :interval 125000 :off-x 32 :off-y 32 :cursor "petal")))


;;; Animation tables (AnimationPattern[][] in the C original)

;;; For each state, the sprite basename used in frame 0 and frame 1.
;;; The mask filename is always "<name>_mask.xbm".
(defparameter +state-frame-0+
  #("mati2" "jare2" "kaki1" "mati3" "sleep1" "awake"
    "up1" "down1" "left1" "right1" "upleft1" "upright1"
    "dwleft1" "dwright1" "utogi1" "dtogi1" "ltogi1" "rtogi1"))

(defparameter +state-frame-1+
  #("mati2" "mati2" "kaki2" "mati3" "sleep2" "awake"
    "up2" "down2" "left2" "right2" "upleft2" "upright2"
    "dwleft2" "dwright2" "utogi2" "dtogi2" "ltogi2" "rtogi2"))


;;; The application
;;;
;;; Everything one run of the demo needs lives in an XNEKO instance,
;;; made by RUN-XNEKO from the demo's options and passed to every
;;; function, so runs never share state.  The slots are oneko.c's
;;; globals, under the same names.  The connection and the cat's window
;;; are the widget's, and the screen's root, size, depth and colormap
;;; are asked of the connection; WITH-XNEKO binds them all by name.

(defclass xneko (xd:application)
  ((fg-pixel :initform 0)
   (bg-pixel :initform 1)
   (fg-rgb   :initform '(0 0 0))
   (bg-rgb   :initform '(65535 65535 65535))

   (loader-gc :initform nil
              :documentation "A depth-1 GC used to upload XBM data via PUT-IMAGE.")
   (sprites   :initform nil
              :documentation "Hash table: sprite basename -> SPRITE, with
              its mask (see lib/sprites.lisp).")
   (sprite-gc :initform nil
              :documentation "The GC every sprite is drawn with on WINDOW:
              opaque, in the foreground and background colours.")
   (cursor    :initform nil)
   (shape-p   :initform nil)

   (neko-x          :initform 0)
   (neko-y          :initform 0)
   (neko-move-dx    :initform 0)
   (neko-move-dy    :initform 0)
   (neko-last-x     :initform -1)
   (neko-last-y     :initform -1)
   (last-shape-mask :initform nil)

   (neko-state  :initform +neko-stop+)
   (tick-count  :initform 0)
   (state-count :initform 0)

   (mouse-x      :initform 0)
   (mouse-y      :initform 0)
   (prev-mouse-x :initform 0)
   (prev-mouse-y :initform 0)
   (target       :initform 0)
   (prev-target  :initform 0)

   ;; The demo's options, for this run.  NIL for SPEED, IDLE-SPACE,
   ;; INTERVAL-US and the offsets means the variant's default, filled in
   ;; by MAKE-XNEKO.  :TORA is in *VARIANT-DEFAULTS* but its bitmaps are
   ;; not shipped (demo-9/bitmasks/ has no tora/), so it is not offered.
   (variant     :initarg :variant :initform :neko
                :type (member :neko :dog :bsd :sakura :tomoyo)
                :documentation "Which animal.")
   (foreground  :initarg :foreground :initform "black" :type string
                :documentation "Sprite colour name.")
   (background  :initarg :background :initform "white" :type string
                :documentation "Sprite background colour name.")
   (shape       :initarg :shape :initform t :type boolean
                :documentation "Use the SHAPE extension.")
   (root-cursor :initarg :root-cursor :initform t :type boolean
                :documentation "The variant's cursor on the root, as oneko does.")
   (verbose     :initarg :verbose :initform t :type boolean
                :documentation "Print diagnostics.")
   (idle-space  :initarg :idle :initform nil :type (or null (real 0))
                :documentation "Idle distance; NIL for the variant's default.")
   (speed       :initarg :speed :initform nil :type (or null (real (0)))
                :documentation "Pixels per step; NIL for the variant's default.")
   (interval-us :initarg :interval :initform nil :type (or null (integer 1))
                :documentation "Microseconds per frame; NIL for the variant's default.")
   (x-offset    :initarg :x-offset :initform nil :type (or null integer)
                :documentation "Horizontal offset from the target.")
   (y-offset    :initarg :y-offset :initform nil :type (or null integer)
                :documentation "Vertical offset from the target.")
   (tofocus     :initarg :tofocus :initform nil :type boolean
                :documentation "Chase the focused window, not the pointer.")

   (dont-mapped :initform t)
   (raise-delay :initform 0
                :documentation "Ticks until the cat may raise itself again
                (see HANDLE-EVENT and +RAISE-WAIT+).")
   (quit-keycodes :initform nil)
   (root-cursor-set :initform nil
                    :documentation "True once the root has our cursor, so
                    TEARDOWN-XNEKO gives it back.")
   (last-sprite-name :initform nil
                     :documentation "Name (string) of the sprite most recently
                     drawn, for redraws."))
  (:default-initargs :kind :override-redirect))


;;; WITH-SLOTS on an XNEKO, with CONN and WINDOW (the cat's) bound as
;;; well, and the screen's SCREEN, ROOT, WIDTH, HEIGHT, DEPTH and
;;; COLORMAP.
(defmacro with-xneko ((nk &rest slots) &body body)
  `(symbol-macrolet ((conn     (xact:widget-connection ,nk))
                     (window   (xact:widget-window ,nk))
                     (screen   (xd:app-screen ,nk))
                     (root     (xd:app-root ,nk))
                     (width    (xcb:width-in-pixels (xd:app-screen ,nk)))
                     (height   (xcb:height-in-pixels (xd:app-screen ,nk)))
                     (depth    (xd:app-depth ,nk))
                     (colormap (xcb:default-colormap (xd:app-screen ,nk))))
     (with-slots ,slots ,nk
       ,@body)))
(defparameter *sin-pi-per8* (sin (/ pi 8.0d0)))
(defparameter *sin-pi-per8-times-3* (sin (* 3 (/ pi 8.0d0))))

(defparameter *bitmap-dir*
  (asdf:system-relative-pathname "clxcb-demos" "demo-9/bitmaps/"))
(defparameter *bitmask-dir*
  (asdf:system-relative-pathname "clxcb-demos" "demo-9/bitmasks/"))
(defparameter *cursor-dir*
  (asdf:system-relative-pathname "clxcb-demos" "demo-9/cursors/"))



;;; Colour lookup

(defun alloc-colour (nk name &key (default-pixel 0) (default-rgb '(0 0 0)))
  "Return (values PIXEL (R G B)) for the named colour, or the defaults
   on failure.  RGB components are 16-bit, as the X protocol uses."
  (with-xneko (nk)
    (handler-case
        (let* ((cookie (xcb::alloc-named-color conn colormap name))
               (reply  (xcb::alloc-named-color-reply conn cookie)))
          (values (slot-value reply 'xcb::pixel)
                  (list (slot-value reply 'xcb::exact-red)
                        (slot-value reply 'xcb::exact-green)
                        (slot-value reply 'xcb::exact-blue))))
      (error ()
        (values default-pixel default-rgb)))))


;;; XBM loading

(defun sprite-file-basename (variant name)
  "Return the file basename (without .xbm) for sprite NAME of VARIANT.
   Neko uses plain names (\"mati2\"); the other variants append an
   underscore and the variant name (\"mati2_dog\", \"mati2_tomoyo\")."
  (if (eq variant :neko)
      name
      (format nil "~A_~(~A~)" name variant)))

(defun load-sprite (nk name)
  "The SPRITE named NAME of the run's variant, with its mask."
  (with-xneko (nk loader-gc variant)
    (let* ((variant-str (string-downcase (symbol-name variant)))
           (base        (sprite-file-basename variant name))
           (body-path   (merge-pathnames
                         (format nil "~A/~A.xbm" variant-str base)
                         *bitmap-dir*))
           (mask-path   (merge-pathnames
                         (format nil "~A/~A_mask.xbm" variant-str base)
                         *bitmask-dir*)))
      (unless (probe-file body-path)
        (error "xneko: missing body sprite ~A" body-path))
      (unless (probe-file mask-path)
        (error "xneko: missing mask sprite ~A" mask-path))
      (xcb-demos.sprites:load-xbm-sprite conn root body-path
                                         :mask-path mask-path :loader-gc loader-gc))))

(defun load-all-sprites (nk)
  "Load every sprite used by the animation tables into the SPRITES slot,
   a hash table keyed by sprite basename.  Sprites go into the table as
   they are made, so if one fails the ones already loaded are there to
   be freed (see TEARDOWN-XNEKO)."
  (let ((needed (make-hash-table :test 'equal))
        (result (setf (slot-value nk 'sprites) (make-hash-table :test 'equal))))
    (loop for name across +state-frame-0+ do (setf (gethash name needed) t))
    (loop for name across +state-frame-1+ do (setf (gethash name needed) t))
    (maphash (lambda (name _)
               (declare (ignore _))
               (setf (gethash name result) (load-sprite nk name)))
             needed)
    result))


;;; Cursor

(defun make-neko-cursor (nk)
  "Build the mouse-pointer cursor for the run's variant, or return NIL when the
   cursor XBMs are not present on disk.

   Cursor bitmaps live under DEMO-9/CURSORS/ and follow the naming
   convention <base>_cursor.xbm / <base>_cursor_mask.xbm, where <base>
   is the variant's :CURSOR field in *VARIANT-DEFAULTS* — for instance
   \"mouse\" for :neko and :tora, \"bone\" for :dog.

   The hot spot is (0, 0), the top-left of the arrow tip, matching the
   original XBM assets.

   The cursor goes on the cat window itself, always, and on the root
   only with :ROOT-CURSOR.  That is deliberate, and what oneko.c does
   (it creates the cat window with CWCursor): when the cat catches the
   pointer, the pointer is over the cat, and there it is the window's
   own cursor that shows -- so the cat holds a mouse (a bone, a petal)
   in its paws even when the desktop keeps its usual pointer.  Setting
   the cursor on the root only would lose that: over the cat window the
   pointer would be whatever the cat window has, which is the default.

   Returns a CURSOR resource id, or NIL when the assets are missing."
  (with-xneko (nk fg-rgb bg-rgb variant)
    (let ((base (getf (cdr (assoc variant *variant-defaults*)) :cursor)))
      (xcb-demos.sprites:make-xbm-cursor
       conn root
       (merge-pathnames (format nil "~A_cursor.xbm" base) *cursor-dir*)
       (merge-pathnames (format nil "~A_cursor_mask.xbm" base) *cursor-dir*)
       fg-rgb bg-rgb))))


;;; Window, GC, keymap

(defun setup-neko-window (nk)
  "Create the cat window, with CURSOR as its cursor when there is one
   (see MAKE-NEKO-CURSOR for why the cat window has it), as oneko.c
   creates it with CWCursor."
  (with-xneko (nk bg-pixel cursor)
    (setf window (xcb:generate-id conn))
    (apply #'xcb::create-window conn depth window root
           0 0 +bitmap-width+ +bitmap-height+
           0
           +window-class-input-output+
           0                              ; CopyFromParent visual
           (logior +cw-back-pixel+
                   +cw-override-redirect+
                   +cw-event-mask+
                   (if cursor +cw-cursor+ 0))
           :background-pixel bg-pixel
           :override-redirect 1
           :event-mask (logior +event-mask-exposure+
                               +event-mask-key-press+
                               +event-mask-visibility-change+)
           (and cursor (list :cursor cursor)))
    window))

(defun build-quit-keycodes (nk)
  "Collect the keycodes that produce the 'q' keysym, so Alt+q and
   Ctrl+q can be recognised regardless of the server's keymap."
  (with-xneko (nk quit-keycodes)
    (let* ((min-kc  (xcb:conn-min-keycode conn))
           (max-kc  (xcb:conn-max-keycode conn))
           (count   (1+ (- max-kc min-kc)))
           (cookie  (xcb::get-keyboard-mapping conn min-kc count))
           (reply   (xcb::get-keyboard-mapping-reply conn cookie))
           (ks-per  (slot-value reply 'xcb::keysyms-per-keycode))
           (keysyms (slot-value reply 'xcb::keysyms))
           (acc '()))
      (loop for i from 0 below count
            for kc = (+ min-kc i)
            for base = (* i ks-per)
            when (loop for j from 0 below ks-per
                       thereis (let ((ks (elt keysyms (+ base j))))
                                 (or (= ks #x71)   ; 'q'
                                     (= ks #x51)))) ; 'Q'
              do (push kc acc))
      (setf quit-keycodes (nreverse acc)))))


;;; Pointer and focus tracking

(defun query-pointer (nk)
  "Return the pointer's root-relative (values X Y)."
  (with-xneko (nk mouse-x mouse-y)
    (handler-case
        (let* ((cookie (xcb::query-pointer conn window))
               (reply  (xcb::query-pointer-reply conn cookie)))
          (values (slot-value reply 'xcb::root-x)
                  (slot-value reply 'xcb::root-y)))
      (error () (values mouse-x mouse-y)))))

(defun query-focus (nk)
  (with-xneko (nk)
    (handler-case
        (let* ((cookie (xcb::get-input-focus conn))
               (reply  (xcb::get-input-focus-reply conn cookie)))
          (slot-value reply 'xcb::focus))
      (error () 0))))

(defun top-level-of (nk window)
  "Climb the window tree until the parent is the root; return that
   top-level window, or 0 on failure."
  (let ((conn (xact:widget-connection nk)))
    (loop
      (handler-case
          (let* ((cookie (xcb::query-tree conn window))
                 (reply  (xcb::query-tree-reply conn cookie))
                 (root   (slot-value reply 'xcb::root))
                 (parent (slot-value reply 'xcb::parent)))
            (cond
              ((zerop parent) (return 0))
              ((= parent root) (return window))
              (t (setf window parent))))
        (error () (return 0))))))

(defun update-mouse (nk)
  (with-xneko (nk mouse-x mouse-y prev-mouse-x prev-mouse-y target prev-target x-offset y-offset tofocus)
    (multiple-value-bind (mx my) (query-pointer nk)
      (setf prev-mouse-x mouse-x
            prev-mouse-y mouse-y
            prev-target  target
            mouse-x      (+ mx x-offset)
            mouse-y      (+ my y-offset)))
    (when tofocus
      (let ((f (query-focus nk)))
        (setf target (if (and (plusp f) (/= f root))
                           (top-level-of nk f)
                           0))))))


;;; Direction and motion

(defun target-geometry (nk)
  "Return (values X Y WIDTH HEIGHT) of the focus target, *TARGET*, when
   it is viewable and on screen, else NIL.  *TARGET* is a child of the
   root (see TOP-LEVEL-OF), usually the WM's frame, so its GetGeometry
   position is already in root coordinates.  (GetWindowAttributes has no
   position at all: Xlib's XGetWindowAttributes, which oneko.c calls,
   adds a GetGeometry to fill it in.)"
  (with-xneko (nk target)
    (handler-case
        (let* ((gc (xcb::get-geometry conn target))
               (ac (xcb::get-window-attributes conn target))
               (g  (xcb::get-geometry-reply conn gc))
               (a  (xcb::get-window-attributes-reply conn ac))
               (x  (slot-value g 'xcb::x))
               (y  (slot-value g 'xcb::y))
               (w  (slot-value g 'xcb::width))
               (h  (slot-value g 'xcb::height)))
          (and (= (slot-value a 'xcb::map-state) 2) ; IsViewable
               (> (+ x w) 0) (< x width)
               (> (+ y h) 0) (< y height)
               (values x y w h)))
      (error () nil))))

(defun compute-aim-point (nk)
  "Return (values AIM-X AIM-Y) in root coordinates: the mouse, or with
   ToFocus the top edge of the focused window, as oneko.c does it -- the
   cat sits on the window, following the pointer along it but staying
   within its left and right edges.  The point is in the convention
   COMPUTE-MOVE-VECTOR expects (it subtracts half a bitmap width and a
   whole bitmap height)."
  (with-xneko (nk mouse-x mouse-y target x-offset y-offset tofocus)
    (if (and tofocus (plusp target))
        (multiple-value-bind (tx ty tw) (target-geometry nk)
          (if tx
              (values (cond ((< mouse-x (+ tx (/ +bitmap-width+ 2)))
                             (+ tx x-offset (/ +bitmap-width+ 2)))
                            ((> mouse-x (- (+ tx tw) (/ +bitmap-width+ 2)))
                             (- (+ tx tw x-offset) (/ +bitmap-width+ 2)))
                            (t mouse-x))
                      (+ ty y-offset))
              (values mouse-x mouse-y)))
        (values mouse-x mouse-y))))

(defun compute-move-vector (nk)
  "Update *NEKO-MOVE-DX* and *NEKO-MOVE-DY* from the aim point and the
   cat's current position.  The X axis is biased by half a bitmap width,
   the Y axis by a full bitmap height, matching the C original."
  (with-xneko (nk neko-x neko-y neko-move-dx neko-move-dy speed)
    (multiple-value-bind (aim-x aim-y) (compute-aim-point nk)
      (let* ((large-x (float (- aim-x neko-x (/ +bitmap-width+ 2)) 1.0d0))
             (large-y (float (- aim-y neko-y +bitmap-height+) 1.0d0))
             (len (sqrt (+ (* large-x large-x) (* large-y large-y)))))
        (cond
          ((zerop len)
           (setf neko-move-dx 0 neko-move-dy 0))
          ((<= len speed)
           (setf neko-move-dx (round large-x)
                 neko-move-dy (round large-y)))
          (t
           (setf neko-move-dx (round (/ (* speed large-x) len))
                 neko-move-dy (round (/ (* speed large-y) len)))))))))

(defun neko-direction (nk)
  (with-xneko (nk neko-move-dx neko-move-dy neko-state)
    (let ((new-state
            (if (and (zerop neko-move-dx) (zerop neko-move-dy))
                +neko-stop+
                (let* ((large-x (float neko-move-dx 1.0d0))
                       (large-y (float (- neko-move-dy) 1.0d0))
                       (len (sqrt (+ (* large-x large-x) (* large-y large-y))))
                       (sin-theta (/ large-y len)))
                  (if (plusp neko-move-dx)
                      (cond
                        ((> sin-theta *sin-pi-per8-times-3*)     +neko-u-move+)
                        ((> sin-theta *sin-pi-per8*)             +neko-ur-move+)
                        ((> sin-theta (- *sin-pi-per8*))         +neko-r-move+)
                        ((> sin-theta (- *sin-pi-per8-times-3*)) +neko-dr-move+)
                        (t                                       +neko-d-move+))
                      (cond
                        ((> sin-theta *sin-pi-per8-times-3*)     +neko-u-move+)
                        ((> sin-theta *sin-pi-per8*)             +neko-ul-move+)
                        ((> sin-theta (- *sin-pi-per8*))         +neko-l-move+)
                        ((> sin-theta (- *sin-pi-per8-times-3*)) +neko-dl-move+)
                        (t                                       +neko-d-move+)))))))
      (when (/= neko-state new-state)
        (set-neko-state nk new-state)))))

(defun clamp-neko-position (nk)
  (with-xneko (nk neko-x neko-y)
    (setf neko-x (max 0 (min neko-x (- width  +bitmap-width+)))
          neko-y (max 0 (min neko-y (- height +bitmap-height+))))))

(defun neko-in-bounds-p (nk)
  (with-xneko (nk neko-x neko-y)
    (and (>= neko-x 0)
         (>= neko-y 0)
         (<= neko-x (- width  +bitmap-width+))
         (<= neko-y (- height +bitmap-height+)))))


;;; State machine

(defun set-neko-state (nk value)
  (with-xneko (nk neko-state tick-count state-count)
    (setf neko-state   value
          tick-count   0
          state-count  0)))

(defun tick-count-up (nk)
  (with-xneko (nk tick-count state-count)
    (incf tick-count)
    (when (>= tick-count +max-tick+) (setf tick-count 0))
    (when (evenp tick-count)
      (when (< state-count +max-tick+) (incf state-count)))))

(defun neko-move-start-p (nk)
  "True when the pointer has moved appreciably or the target changed
   since the previous tick."
  (with-xneko (nk mouse-x mouse-y prev-mouse-x prev-mouse-y target prev-target idle-space)
    (not (and (<= (- mouse-x idle-space) prev-mouse-x)
              (<= prev-mouse-x (+ mouse-x idle-space))
              (<= (- mouse-y idle-space) prev-mouse-y)
              (<= prev-mouse-y (+ mouse-y idle-space))
              (= prev-target target)))))

(declaim (inline neko-dont-move-p))
(defun neko-dont-move-p (nk)
  (with-xneko (nk neko-x neko-y neko-last-x neko-last-y)
    (and (= neko-x neko-last-x) (= neko-y neko-last-y))))

(defun neko-think-draw (nk)
  (with-xneko (nk sprites neko-x neko-y neko-move-dx neko-move-dy neko-state tick-count state-count mouse-y target tofocus last-sprite-name)
    (compute-move-vector nk)
  
    ;; Choose the sprite frame: slower for sleep.
    (let* ((frame (if (= neko-state +neko-sleep+)
                      (logand (ash tick-count -2) 1)
                      (logand tick-count 1)))
           (name  (if (zerop frame)
                      (aref +state-frame-0+ neko-state)
                      (aref +state-frame-1+ neko-state)))
           (sprite (gethash name sprites)))
      (when sprite
        (setf last-sprite-name name)
        (draw-neko nk neko-x neko-y sprite)))
  
    (tick-count-up nk)
  
    (case neko-state
      (#.+neko-stop+
       (cond
         ((neko-move-start-p nk)                    (set-neko-state nk +neko-awake+))
         ((< state-count +neko-stop-time+)     nil)
         ((and (minusp neko-move-dx) (<= neko-x 0))
          (set-neko-state nk +neko-l-togi+))
         ((and (plusp neko-move-dx) (>= neko-x (- width +bitmap-width+)))
          (set-neko-state nk +neko-r-togi+))
         ((or (and (minusp neko-move-dy) (<= neko-y 0))
              (and tofocus (plusp target) (> neko-y mouse-y)))
          (set-neko-state nk +neko-u-togi+))
         ((or (and (plusp neko-move-dy)
                   (>= neko-y (- height +bitmap-height+)))
              (and tofocus (plusp target)
                   (< neko-y (- mouse-y +bitmap-height+))))
          (set-neko-state nk +neko-d-togi+))
         (t (set-neko-state nk +neko-jare+))))
  
      (#.+neko-jare+
       (cond
         ((neko-move-start-p nk)                 (set-neko-state nk +neko-awake+))
         ((< state-count +neko-jare-time+)  nil)
         (t                                   (set-neko-state nk +neko-kaki+))))
  
      (#.+neko-kaki+
       (cond
         ((neko-move-start-p nk)                 (set-neko-state nk +neko-awake+))
         ((< state-count +neko-kaki-time+)  nil)
         (t                                   (set-neko-state nk +neko-akubi+))))
  
      (#.+neko-akubi+
       (cond
         ((neko-move-start-p nk)                 (set-neko-state nk +neko-awake+))
         ((< state-count +neko-akubi-time+) nil)
         (t                                   (set-neko-state nk +neko-sleep+))))
  
      (#.+neko-sleep+
       (when (neko-move-start-p nk)
         (set-neko-state nk +neko-awake+)))
  
      (#.+neko-awake+
       (when (>= state-count +neko-awake-time+)
         (neko-direction nk)))
  
      ((#.+neko-u-move+ #.+neko-d-move+ #.+neko-l-move+ #.+neko-r-move+
        #.+neko-ul-move+ #.+neko-ur-move+ #.+neko-dl-move+ #.+neko-dr-move+)
       (incf neko-x neko-move-dx)
       (incf neko-y neko-move-dy)
       (neko-direction nk)
       (unless (neko-in-bounds-p nk)
         (clamp-neko-position nk)
         (when (neko-dont-move-p nk)
           (set-neko-state nk +neko-stop+))))
  
      ((#.+neko-u-togi+ #.+neko-d-togi+ #.+neko-l-togi+ #.+neko-r-togi+)
       (cond
         ((neko-move-start-p nk)                 (set-neko-state nk +neko-awake+))
         ((< state-count +neko-togi-time+)  nil)
         (t                                   (set-neko-state nk +neko-kaki+))))
  
      (t (set-neko-state nk +neko-stop+)))))


;;; Drawing

(defun draw-neko (nk x y sprite)
  (with-xneko (nk sprite-gc shape-p neko-last-x neko-last-y last-shape-mask dont-mapped)
    (let ((mask (xcb-demos.sprites:sprite-mask sprite)))
      ;; The cat is still most of the time; don't move it to where it is.
      (unless (and (eql x neko-last-x) (eql y neko-last-y))
        (xcb::configure-window conn window
                               (logior +config-window-x+
                                       +config-window-y+)
                               :x x :y y))

      ;; Shape mask travels with the window, so only reapply it when the
      ;; sprite changes.
      (when (and shape-p (not (eql mask last-shape-mask)))
        (xcb-shape::mask conn +shape-so-set+ +shape-sk-bounding+
                         window 0 0 mask)
        (setf last-shape-mask mask))

      (when dont-mapped
        (xcb::map-window conn window)
        (setf dont-mapped nil))

      (xcb-demos.sprites:draw-sprite conn window sprite-gc sprite 0 0)

      (setf neko-last-x x
            neko-last-y y))))

(defun redraw-neko (nk)
  (with-xneko (nk sprite-gc sprites dont-mapped last-sprite-name)
    ;; Repaint the last drawn sprite, as oneko.c's RedrawNeko does.
    ;; Guarded on the sprite, not the shape mask, which stays NIL without
    ;; SHAPE.
    (when (and last-sprite-name (not dont-mapped))
      (let ((sprite (gethash last-sprite-name sprites)))
        (when sprite
          (xcb-demos.sprites:draw-sprite conn window sprite-gc sprite 0 0))))))


;;; Event handling

(defun quit-key-p (nk ev)
  (with-xneko (nk quit-keycodes)
    (let ((kc    (slot-value ev 'xcb::detail))
          (state (slot-value ev 'xcb::state)))
      (and (member kc quit-keycodes)
           (plusp (logand state (logior +mod-mask-control+ +mod-mask-n1+)))))))

(defun handle-event (nk ev)
  "Return T when the event loop should exit."
  (with-xneko (nk raise-delay)
    (typecase ev
      (xcb::expose             (redraw-neko nk) nil)
      (xcb::key-press          (quit-key-p nk ev))
      ;; As oneko.c: raise when obscured, but at most once per
      ;; +RAISE-WAIT+ ticks, so two raising windows cannot fight forever.
      (xcb::visibility-notify  (when (zerop raise-delay)
                                 (xcb::configure-window conn window
                                                        +config-window-stack-mode+
                                                        :stack-mode +stack-mode-above+)
                                 (setf raise-delay +raise-wait+))
                               nil)
      (t nil))))


;;; Event loop

(defun event-loop (nk)
  (with-xneko (nk interval-us raise-delay)
    (let ((next-tick (+ (get-internal-real-time)
                        (round (* interval-us
                                  (/ internal-time-units-per-second
                                     1000000)))))
          (conn conn))
      (loop
        ;; XD:STOP, through XACT:REQUEST-CLOSE.
        (when (xact:toplevel-closing-p nk)
          (return))
        (loop for ev = (xcb:poll-for-event conn)
              while ev
              do (when (handle-event nk ev)
                   (return-from event-loop nil)))
        (when (>= (get-internal-real-time) next-tick)
          (update-mouse nk)
          (neko-think-draw nk)
          (when (plusp raise-delay) (decf raise-delay))
          (setf next-tick (+ (get-internal-real-time)
                             (round (* interval-us
                                       (/ internal-time-units-per-second
                                          1000000))))))
        (xcb:wait-for-x-event-or-timeout conn 0.005)
        ;;(sleep 0.005)
        ))))


;;; Setup and teardown

(defun setup-shape-extension-p (nk)
  (with-xneko (nk)
    (let ((info (handler-case (xcb:ensure-extension conn "XCB-SHAPE")
                  (error () nil))))
      (and info (getf info :present) t))))

(defun variant-default (variant key)
  (getf (cdr (assoc variant *variant-defaults*)) key))


;;; Entry points

(defun xneko (&rest options)
  "Run the XNeko demo.  OPTIONS are the demo's declared options (see
   its DEFINE-DEMO form), e.g. (xneko :variant :tora)."
  (apply #'run options))

(defun make-xneko (d conn)
  "A fresh XNEKO for one run on CONN with D's options, the variant's
   defaults filled in where they are NIL."
  (let ((nk (xd:make-application d conn)))
    (with-xneko (nk variant speed idle-space interval-us x-offset y-offset)
      (setf speed       (or speed       (variant-default variant :speed))
            idle-space  (or idle-space  (variant-default variant :idle))
            interval-us (or interval-us (variant-default variant :interval))
            x-offset    (or x-offset    (variant-default variant :off-x))
            y-offset    (or y-offset    (variant-default variant :off-y))))
    nk))

(defun setup-xneko (nk)
  "Make everything NK's run needs: colours, cursor, cat window, sprites.
   Whatever is made is recorded in NK as it is made, so TEARDOWN-XNEKO
   frees it even when a later step fails."
  (with-xneko (nk loader-gc cursor sprite-gc shape-p shape foreground background fg-pixel fg-rgb bg-pixel bg-rgb root-cursor root-cursor-set verbose neko-x neko-y)
    ;; Colours.
    (multiple-value-bind (pixel rgb) (alloc-colour nk foreground)
      (setf fg-pixel pixel fg-rgb rgb))
    (multiple-value-bind (pixel rgb) (alloc-colour nk background :default-pixel 1)
      (setf bg-pixel pixel bg-rgb rgb))
    ;; SHAPE detection.
    (setf shape-p (and shape (setup-shape-extension-p nk)))
    (when (and shape (not shape-p) verbose)
      (format t "~&SHAPE extension not available; cat will be rectangular.~%"))
    ;; The cursor before the window, which is created with it.
    (setf loader-gc (xcb-demos.xbm:make-xbm-loader-gc conn root)
          cursor    (make-neko-cursor nk))
    (setup-neko-window nk)
    (xact:realize nk)
    (setf sprite-gc (xcb-demos.sprites:make-sprite-gc conn window fg-pixel
                                                      :background bg-pixel))
    (load-all-sprites nk)
    (build-quit-keycodes nk)
    (when (and cursor root-cursor)
      (xcb::change-window-attributes conn root +cw-cursor+ :cursor cursor)
      (setf root-cursor-set t))
    ;; Initial cat position: near the centre, as in the C original.
    (setf neko-x (floor (- width  (/ +bitmap-width+ 2)) 2)
          neko-y (floor (- height (/ +bitmap-height+ 2)) 2))
    nk))

(defun teardown-xneko (nk)
  "Free everything SETUP-XNEKO made, however far it got."
  (with-xneko (nk sprites sprite-gc cursor loader-gc root-cursor-set)
    (xcb-demos:ignoring-errors
      ;; Give the root its default cursor back before freeing ours
      ;; (oneko.c's RestoreCursor).
      (when root-cursor-set
        (xcb::change-window-attributes conn root +cw-cursor+ :cursor 0))
      (xact:unrealize nk)
      (when sprites
        (maphash (lambda (name sprite)
                   (declare (ignore name))
                   (xcb-demos.sprites:free-sprite conn sprite))
                 sprites))
      (when sprite-gc
        (xcb::free-gc conn sprite-gc))
      (when cursor
        (xcb::free-cursor conn cursor))
      (when loader-gc
        (xcb::free-gc conn loader-gc)))))

(defun run-xneko (d conn)
  "Run the XNeko demo body: one XNEKO, set up, run and torn down.  The
   demo instance D is only told about the window and asked whether to
   stop."
  (let ((nk (make-xneko d conn)))
    (unwind-protect
         (progn
           (setup-xneko nk)
           (with-xneko (nk variant verbose speed idle-space interval-us shape-p tofocus)
             (when verbose
               (format t "~&Variant: ~A  Speed: ~A  Idle: ~A  Interval: ~A us~%"
                       variant speed idle-space interval-us)
               (format t "  Shape: ~:[off~;on~]  ToFocus: ~:[off~;on~]~%"
                       shape-p tofocus)
               (format t "~&Controls:~%")
               (format t "  Alt+q  or  Ctrl+q    exit~%")))
           (event-loop nk))
      (teardown-xneko nk))))
