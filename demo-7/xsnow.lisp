;;; xsnow.lisp — XSnow port for CLXCB.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; A port of the classic xsnow demo, drawn on the root window (or a
;;; transparent overlay when a compositor is running).  The event loop
;;; is driven by xact.

(xd:define-demo :xsnow
    (:resource-class "XSnow"
     :app xsnow-widget
     :options (:verbose :accrate :santa :santa-speed :santa-rate :santa-timeout))
  (format t "~&========================================~%")
  (format t "   CLXCB XSnow (demo7)                 ~%")
  (format t "========================================~%")
  (run-xsnow d conn))

(defconstant +gravity+                 0.14d0)
(defconstant +drag+                    0.06d0)
(defconstant +max-vy+                  7.0d0)
(defconstant +column-width+            4)
(defconstant +min-flakes+              10)
(defconstant +max-flakes+              900)
(defconstant +flake-step+              25)
(defconstant +tick-seconds+            0.033d0)
(defconstant +flake-landing-amount+    0.25d0)
(defconstant +santa-base-speed+        4.0d0)
(defconstant +santa-update-every+      3)
(defconstant +skyline-refresh-ticks+   60)
(defconstant +skyline-min-dirty-ticks+ 8)
(defconstant +min-window-top+          40)
(defconstant +min-window-width+        60)
(defconstant +min-window-height+       40)
;; How deep snow gets on windows and on the ground, as in the C original
;; (INITWINSNOWDEPTH and INITSCRSNOWDEPTH).
(defconstant +max-window-snow+       15)
(defconstant +max-ground-snow+       50)

(defparameter *pixmap-dir*
  (asdf:system-relative-pathname "clxcb-demos" "demo-7/sprites/"))

(defparameter *santa-files-right*
  '("BigSantaRudolf1.XPM" "BigSantaRudolf2.XPM"
    "BigSantaRudolf3.XPM" "BigSantaRudolf4.XPM"))

(defparameter *santa-files-left*
  '("BigSantaRudolf1-left-facing.XPM" "BigSantaRudolf2-left-facing.XPM"
    "BigSantaRudolf3-left-facing.XPM" "BigSantaRudolf4-left-facing.XPM"))

(defstruct (flake (:constructor %make-flake))
  (x 0.0d0 :type double-float)
  (y 0.0d0 :type double-float)
  (vx 0.0d0 :type double-float)
  (vy 0.0d0 :type double-float)
  (kind 0 :type fixnum))

(defclass xsnow-widget (xd:application)
  ;; The window is the one the snow falls on: the virtual root, where the
  ;; WM has one (see XD:VIRTUAL-ROOT).  Its size is the screen's.
  ((verbose       :initarg :verbose       :initform nil :type boolean :reader xsnow-verbose
                  :documentation "Print diagnostics.")
   (accrate       :initarg :accrate       :initform 1.0d0 :type (real (0)) :reader xsnow-accrate
                  :documentation "Rate at which snow piles up on windows and the ground.")
   (bg-pixel      :initform 0 :accessor xsnow-bg-pixel)
   (compositing   :initform nil :accessor xsnow-compositing)
   (present-window :initform nil :accessor xsnow-present-window)
   (overlay       :initform nil :accessor xsnow-overlay)
   (overlay-colormap :initform nil :accessor xsnow-overlay-colormap)
   (background    :initform nil :accessor xsnow-background)
   (canvas        :initform nil :accessor xsnow-canvas)
   (canvas-gc     :initform nil :accessor xsnow-canvas-gc)
   (sprite-gc     :initform nil :accessor xsnow-sprite-gc)
   (flake-offsets :initform nil :accessor xsnow-flake-offsets)
   (tree-offsets  :initform nil :accessor xsnow-tree-offsets)
   (flakes        :initform nil :accessor xsnow-flakes)
   (flake-count   :initform 0   :accessor xsnow-flake-count)
   (wind          :initform 0.0d0 :accessor xsnow-wind)
   (wind-enabled  :initform t     :accessor xsnow-wind-enabled)
   (wind-until    :initform 0     :accessor xsnow-wind-until)
   (wind-sign     :initform 1     :accessor xsnow-wind-sign)
   (snow-heights  :initform nil :accessor xsnow-snow-heights)
   (window-snow   :initform nil :accessor xsnow-window-snow)
   ;; Fallen snow is drawn as in the C original: every flake that lands
   ;; is stamped where it lands, into SNOW-MASK, and the mask is filled
   ;; white each frame.  The heights above only say where flakes land.
   (snow-mask     :initform nil :accessor xsnow-snow-mask)
   (mask-gc       :initform nil :accessor xsnow-mask-gc)
   (mask-clear-gc :initform nil :accessor xsnow-mask-clear-gc)
   (stamps        :initform '() :accessor xsnow-stamps
                  :documentation "Points landed since the last frame, for SNOW-MASK.")
   (clears        :initform '() :accessor xsnow-clears
                  :documentation "Rectangles of SNOW-MASK to clear: snow on windows that moved.")
   (bodies        :initform '() :accessor xsnow-bodies
                  :documentation "Rectangles of solid snow landed since the last frame, for SNOW-MASK.")
   (drift         :initform nil :accessor xsnow-drift
                  :documentation "Each column's share of the maximum snow depth.")
   (flake-sizes   :initform nil :accessor xsnow-flake-sizes
                  :documentation "(WIDTH . HEIGHT) of each flake sprite.")
   (skyline       :initform nil :accessor xsnow-skyline)
   (column-count  :initform 0   :accessor xsnow-column-count)
   (skyline-dirty :initform t   :accessor xsnow-skyline-dirty)
   (ticks-since-refresh :initform 0 :accessor xsnow-ticks-since-refresh)
   (santa-enabled :initarg :santa         :initform t :type boolean :reader xsnow-santa-enabled
                  :documentation "Let Santa fly.")
   (santa-speed   :initarg :santa-speed   :initform 1.0d0 :type (real (0)) :reader xsnow-santa-speed
                  :documentation "Santa's speed, relative to the default.")
   (santa-rate    :initarg :santa-rate    :initform 1.0d0 :type (real 0 1) :reader xsnow-santa-rate
                  :documentation "Chance, from 0 to 1, that Santa flies again after each wait.")
   (santa-timeout :initarg :santa-timeout :initform 0.0d0 :type (real 0) :reader xsnow-santa-timeout
                  :documentation "Seconds to wait between Santa's runs; 0 to fly again at once.")
   (santa-frames-right :initform nil :accessor xsnow-santa-frames-right)
   (santa-frames-left  :initform nil :accessor xsnow-santa-frames-left)
   (santa-direction :initform :right :accessor xsnow-santa-direction)
   (santa-width   :initform 0 :accessor xsnow-santa-width)
   (santa-height  :initform 0 :accessor xsnow-santa-height)
   (santa-x       :initform 0.0d0 :accessor xsnow-santa-x)
   (santa-y       :initform 0.0d0 :accessor xsnow-santa-y)
   (santa-vy      :initform 1.0d0 :accessor xsnow-santa-vy)
   (santa-frame   :initform 0 :accessor xsnow-santa-frame)
   (santa-tick    :initform 0 :accessor xsnow-santa-tick)
   (santa-gcs     :initform (make-hash-table :test 'eql)
                  :accessor xsnow-santa-gcs)
   (santa-state   :initform :flying :accessor xsnow-santa-state)
   (santa-next-attempt :initform 0 :accessor xsnow-santa-next-attempt)
   (keycode-map   :initform (make-hash-table) :accessor xsnow-keycode-map))
  (:default-initargs :kind :root))

;;; Physics

(defun random-flake-kind (w)
  (if (xsnow-flake-offsets w)
      (random (length (xsnow-flake-offsets w)))
      0))

(defun flake-respawn (w f &optional (above-screen t))
  (let ((width  (float (xact:widget-width w) 1.0d0))
        (height (float (xact:widget-height w) 1.0d0)))
    (setf (flake-x f) (random width)
          (flake-y f) (if above-screen
                          (- -2.0d0 (random 40.0d0))
                          (random height))
          (flake-vx f) (- (random 0.6d0) 0.3d0)
          (flake-vy f) (+ 0.4d0 (random 2.0d0))
          (flake-kind f) (random-flake-kind w)))
  f)

(defun make-flake-vector (w n)
  (let ((v (make-array n)))
    (dotimes (i n)
      (setf (aref v i) (flake-respawn w (%make-flake) nil)))
    v))

;; Each column's snow stops at its own depth, a fraction (DRIFT) of the
;; maximum, so that the surface stays uneven, like drifts, instead of
;; levelling off flat.

(defun snow-add-at-bottom (w col amount)
  (setf (aref (xsnow-snow-heights w) col)
        (min (+ (aref (xsnow-snow-heights w) col) amount)
             (* +max-ground-snow+ (aref (xsnow-drift w) col)))))

(defun snow-add-on-window (w col amount)
  (let* ((skyline (aref (xsnow-skyline w) col))
         (cap (max 0.0d0 (min skyline (* +max-window-snow+ (aref (xsnow-drift w) col)))))
         (new (+ (aref (xsnow-window-snow w) col) amount)))
    (setf (aref (xsnow-window-snow w) col)
          (max 0.0d0 (min new cap)))))

(defun make-drift (count)
  "COUNT depth fractions between 0.45 and 1 that wander slowly from
   column to column."
  (let ((v (make-array count :element-type 'double-float))
        (d 0.75d0))
    (dotimes (i count v)
      (setf d (max 0.45d0 (min 1.0d0 (+ d (- (random 0.16d0) 0.08d0))))
            (aref v i) d))))

(defun column-surface (w col above)
  "The y where a flake in column COL whose bottom was at ABOVE lands,
   and whether that is on a window (true) or on the ground.  A flake
   already below a window's top falls on behind it, to the ground."
  (let* ((height (float (xact:widget-height w) 1.0d0))
         (skyline (aref (xsnow-skyline w) col))
         (bottom-top (- height (aref (xsnow-snow-heights w) col))))
    (if (and (>= skyline +min-window-top+)
             (< skyline height))
        (let ((window-top (- skyline (aref (xsnow-window-snow w) col))))
          (if (and (< window-top bottom-top) (< above window-top))
              (values window-top t)
              (values bottom-top nil)))
        (values bottom-top nil))))

(defun deposit-snow (w x kind col landing on-window)
  "A flake of KIND at X, in column COL, has landed on the surface at
   LANDING, on a window or on the ground: stamp it there, fill in the
   snow under it, and raise the surface."
  (destructuring-bind (fw . fh) (aref (xsnow-flake-sizes w) kind)
    (let* ((px (round x))
           (py (- (round landing) fh -1))   ; sunk in by a pixel
           (amount (* +flake-landing-amount+ (xsnow-accrate w)))
           (skyline (xsnow-skyline w))
           (col0 (max 0 (floor px +column-width+)))
           (col1 (min (1- (xsnow-column-count w)) (floor (+ px fw -1) +column-width+)))
           (base (if on-window
                     (round (aref skyline col))
                     (xact:widget-height w)))
           (body-top (+ py (floor fh 2))))
      ;; On a window, only the columns on that window, so that a flake on
      ;; its edge does not fill or raise the columns beside it.
      (when on-window
        (loop while (and (< col0 col) (/= (aref skyline col0) (aref skyline col)))
              do (incf col0))
        (loop while (and (> col1 col) (/= (aref skyline col1) (aref skyline col)))
              do (decf col1)))
      (dolist (o (aref (xsnow-flake-offsets w) kind))
        (push (make-instance 'xcb::point :x (+ px (car o)) :y (+ py (cdr o)))
              (xsnow-stamps w)))
      ;; The stamped flakes make the surface; below them the snow is solid.
      (let ((x0 (max px (* col0 +column-width+)))
            (x1 (min (+ px fw) (* (1+ col1) +column-width+))))
        (when (and (< body-top base) (< x0 x1))
          (push (make-instance 'xcb::rectangle :x x0 :y body-top
                                               :width (- x1 x0) :height (- base body-top))
                (xsnow-bodies w))))
      (loop for col from col0 to col1
            do (if on-window
                   (snow-add-on-window w col amount)
                   (snow-add-at-bottom w col amount))))))

(defun paint-snow-at-bottom (w)
  "A thin layer of snow on the ground to start with, as the C original
   paints."
  (let ((kinds (length (xsnow-flake-offsets w)))
        (width (xact:widget-width w)))
    (dotimes (i (* 2 (xsnow-column-count w)))
      (let* ((kind (random kinds))
             (x (random width))
             (col (min (1- (xsnow-column-count w)) (floor x +column-width+))))
        (when (< (aref (xsnow-snow-heights w) col) 8.0d0)
          (deposit-snow w x kind col
                        (- (xact:widget-height w) (aref (xsnow-snow-heights w) col))
                        nil))))))

(defun schedule-next-wind-change (w)
  (setf (xsnow-wind-until w)
        (+ (get-internal-real-time)
           (round (* internal-time-units-per-second
                     (+ 2.0 (random 5.0)))))))

(defun update-wind (w)
  (when (and (xsnow-wind-enabled w)
             (>= (get-internal-real-time) (xsnow-wind-until w)))
    (let ((roll (random 100)))
      (cond
        ((< roll 30) (setf (xsnow-wind w) 0.0d0))
        ((< roll 65) (setf (xsnow-wind w) (* 0.10d0 (xsnow-wind-sign w))))
        (t           (setf (xsnow-wind w) (* 0.22d0 (xsnow-wind-sign w))))))
    (when (< (random 100) 40)
      (setf (xsnow-wind-sign w) (- (xsnow-wind-sign w))))
    (schedule-next-wind-change w)))

(defun update-flake (w f)
  (when (xsnow-wind-enabled w)
    (incf (flake-vx f) (xsnow-wind w)))
  (setf (flake-vx f) (* (flake-vx f) (- 1.0d0 +drag+)))
  (incf (flake-vy f) +gravity+)
  (when (> (flake-vy f) +max-vy+)
    (setf (flake-vy f) +max-vy+))
  (incf (flake-x f) (flake-vx f))
  (incf (flake-y f) (flake-vy f))
  (let ((width (float (xact:widget-width w) 1.0d0)))
    (cond
      ((< (flake-x f) 0.0d0) (incf (flake-x f) width))
      ((>= (flake-x f) width) (decf (flake-x f) width))))
  ;; A flake lands when its bottom, below its middle, crosses the
  ;; surface of the snow on a window or on the ground.
  (let* ((height (float (xact:widget-height w) 1.0d0))
         (size (aref (xsnow-flake-sizes w) (flake-kind f)))
         (col (min (1- (xsnow-column-count w))
                   (max 0 (truncate (+ (flake-x f) (/ (car size) 2))
                                    +column-width+))))
         (bottom (+ (flake-y f) (cdr size)))
         (prev-bottom (- bottom (flake-vy f))))
    (multiple-value-bind (landing on-window) (column-surface w col prev-bottom)
      (cond
        ((and (>= bottom landing)
              (< prev-bottom landing))
         (deposit-snow w (flake-x f) (flake-kind f) col landing on-window)
         ;; As in the C original, a flake that lands on a window falls on
         ;; behind it, so the ground under windows gets its snow too.
         (unless on-window
           (flake-respawn w f)))
      ;; A flake that was already below its landing line -- it started
      ;; in a window's column, or a window or the pile rose above it --
      ;; never crosses it, and would fall forever: start it again once
      ;; it is off the screen, or the snow runs out.
        ((>= (flake-y f) height)
         (flake-respawn w f))))))

(defun xsnow-update (w)
  (incf (xsnow-ticks-since-refresh w))
  (when (or (and (xsnow-skyline-dirty w)
                 (>= (xsnow-ticks-since-refresh w) +skyline-min-dirty-ticks+))
            (>= (xsnow-ticks-since-refresh w) +skyline-refresh-ticks+))
    (refresh-skyline w)
    (setf (xsnow-skyline-dirty w) nil
          (xsnow-ticks-since-refresh w) 0))
  (update-wind w)
  (dotimes (i (xsnow-flake-count w))
    (update-flake w (aref (xsnow-flakes w) i)))
  (when (xsnow-santa-enabled w)
    (incf (xsnow-santa-tick w))
    (when (>= (xsnow-santa-tick w) +santa-update-every+)
      (setf (xsnow-santa-tick w) 0)
      (update-santa w))))

;;; XBM sprites

(defun xbm->offsets (bytes width height)
  (let ((row-bytes (ceiling width 8))
        (offsets '()))
    (dotimes (row height)
      (dotimes (col width)
        (let* ((byte-idx (+ (* row row-bytes) (ash col -3)))
               (bit-idx  (- 7 (logand col 7)))
               (byte     (if (< byte-idx (length bytes))
                             (aref bytes byte-idx)
                             0))
               (bit      (ldb (byte 1 bit-idx) byte)))
          (when (= bit 1)
            (push (cons col row) offsets)))))
    (nreverse offsets)))

(defun load-xbm-offsets (path)
  (multiple-value-bind (w h bytes) (xcb-demos.xbm:read-xbm path)
    (xbm->offsets bytes w h)))

(defun load-all-sprites (w)
  (let* ((all  (xcb-demos.xbm:xbm-files *pixmap-dir*))
         (snow (remove-if-not
                (lambda (p) (search "snow" (file-namestring p))) all))
         (tree (remove-if-not
                (lambda (p) (search "tannenbaum" (file-namestring p))) all)))
    (unless snow (error "No snow*.xbm in ~A" *pixmap-dir*))
    (setf (xsnow-flake-offsets w) (make-array (length snow))
          (xsnow-flake-sizes w) (make-array (length snow)))
    (loop for path in snow
          for i from 0
          do (multiple-value-bind (fw fh bytes) (xcb-demos.xbm:read-xbm path)
               (setf (aref (xsnow-flake-offsets w) i) (xbm->offsets bytes fw fh)
                     (aref (xsnow-flake-sizes w) i) (cons fw fh))))
    (setf (xsnow-tree-offsets w) (make-array (length tree)))
    (loop for path in tree
          for i from 0
          do (setf (aref (xsnow-tree-offsets w) i)
                   (load-xbm-offsets path)))
    (when (xsnow-verbose w)
      (format t "~&Loaded ~D snowflake, ~D tree sprite~:P.~%"
              (length snow) (length tree)))))

;;; XPM sprites (Santa)

(defun xpm-frame->color-groups (width colors pixel-rows)
  (let ((groups (make-hash-table)))
    (loop for row in pixel-rows
          for y from 0
          do (loop for x from 0 below width
                   for rgb = (gethash (char row x) colors)
                   when rgb
                     do (push (cons x y) (gethash rgb groups))))
    (loop for rgb being the hash-keys of groups using (hash-value offsets)
          collect (cons rgb offsets))))

(defun load-frame-set (w files)
  (let ((frames (make-array (length files))))
    (loop for name in files
          for i from 0
          do (multiple-value-bind (wd ht colors rows)
                 (xcb-demos.xpm:parse-xpm (merge-pathnames name *pixmap-dir*))
               (setf (xsnow-santa-width w) wd
                     (xsnow-santa-height w) ht)
               (setf (aref frames i)
                     (xpm-frame->color-groups wd colors rows))))
    frames))

(defun load-santa-frames (w)
  (setf (xsnow-santa-frames-right w) (load-frame-set w *santa-files-right*)
        (xsnow-santa-frames-left w)  (load-frame-set w *santa-files-left*))
  (when (xsnow-verbose w)
    (format t "~&Loaded Santa: ~D frame~:P per direction, ~Dx~D~%"
            (length (xsnow-santa-frames-right w))
            (xsnow-santa-width w) (xsnow-santa-height w))))

(defun santa-current-frames (w)
  (if (eq (xsnow-santa-direction w) :right)
      (xsnow-santa-frames-right w)
      (xsnow-santa-frames-left w)))

(defun santa-respawn (w)
  (setf (xsnow-santa-direction w) (if (< (random 1.0d0) 0.5d0) :right :left))
  (let ((width  (xact:widget-width w))
        (height (xact:widget-height w)))
    (setf (xsnow-santa-x w)
          (if (eq (xsnow-santa-direction w) :right)
              (- (float (xsnow-santa-width w) 1.0d0))
              (float width 1.0d0))
          (xsnow-santa-y w)
          (float (+ 40 (random (max 1 (truncate height 3)))) 1.0d0)
          (xsnow-santa-vy w) 1.0d0
          (xsnow-santa-frame w) 0
          (xsnow-santa-state w) :flying)))

(defun santa-schedule-next-run (w)
  (if (zerop (xsnow-santa-timeout w))
      (santa-respawn w)
      (setf (xsnow-santa-state w) :waiting
            (xsnow-santa-next-attempt w)
            (+ (get-internal-real-time)
               (round (* (xsnow-santa-timeout w)
                         internal-time-units-per-second))))))

(defun maybe-launch-santa (w)
  (when (>= (get-internal-real-time) (xsnow-santa-next-attempt w))
    (if (<= (random 1.0d0) (xsnow-santa-rate w))
        (santa-respawn w)
        (santa-schedule-next-run w))))

(defun update-santa (w)
  (ecase (xsnow-santa-state w)
    (:waiting (maybe-launch-santa w))
    (:flying
     (let ((dx (* +santa-base-speed+ (xsnow-santa-speed w)
                  (if (eq (xsnow-santa-direction w) :right) 1.0d0 -1.0d0))))
       (incf (xsnow-santa-x w) (+ dx (xsnow-wind w))))
     (when (> (random 10) 3)
       (incf (xsnow-santa-y w) (xsnow-santa-vy w)))
     (when (< (xsnow-santa-y w) 0.0d0)
       (setf (xsnow-santa-y w) 0.0d0))
     (when (> (random 100) 80)
       (setf (xsnow-santa-vy w) (- (xsnow-santa-vy w))))
     (if (ecase (xsnow-santa-direction w)
           (:right (>= (xsnow-santa-x w)
                       (float (xact:widget-width w) 1.0d0)))
           (:left  (<= (xsnow-santa-x w)
                       (- (float (xsnow-santa-width w) 1.0d0)))))
         (santa-schedule-next-run w)
         (setf (xsnow-santa-frame w)
               (mod (1+ (xsnow-santa-frame w))
                    (length (santa-current-frames w))))))))

(defun santa-gc-for (w rgb)
  (or (gethash rgb (xsnow-santa-gcs w))
      (setf (gethash rgb (xsnow-santa-gcs w))
            (let ((conn (xact:widget-connection w))
                  (gc (xcb:generate-id (xact:widget-connection w))))
              (xcb::create-gc conn gc (xsnow-canvas w)
                              +gc-foreground+
                              :foreground (opaque w rgb))
              gc))))

(defun free-santa-gcs (w)
  (maphash (lambda (_ gc)
             (declare (ignore _))
             (ignore-errors (xcb::free-gc (xact:widget-connection w) gc)))
           (xsnow-santa-gcs w))
  (clrhash (xsnow-santa-gcs w)))

(defun draw-santa (w)
  (when (and (xsnow-santa-enabled w)
             (santa-current-frames w)
             (eq (xsnow-santa-state w) :flying))
    (let ((px (round (xsnow-santa-x w)))
          (py (round (xsnow-santa-y w)))
          (conn (xact:widget-connection w)))
      (dolist (group (aref (santa-current-frames w) (xsnow-santa-frame w)))
        (destructuring-bind (rgb . offsets) group
          (let ((gc (santa-gc-for w rgb)))
            (xcb::poly-point
             conn +coord-mode-origin+ (xsnow-canvas w) gc
             (mapcar (lambda (o)
                       (make-instance 'xcb::point
                                      :x (+ px (car o))
                                      :y (+ py (cdr o))))
                     offsets))))))))

;;; Compositor / ARGB visual detection

(defun compositor-running-p (conn)
  (handler-case
      (let* ((atom   (xcb:intern-atom-id conn "_NET_WM_CM_S0"))
             (cookie (xcb::get-selection-owner conn atom))
             (reply  (xcb::get-selection-owner-reply conn cookie)))
        (plusp (slot-value reply 'xcb::owner)))
    (error () nil)))

(defun find-argb32-visual (screen)
  (let ((depths (coerce (slot-value screen 'xcb::allowed-depths) 'list)))
    (dolist (d depths)
      (when (= (slot-value d 'xcb::depth) 32)
        (let ((visuals (coerce (slot-value d 'xcb::visuals) 'list)))
          (dolist (v visuals)
            (when (= (slot-value v 'xcb::class) +visual-class-true-color+)
              (return-from find-argb32-visual
                (slot-value v 'xcb::visual-id))))))))
  nil)

;;; Window-tree queries

(defun raise-overlay (w)
  (when (and (xsnow-compositing w) (xsnow-overlay w))
    (ignore-errors
     (xcb::configure-window (xact:widget-connection w) (xsnow-overlay w)
                            +config-window-stack-mode+
                            :stack-mode +stack-mode-above+))))

(defun refresh-skyline (w)
  (raise-overlay w)
  (let ((conn (xact:widget-connection w))
        (root (xact:widget-window w))
        (height (xact:widget-height w)))
    (handler-case
        (let* ((windows '())    ; windows snow can land on
               (stack '())      ; every viewable window, which may hide their tops
               (screen-h (float height 1.0d0))
               (cookie   (xcb::query-tree conn root))
               (reply    (xcb::query-tree-reply conn cookie))
               (children (slot-value reply 'xcb::children))
               (child-list (if (vectorp children)
                               (coerce children 'list)
                               children)))
          (when (and child-list (plusp (length child-list)))
            (let* ((attr-cookies
                     (loop for child in child-list
                           collect (cons child
                                         (xcb::get-window-attributes
                                          conn child))))
                   (matching-children
                     (loop for (child . ac) in attr-cookies
                           when (handler-case
                                    (let* ((ar (xcb::get-window-attributes-reply
                                                conn ac))
                                           (map-state
                                             (slot-value ar 'xcb::map-state))
                                           (override
                                             (slot-value ar
                                                         'xcb::override-redirect)))
                                      (and (= map-state 2)
                                           (zerop override)))
                                  (error () nil))
                             collect child))
                   (geom-cookies
                     (loop for child in matching-children
                           collect (cons child
                                         (xcb::get-geometry conn child)))))
              ;; QueryTree lists the children bottom to top, so RANK is
              ;; each window's place in the stacking order.
              (loop for (nil . gc) in geom-cookies
                    for rank from 0 do
                (handler-case
                    (let* ((gr (xcb::get-geometry-reply conn gc))
                           (vx (slot-value gr 'xcb::x))
                           (vy (slot-value gr 'xcb::y))
                           (vw (slot-value gr 'xcb::width))
                           (vh (slot-value gr 'xcb::height))
                           (win (list vx vy vw vh rank)))
                      (push win stack)
                      (when (and (>= vy +min-window-top+)
                                 (< vy height)
                                 (>= vw +min-window-width+)
                                 (>= vh +min-window-height+)
                                 (< vx (xact:widget-width w))
                                 (> (+ vx vw) 0))
                        (push win windows)))
                  (error () nil)))))
          (let ((new-skyline (make-array (xsnow-column-count w)
                                         :element-type 'double-float
                                         :initial-element screen-h)))
            ;; Snow falling in a column lands on the highest top edge in it
            ;; that it can see: not under a window stacked above.
            (setf windows (sort windows #'< :key #'second))
            (loop for col from 0 below (xsnow-column-count w)
                  for x0 = (* col +column-width+)
                  for x1 = (+ x0 +column-width+)
                  do (dolist (win windows)
                       (destructuring-bind (vx vy vw vh rank) win
                         (declare (ignore vh))
                         (when (and (<= vx x0) (>= (+ vx vw) x1)
                                    (notany (lambda (o)
                                              (destructuring-bind (ox oy ow oh orank) o
                                                (and (> orank rank)
                                                     (< ox x1) (> (+ ox ow) x0)
                                                     (<= oy vy) (< vy (+ oy oh)))))
                                            stack))
                           (setf (aref new-skyline col)
                                 (max 0.0d0 (float vy 1.0d0)))
                           (return)))))
            (loop for i from 0 below (xsnow-column-count w)
                  for old = (aref (xsnow-skyline w) i)
                  when (/= (aref new-skyline i) old)
                    do (setf (aref (xsnow-window-snow w) i) 0.0d0)
                       (when (< old screen-h)
                         (clear-window-snow w i old)))
            (loop for i from 0 below (xsnow-column-count w)
                  when (< (aref new-skyline i) +min-window-top+)
                    do (setf (aref new-skyline i) screen-h)
                       (setf (aref (xsnow-window-snow w) i) 0.0d0))
            (replace (xsnow-skyline w) new-skyline)
            (setf (xsnow-skyline-dirty w) nil
                  (xsnow-ticks-since-refresh w) 0)))
      (error () nil))))

;;; Frame drawing

(defun clear-window-snow (w col top)
  "Forget the snow stamped on a window whose top edge in column COL was
   at TOP: it has moved, or gone."
  (let ((y0 (max 0 (- (round top) +max-window-snow+ 10))))
    (push (make-instance 'xcb::rectangle
                         :x (* col +column-width+) :y y0
                         :width +column-width+ :height (max 1 (- (round top) y0)))
          (xsnow-clears w))))

(defun opaque (w rgb)
  (if (xsnow-compositing w) (logior #xFF000000 rgb) rgb))

(defun clear-canvas (w)
  (let ((conn (xact:widget-connection w))
        (width (xact:widget-width w))
        (height (xact:widget-height w)))
    (if (xsnow-compositing w)
        (progn
          (xcb::change-gc conn (xsnow-canvas-gc w) +gc-foreground+
                          :foreground 0)
          (xcb::poly-fill-rectangle
           conn (xsnow-canvas w) (xsnow-canvas-gc w)
           (list (make-instance 'xcb::rectangle
                                :x 0 :y 0 :width width :height height))))
        (xcb::copy-area conn (xsnow-background w) (xsnow-canvas w)
                        (xsnow-canvas-gc w)
                        0 0 0 0 width height))))

(defun update-snow-mask (w)
  "Send SNOW-MASK the clears and stamps since the last frame."
  (let ((conn (xact:widget-connection w)))
    (when (xsnow-clears w)
      (xcb::poly-fill-rectangle conn (xsnow-snow-mask w) (xsnow-mask-clear-gc w)
                                (xsnow-clears w))
      (setf (xsnow-clears w) '()))
    (when (xsnow-bodies w)
      (xcb::poly-fill-rectangle conn (xsnow-snow-mask w) (xsnow-mask-gc w)
                                (xsnow-bodies w))
      (setf (xsnow-bodies w) '()))
    (when (xsnow-stamps w)
      (xcb::poly-point conn +coord-mode-origin+
                       (xsnow-snow-mask w) (xsnow-mask-gc w) (xsnow-stamps w))
      (setf (xsnow-stamps w) '()))))

(defun draw-accumulation (w)
  "Paint the fallen snow: white wherever SNOW-MASK is set."
  (update-snow-mask w)
  (let ((conn (xact:widget-connection w))
        (gc (xsnow-canvas-gc w)))
    (xcb::change-gc conn gc (logior +gc-foreground+ +gc-clip-mask+)
                    :foreground (opaque w #xFFFFFF)
                    :clip-mask (xsnow-snow-mask w))
    (xcb::poly-fill-rectangle
     conn (xsnow-canvas w) gc
     (list (make-instance 'xcb::rectangle :x 0 :y 0
                                          :width (xact:widget-width w)
                                          :height (xact:widget-height w))))
    (xcb::change-gc conn gc +gc-clip-mask+ :clip-mask 0)))

(defun draw-trees (w)
  (when (and (xsnow-tree-offsets w)
             (plusp (length (xsnow-tree-offsets w))))
    (let* ((width (xact:widget-width w))
           (height (xact:widget-height w))
           (positions (list (list (- width 150) (- height 300))
                            (list (- width 90)  (- height 160))
                            (list 90            (- height 160))
                            (list 40            (- height 110))))
           (offsets (aref (xsnow-tree-offsets w) 0))
           (points '()))
      (loop for (x y) in positions do
        (dolist (o offsets)
          (push (make-instance 'xcb::point
                               :x (+ x (car o))
                               :y (+ y (cdr o)))
                points)))
      (when points
        (let ((conn (xact:widget-connection w)))
          ;; Chartreuse, the C original's tree colour.
          (xcb::change-gc conn (xsnow-sprite-gc w) +gc-foreground+
                          :foreground (opaque w #x7FFF00))
          (xcb::poly-point conn +coord-mode-origin+
                           (xsnow-canvas w) (xsnow-sprite-gc w) points)
          (xcb::change-gc conn (xsnow-sprite-gc w) +gc-foreground+
                          :foreground (opaque w #xFFFFFF)))))))

(defun draw-flakes (w)
  (let ((points '()))
    (dotimes (i (xsnow-flake-count w))
      (let* ((f       (aref (xsnow-flakes w) i))
             (kind    (flake-kind f))
             (offsets (aref (xsnow-flake-offsets w) kind))
             (px      (round (flake-x f)))
             (py      (round (flake-y f))))
        (dolist (o offsets)
          (push (make-instance 'xcb::point
                               :x (+ px (car o))
                               :y (+ py (cdr o)))
                points))))
    (when points
      (xcb::poly-point (xact:widget-connection w)
                       +coord-mode-origin+
                       (xsnow-canvas w) (xsnow-sprite-gc w) points))))

(defun present (w)
  (let ((conn (xact:widget-connection w)))
    (xcb::copy-area conn (xsnow-canvas w) (xsnow-present-window w)
                    (xsnow-canvas-gc w)
                    0 0 0 0
                    (xact:widget-width w) (xact:widget-height w))))

(defun draw-frame (w)
  (clear-canvas w)
  (draw-accumulation w)
  (draw-trees w)
  (draw-flakes w)
  (draw-santa w)
  (present w))

(defmethod xact:draw ((w xsnow-widget) surface)
  (declare (ignore surface))
  (draw-frame w))

;;; Key helpers

(defun keycode-for-keysym (w ks)
  (maphash (lambda (kc ksyms)
             (when (find ks ksyms)
               (return-from keycode-for-keysym kc)))
           (xsnow-keycode-map w))
  nil)

(defun build-keycode-map (w)
  (let* ((conn (xact:widget-connection w)))
    (clrhash (xsnow-keycode-map w))
    (let* ((min-kc (xcb:conn-min-keycode conn))
           (max-kc (xcb:conn-max-keycode conn))
           (count  (1+ (- max-kc min-kc)))
           (cookie (xcb::get-keyboard-mapping conn min-kc count))
           (reply  (xcb::get-keyboard-mapping-reply conn cookie))
           (ks-per (slot-value reply 'xcb::keysyms-per-keycode))
           (keysyms (slot-value reply 'xcb::keysyms)))
      (loop for i from 0 below count
            for kc = (+ min-kc i)
            for base = (* i ks-per)
            do (setf (gethash kc (xsnow-keycode-map w))
                     (coerce (loop for j from 0 below ks-per
                                   collect (elt keysyms (+ base j)))
                             'vector))))))

(defun grab-keys (w)
  (let ((conn (xact:widget-connection w))
        (root (xact:widget-window w)))
    (flet ((grab (ks mod)
             (let ((kc (keycode-for-keysym w ks)))
               (when kc
                 (handler-case
                     (xcb::grab-key conn 0 root mod kc 1 1)
                   (error () nil))))))
      (grab +xk-q-small+ +mod-mask-control+)
      (grab +xk-w-small+ 0)
      (grab +xk-space+   0)
      (grab +xk-minus+   0)
      (grab +xk-minus+   +mod-mask-shift+)
      (grab +xk-slash+   0)
      (grab +xk-slash+   +mod-mask-shift+))))

(defun add-flakes (w n)
  (let* ((old (xsnow-flake-count w))
         (new (min +max-flakes+ (+ old n))))
    (when (> new old)
      (let ((v (make-array new)))
        (dotimes (i old) (setf (aref v i) (aref (xsnow-flakes w) i)))
        (loop for i from old below new
              do (setf (aref v i) (flake-respawn w (%make-flake) nil)))
        (setf (xsnow-flakes w) v (xsnow-flake-count w) new)))
    (when (xsnow-verbose w)
      (format t "~&flakes: ~D~%" (xsnow-flake-count w)))))

(defun remove-flakes (w n)
  (let ((new (max +min-flakes+ (- (xsnow-flake-count w) n))))
    (when (< new (xsnow-flake-count w))
      (let ((v (make-array new)))
        (dotimes (i new) (setf (aref v i) (aref (xsnow-flakes w) i)))
        (setf (xsnow-flakes w) v (xsnow-flake-count w) new)))
    (when (xsnow-verbose w)
      (format t "~&flakes: ~D~%" (xsnow-flake-count w)))))

;;; Interactors

(defclass xsnow-keys (xact:interactor)
  ((widget :initarg :widget :reader keys-widget)))

(defmethod xact:handle-event ((i xsnow-keys) (ev xact:key-press))
  (let ((w (keys-widget i))
        (ks (xact:event-keysym ev)))
    (cond
      ((eql ks #\w)
       (setf (xsnow-wind-enabled w) (not (xsnow-wind-enabled w)))
       (when (xsnow-verbose w)
         (format t "~&wind: ~:[off~;on~]~%" (xsnow-wind-enabled w)))
       t)
      ((eql ks #\space) (add-flakes w +flake-step+) t)
      ((or (eql ks #\-) (eql ks #\_)) (remove-flakes w +flake-step+) t)
      ((or (eql ks #\/) (eql ks #\?))
       (format t "~&xsnow state:~%  flakes: ~D~%  wind: ~:[off~;~,2F~]~%  size: ~Dx~D~%"
               (xsnow-flake-count w) (xsnow-wind-enabled w)
               (xsnow-wind w)
               (xact:widget-width w) (xact:widget-height w))
       t)
      (t nil))))

(defclass xsnow-tick (xact:interactor)
  ((widget    :initarg :widget :reader tick-widget)
   (next-tick :initform 0 :accessor tick-next)))

(defmethod xact:handle-tick ((i xsnow-tick))
  (let* ((w (tick-widget i))
         (now (get-internal-real-time)))
    (when (>= now (tick-next i))
      (xsnow-update w)
      (setf (xact:widget-dirty-p w) t)
      (setf (tick-next i)
            (+ now (round (* +tick-seconds+
                             internal-time-units-per-second)))))))

;;; Setup / teardown

(defun setup-presentation (w root)
  (setf (xsnow-compositing w)
        (compositor-running-p (xact:widget-connection w)))
  (when (xsnow-compositing w)
    (let* ((conn (xact:widget-connection w))
           (screen (xd:app-screen w))
           (visual (find-argb32-visual screen)))
      (unless visual
        (when (xsnow-verbose w)
          (format t "~&Compositor detected but no ARGB32 visual; drawing on root.~%"))
        (setf (xsnow-compositing w) nil))
      (when (xsnow-compositing w)
        (let ((width (xact:widget-width w))
              (height (xact:widget-height w)))
          (setf (xsnow-overlay-colormap w) (xcb:generate-id conn))
          (xcb::create-colormap conn 0 (xsnow-overlay-colormap w) root visual)
          (setf (xsnow-overlay w) (xcb:generate-id conn))
          (xcb::create-window
           conn 32 (xsnow-overlay w) root 0 0 width height 0
           1 visual
           (logior +cw-back-pixel+ +cw-border-pixel+
                   +cw-colormap+ +cw-override-redirect+
                   +cw-event-mask+)
           :background-pixel 0
           :border-pixel 0
           :colormap (xsnow-overlay-colormap w)
           :override-redirect 1
           :event-mask (logior +event-mask-exposure+
                               +event-mask-substructure-notify+))
          (handler-case
              (progn
                (xcb:ensure-extension conn "XCB-SHAPE")
                (xcb-shape::rectangles conn +shape-so-set+ +shape-sk-input+
                                       0 (xsnow-overlay w) 0 0 '()))
            (error () nil))
          (xcb::map-window conn (xsnow-overlay w))
          (raise-overlay w)
          (when (xsnow-verbose w)
            (format t "~&Compositor detected: drawing on transparent overlay.~%"))))))
  (setf (xsnow-present-window w)
        (if (xsnow-compositing w) (xsnow-overlay w) root)))

(defun setup-canvas (w root)
  (let* ((conn (xact:widget-connection w))
         (screen (xd:app-screen w))
         (width (xact:widget-width w))
         (height (xact:widget-height w))
         (depth (if (xsnow-compositing w) 32 (xcb:root-depth screen))))
    (setf (xsnow-canvas w) (xcb:generate-id conn))
    (xcb::create-pixmap conn depth (xsnow-canvas w) root width height)
    (setf (xsnow-canvas-gc w) (xcb:generate-id conn))
    (xcb::create-gc conn (xsnow-canvas-gc w) (xsnow-canvas w) +gc-foreground+
                    :foreground (if (xsnow-compositing w)
                                    0
                                    (xsnow-bg-pixel w)))
    (setf (xsnow-sprite-gc w) (xcb:generate-id conn))
    (xcb::create-gc conn (xsnow-sprite-gc w) (xsnow-canvas w) +gc-foreground+
                    :foreground (opaque w #xFFFFFF))
    (setup-snow-mask w root)
    (unless (xsnow-compositing w)
      (setf (xsnow-background w) (xcb:generate-id conn))
      (xcb::create-pixmap conn depth (xsnow-background w) root width height)
      (capture-root-background w root (xsnow-background w)))))

(defun setup-snow-mask (w root)
  "Make SNOW-MASK, an empty bitmap the size of the screen, and the GCs
   that set and clear it."
  (let ((conn (xact:widget-connection w))
        (width (xact:widget-width w))
        (height (xact:widget-height w)))
    (setf (xsnow-snow-mask w) (xcb:generate-id conn)
          (xsnow-mask-gc w) (xcb:generate-id conn)
          (xsnow-mask-clear-gc w) (xcb:generate-id conn))
    (xcb::create-pixmap conn 1 (xsnow-snow-mask w) root width height)
    (xcb::create-gc conn (xsnow-mask-gc w) (xsnow-snow-mask w) +gc-foreground+
                    :foreground 1)
    (xcb::create-gc conn (xsnow-mask-clear-gc w) (xsnow-snow-mask w) +gc-foreground+
                    :foreground 0)
    (xcb::poly-fill-rectangle conn (xsnow-snow-mask w) (xsnow-mask-clear-gc w)
                              (list (make-instance 'xcb::rectangle :x 0 :y 0
                                                                   :width width
                                                                   :height height)))))

(defun capture-root-background (w root pixmap)
  "Copy the root window's background -- the desktop without the windows
   on it -- into PIXMAP.  Copying from the root itself would give
   whatever the windows on it cover as garbage, which xsnow would then
   paint back wherever a window moves away.  Instead a full-screen
   window with a ParentRelative background is mapped on top for a
   moment: it shows the root's background everywhere, and is copied."
  (let* ((conn (xact:widget-connection w))
         (width (xact:widget-width w))
         (height (xact:widget-height w))
         (snap (xcb:generate-id conn)))
    (xcb::create-window conn 0 snap root 0 0 width height 0
                        +window-class-input-output+ 0
                        (logior +cw-back-pixmap+ +cw-override-redirect+)
                        :background-pixmap 1 ; ParentRelative
                        :override-redirect 1)
    (xcb::map-window conn snap)
    ;; The server paints the background while mapping; a round trip
    ;; makes sure that has happened before the copy.
    (xcb::get-input-focus-reply conn (xcb::get-input-focus conn))
    (xcb::copy-area conn snap pixmap (xsnow-canvas-gc w)
                    0 0 0 0 width height)
    (xcb::destroy-window conn snap)))

(defun setup-columns (w)
  (let ((count (max 1 (ceiling (xact:widget-width w) +column-width+))))
    (setf (xsnow-column-count w) count
          (xsnow-drift w) (make-drift count)
          (xsnow-snow-heights w) (make-array count
                                             :element-type 'double-float
                                             :initial-element 0.0d0)
          (xsnow-window-snow w) (make-array count
                                            :element-type 'double-float
                                            :initial-element 0.0d0)
          (xsnow-skyline w) (make-array count
                                        :element-type 'double-float
                                        :initial-element
                                        (float (xact:widget-height w) 1.0d0)))))

(defun setup-flakes (w)
  (let ((n (max 80 (min +max-flakes+
                        (truncate (/ (* (xact:widget-width w)
                                        (xact:widget-height w))
                                     10000))))))
    (setf (xsnow-flake-count w) n
          (xsnow-flakes w) (make-flake-vector w n))
    (refresh-skyline w)))

(defun xsnow-setup (w root)
  (let ((screen (xd:app-screen w)))
    (setf (xsnow-bg-pixel w) (xcb:black-pixel screen))
    (setup-columns w)
    (setup-presentation w root)
    (setup-canvas w root)
    (load-all-sprites w)
    (setup-flakes w)
    (paint-snow-at-bottom w)
    (when (xsnow-santa-enabled w)
      (load-santa-frames w)
      (santa-respawn w))
    (build-keycode-map w)
    (grab-keys w)))

(defun teardown-presentation (w)
  (let ((conn (xact:widget-connection w)))
    (if (xsnow-compositing w)
        (xcb-demos:ignoring-errors
          (when (xsnow-overlay w)
            (xcb::destroy-window conn (xsnow-overlay w)))
          (when (xsnow-overlay-colormap w)
            (xcb::free-colormap conn (xsnow-overlay-colormap w))))
        (handler-case
            (progn
              (if (and (xsnow-background w) (xsnow-canvas-gc w))
                  (xcb::copy-area conn (xsnow-background w)
                                  (xact:widget-window w) (xsnow-canvas-gc w)
                                  0 0 0 0
                                  (xact:widget-width w)
                                  (xact:widget-height w))
                  (let ((gc (xcb:generate-id conn)))
                    (xcb::create-gc conn gc (xact:widget-window w)
                                    +gc-foreground+
                                    :foreground (xsnow-bg-pixel w))
                    (xcb::poly-fill-rectangle
                     conn (xact:widget-window w) gc
                     (list (make-instance 'xcb::rectangle
                                          :x 0 :y 0
                                          :width (xact:widget-width w)
                                          :height (xact:widget-height w))))
                    (xcb::free-gc conn gc)))
              (xcb::get-input-focus-reply
               conn (xcb::get-input-focus conn)))
          (error () nil)))))

(defun xsnow-teardown (w)
  (let ((conn (xact:widget-connection w)))
    (teardown-presentation w)
    (xcb-demos:ignoring-errors
      (when (xsnow-canvas-gc w)
        (xcb::free-gc conn (xsnow-canvas-gc w))
        (setf (xsnow-canvas-gc w) nil))
      (when (xsnow-sprite-gc w)
        (xcb::free-gc conn (xsnow-sprite-gc w))
        (setf (xsnow-sprite-gc w) nil))
      (free-santa-gcs w)
      (when (xsnow-canvas w)
        (xcb::free-pixmap conn (xsnow-canvas w))
        (setf (xsnow-canvas w) nil))
      (when (xsnow-mask-gc w)
        (xcb::free-gc conn (xsnow-mask-gc w))
        (xcb::free-gc conn (xsnow-mask-clear-gc w))
        (setf (xsnow-mask-gc w) nil (xsnow-mask-clear-gc w) nil))
      (when (xsnow-snow-mask w)
        (xcb::free-pixmap conn (xsnow-snow-mask w))
        (setf (xsnow-snow-mask w) nil))
      (when (xsnow-background w)
        (xcb::free-pixmap conn (xsnow-background w))
        (setf (xsnow-background w) nil)))))

(defun xsnow (&rest options)
  (apply #'run options))

(defun run-xsnow (d conn)
  (let* ((widget (xd:make-application d conn
                                      ;; The virtual root, where a WM has one: drawn
                                      ;; on the real root, the snow would be hidden
                                      ;; behind it.
                                      :window (xd:virtual-root conn)))
         (screen (xd:app-screen widget))
         (root   (xact:widget-window widget))
         (width  (xcb:width-in-pixels screen))
         (height (xcb:height-in-pixels screen)))
    (setf (xact:widget-width widget)  width
          (xact:widget-height widget) height)
    ;; The physics wants double floats; options may be any real.
    (with-slots (accrate santa-speed santa-rate santa-timeout) widget
      (setf accrate       (float accrate 1.0d0)
            santa-speed   (float santa-speed 1.0d0)
            santa-rate    (float santa-rate 1.0d0)
            santa-timeout (float santa-timeout 1.0d0)))
    (xact:realize widget)
    (xsnow-setup widget root)
    (let ((quit (make-instance 'xact:quit-interactor :window root
                               :keys '((:control #\q)) :close nil))
          (keys (make-instance 'xsnow-keys :window root :widget widget))
          (tick (make-instance 'xsnow-tick :window root :widget widget)))
      (xact:widget-add-interactor widget keys)
      (xact:widget-add-interactor widget tick)
      (xact:widget-add-interactor widget quit)
      (xcb::change-window-attributes
       conn root (logior +cw-event-mask+)
       :event-mask (logior +event-mask-exposure+
                           +event-mask-substructure-notify+))
      (format t "~&Screen: ~Dx~D, flakes: ~D~%"
              width height (xsnow-flake-count widget))
      (format t "~&Controls (grabbed globally):~%")
      (format t "  Ctrl+q       exit~%")
      (format t "  w            toggle wind~%")
      (format t "  space        add 25 flakes~%")
      (format t "  -            remove 25 flakes~%")
      (format t "  ? or /       dump state~%")
      (setf (xact:widget-dirty-p widget) t)
      (unwind-protect
           (xact:run-widget
            widget root
            :stop-when (lambda () (xact:quit-requested-p quit))
            :on-other-event
            (lambda (ev)
              (when (or (typep ev 'xcb::create-notify)
                        (typep ev 'xcb::reparent-notify))
                (setf (xsnow-skyline-dirty widget) t))
              nil))
        (xsnow-teardown widget)
        (xact:unrealize widget))))
  t)
