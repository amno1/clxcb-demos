;;; xeyes.lisp — XEyes port for CLXCB.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: MIT
;;;
;;; A Common Lisp port of the classic X11 xeyes demo, derived from the
;;; original C implementation (Eyes.c, Eyes.h, EyesP.h, transform.c,
;;; transform.h, xeyes.c) by Keith Packard at the MIT X Consortium,
;;; which was itself a port of the NeWS xeyes demo (Jeremy Huxtable,
;;; SIGGRAPH '88).  The original's MIT notice is preserved below.
;;;
;;;     Copyright (c) 1991  X Consortium
;;;
;;;     Permission is hereby granted, free of charge, to any person
;;;     obtaining a copy of this software and associated documentation
;;;     files (the "Software"), to deal in the Software without
;;;     restriction, including without limitation the rights to use,
;;;     copy, modify, merge, publish, distribute, sublicense, and/or
;;;     sell copies of the Software, and to permit persons to whom the
;;;     Software is furnished to do so, subject to the following
;;;     conditions:
;;;
;;;     The above copyright notice and this permission notice shall
;;;     be included in all copies or substantial portions of the
;;;     Software.
;;;
;;;     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;;     EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
;;;     OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;;     NONINFRINGEMENT.  IN NO EVENT SHALL THE X CONSORTIUM BE LIABLE
;;;     FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
;;;     OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;;;     CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;;;     THE SOFTWARE.
;;;
;;;     Except as contained in this notice, the name of the X Consortium
;;;     shall not be used in advertising or otherwise to promote the
;;;     sale, use or other dealings in this Software without prior
;;;     written authorization from the X Consortium.
;;;

(xd:define-demo :xeyes
    (:wm-title "CLXCB XEyes"
     :resource-class "XEyes"
     :app xeyes-widget
     :options
     (:width :height :x :y :geometry :shape :distance :decorated :render))
  (format t "~&========================================~%")
  (format t "   CLXCB XEyes (demo5)                 ~%")
  (format t "========================================~%")
  (run-xeyes d conn))

;;; Eye geometry — same values as the C original.

(defconstant +eye-offset+ 0.1d0)
(defconstant +eye-thick+  0.175d0)
(defconstant +ball-diam+  0.3d0)
(defconstant +ball-pad+   0.175d0)
(defconstant +eye-diam+   (- 2.0d0 (* (+ +eye-thick+ +eye-offset+) 2.0d0)))
(defconstant +ball-dist+  (- (/ (- +eye-diam+ +ball-diam+) 2.0d0) +ball-pad+))
(defconstant +w-min-x+    (+ -1.0d0 +eye-offset+))
(defconstant +w-max-x+    (-  3.0d0 +eye-offset+))
(defconstant +w-min-y+    (+ -1.0d0 +eye-offset+))
(defconstant +w-max-y+    (-  1.0d0 +eye-offset+))
(defconstant +tpoint-none+ -1000.0d0)

;; EVAL-WHEN: read with #. at compile time below; not every Lisp defines
;; a plain DEFCONSTANT at compile time.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +part-outline+ 0)
  (defconstant +part-center+  1)
  (defconstant +part-pupil+   2))

;; Inter-poll delays in milliseconds.  Index 0 is the active rate
;; (~60 Hz); the last non-zero entry is the idle cap.
(defparameter *delays* #(16 32 64 128 0))

;;; Pure geometry.

(defstruct (xe-transform (:constructor %make-xe-transform))
  (mx 1.0d0 :type double-float)
  (bx 0.0d0 :type double-float)
  (my 1.0d0 :type double-float)
  (by 0.0d0 :type double-float))

(defun make-fit-transform (pixel-w pixel-h)
  (let* ((mx (/ (float pixel-w 1.0d0) (- +w-max-x+ +w-min-x+)))
         (bx (- 0.0d0 (* mx +w-min-x+)))
         (my (/ (float (- pixel-h) 1.0d0)
                (- +w-max-y+ +w-min-y+)))
         (by (- (float pixel-h 1.0d0) (* my +w-min-y+))))
    (%make-xe-transform :mx mx :bx bx :my my :by by)))

(defun tr-x (x tr) (round (+ (* (xe-transform-mx tr) x) (xe-transform-bx tr))))
(defun tr-y (y tr) (round (+ (* (xe-transform-my tr) y) (xe-transform-by tr))))
(defun un-tr-x (px tr) (/ (- px (xe-transform-bx tr)) (xe-transform-mx tr)))
(defun un-tr-y (py tr) (/ (- py (xe-transform-by tr)) (xe-transform-my tr)))

(defun eye-x (n) (* n 2.0d0))

(defun angle-between-p (a a0 a1)
  (if (<= a0 a1)
      (and (<= a0 a) (<= a a1))
      (or (<= a0 a) (<= a a1))))

(defun compute-pupil (num mouse-x mouse-y screen-rect)
  (let* ((cx (eye-x num))
         (cy 0.0d0)
         (dx (- mouse-x cx))
         (dy (- mouse-y cy)))
    (if (and (zerop dx) (zerop dy))
        (values cx cy)
        (let ((angle (atan dy dx))
              (dist  +ball-dist+))
          (when screen-rect
            (destructuring-bind (sx0 sy0 sx1 sy1) screen-rect
              (let* ((x0 (- sx0 cx)) (y0 (- sy0 cy))
                     (x1 (- sx1 cx)) (y1 (- sy1 cy))
                     (a0 (atan y0 x0))
                     (a1 (atan y1 x0))
                     (a2 (atan y1 x1))
                     (a3 (atan y0 x1)))
                (cond
                  ((angle-between-p angle a0 a1)
                   (when (not (zerop x0))
                     (setf dist (* dist (/ dx x0)))))
                  ((angle-between-p angle a1 a2)
                   (when (not (zerop y1))
                     (setf dist (* dist (/ dy y1)))))
                  ((angle-between-p angle a2 a3)
                   (when (not (zerop x1))
                     (setf dist (* dist (/ dx x1)))))
                  ((angle-between-p angle a3 a0)
                   (when (not (zerop y0))
                     (setf dist (* dist (/ dy y0))))))
                (when (> dist +ball-dist+)
                  (setf dist +ball-dist+)))))
          (let ((hyp (sqrt (+ (* dx dx) (* dy dy)))))
            (if (< hyp dist)
                (values (+ cx dx) (+ cy dy))
                (values (+ cx (* dist (cos angle)))
                        (+ cy (* dist (sin angle))))))))))

(defun eye-rect-to-pixel (cx cy diam tr)
  (let* ((half (/ diam 2.0d0))
         (x0 (tr-x (- cx half) tr))
         (y0 (tr-y (- cy half) tr))
         (x1 (tr-x (+ cx half) tr))
         (y1 (tr-y (+ cy half) tr)))
    (when (> x0 x1) (rotatef x0 x1))
    (when (> y0 y1) (rotatef y0 y1))
    (values x0 y0 (- x1 x0) (- y1 y0))))

(defun circle-segment-count (pw ph)
  (let* ((hd    (/ (sqrt (+ (* pw pw 1.0d0) (* ph ph 1.0d0))) 2.0d0))
         (ratio (min 0.9999999d0 (/ hd (+ hd 0.25d0)))))
    (min 360 (max 8 (* 2 (max 2 (round (/ pi (acos ratio)))))))))

;;; The widget.

(defclass xeyes-widget (xd:application)
  ;; Everything one run needs: its options, how its window is placed,
  ;; its colours, GCs and pixmaps, and the quit interactor.  An
  ;; unrequested position (X, Y NIL) is 100, 100.
  ((decorated      :initarg :decorated :initform nil :type boolean
                   :reader xeyes-decorated
                   :documentation "let the WM decorate the window")
   (positionp      :initform nil
                   :documentation "True when the user asked for a position.")
   (quit           :initform nil :reader xeyes-quit
                   :documentation
                   "The QUIT-INTERACTOR that ends the run.")
   (shape-enabled  :initarg :shape     :initform t   :type boolean
                   :reader xeyes-shape-enabled
                   :documentation
                   "use the SHAPE extension")
   (render-enabled :initarg :render    :initform t   :type boolean
                   :reader xeyes-render-enabled
                   :documentation
                   "use the RENDER extension when available")
   (distance       :initarg :distance  :initform nil :type boolean
                   :reader xeyes-distance
                   :documentation
                   "pupils reach the rim as the pointer nears the screen edge")

   (pixel-outline  :initform 0 :accessor xeyes-pixel-outline)
   (pixel-center   :initform 0 :accessor xeyes-pixel-center)
   (pixel-pupil    :initform 0 :accessor xeyes-pixel-pupil)
   (pixel-bg       :initform 0 :accessor xeyes-pixel-bg)
   (gc-outline     :initform nil :accessor xeyes-gc-outline)
   (gc-center      :initform nil :accessor xeyes-gc-center)
   (gc-pupil       :initform nil :accessor xeyes-gc-pupil)
   (gc-bg          :initform nil :accessor xeyes-gc-bg)
   (pixmap         :initform nil :accessor xeyes-pixmap)
   (paint-w        :initform 0   :accessor xeyes-paint-w)
   (paint-h        :initform 0   :accessor xeyes-paint-h)

   (render-p            :initform nil :accessor xeyes-render-p)
   (render-format       :initform nil :accessor xeyes-render-format)
   (render-window-pict  :initform nil :accessor xeyes-render-window-pict)
   (render-fill         :initform (make-array 3 :initial-element nil)
                        :accessor xeyes-render-fill)
   (render-mask-format  :initform nil :accessor xeyes-render-mask-format)

   (shape-p    :initform nil :accessor xeyes-shape-p)
   (shape-mask :initform nil :accessor xeyes-shape-mask)

   (transform :initform nil :accessor xeyes-transform)
   (pupil-x   :initform (make-array 2 :initial-element +tpoint-none+
                                      :element-type 'double-float)
              :accessor xeyes-pupil-x)
   (pupil-y   :initform (make-array 2 :initial-element +tpoint-none+
                                      :element-type 'double-float)
              :accessor xeyes-pupil-y)
   (mouse-x   :initform +tpoint-none+ :accessor xeyes-mouse-x)
   (mouse-y   :initform +tpoint-none+ :accessor xeyes-mouse-y)

   (saved-focus :initform nil :accessor xeyes-saved-focus))
  (:default-initargs :width 150 :height 100))

;;; Setup.

(defun xeyes-setup-colors (w screen)
  (setf (xeyes-pixel-outline w) (xcb:black-pixel screen)
        (xeyes-pixel-center  w) (xcb:white-pixel screen)
        (xeyes-pixel-pupil   w) (xcb:black-pixel screen)
        (xeyes-pixel-bg      w) (xcb:black-pixel screen)))

(defun xeyes-setup-gcs (w)
  (let* ((conn   (xact:widget-connection w))
         (window (xact:widget-window w)))
    (setf (xeyes-gc-outline w) (xcb:generate-id conn)
          (xeyes-gc-center  w) (xcb:generate-id conn)
          (xeyes-gc-pupil   w) (xcb:generate-id conn)
          (xeyes-gc-bg      w) (xcb:generate-id conn))
    (xcb::create-gc conn (xeyes-gc-outline w) window +gc-foreground+
                    :foreground (xeyes-pixel-outline w))
    (xcb::create-gc conn (xeyes-gc-center w) window +gc-foreground+
                    :foreground (xeyes-pixel-center w))
    (xcb::create-gc conn (xeyes-gc-pupil w) window +gc-foreground+
                    :foreground (xeyes-pixel-pupil w))
    (xcb::create-gc conn (xeyes-gc-bg w) window +gc-foreground+
                    :foreground (xeyes-pixel-bg w))))

(defun xeyes-recreate-backing-store (w)
  (let ((conn (xact:widget-connection w))
        (window (xact:widget-window w)))
    (when (xeyes-render-window-pict w)
      (ignore-errors
       (xcb-render::free-picture conn (xeyes-render-window-pict w)))
      (setf (xeyes-render-window-pict w) nil))
    (when (xeyes-pixmap w)
      (ignore-errors (xcb::free-pixmap conn (xeyes-pixmap w)))
      (setf (xeyes-pixmap w) nil))
    (let* ((screen (xd:app-screen w))
           (width  (xact:widget-width w))
           (height (xact:widget-height w)))
      (setf (xeyes-pixmap w) (xcb:generate-id conn))
      (xcb::create-pixmap conn (xcb:root-depth screen)
                          (xeyes-pixmap w) window width height)
      (when (xeyes-render-format w)
        (setf (xeyes-render-window-pict w) (xcb:generate-id conn))
        (xcb-render::create-picture
         conn (xeyes-render-window-pict w)
         (xeyes-pixmap w) (xeyes-render-format w) 0))
      (setf (xeyes-paint-w w) width
            (xeyes-paint-h w) height))))

(defun xeyes-setup-render (w)
  (let* ((conn (xact:widget-connection w))
         (info (handler-case (xcb:ensure-extension conn "XCB-RENDER")
                 (error () nil))))
    (unless (and info (getf info :present))
      (return-from xeyes-setup-render nil)))
  (handler-case
      (let* ((conn    (xact:widget-connection w))
             (screen  (xd:app-screen w))
             (visual  (xcb:root-visual screen))
             (reply   (runes/xcb:pict-formats-reply-for conn))
             (format  (xcb-render:find-visual-pict-format reply visual))
             (a8      (xcb-render:find-standard-pict-format
                       reply xcb-render:+pict-standard-a8+)))
        (unless a8
          (format t "~&RENDER: A8 PictFormat not found; falling back.~%")
          (return-from xeyes-setup-render nil))
        (unless format
          (format t "~&RENDER: no PictFormat for visual #x~X; falling back.~%"
                  visual)
          (return-from xeyes-setup-render nil))
        (setf (xeyes-render-mask-format w) a8)
        (setf (xeyes-render-format w) format)
        ;; Rebuild the backing store now that render-format is set, so
        ;; the destination Picture is created against the fresh pixmap.
        (xeyes-recreate-backing-store w)
        (let ((colors (vector
                       (xcb-render:make-color 0 0 0)
                       (xcb-render:make-color #xFFFF #xFFFF #xFFFF)
                       (xcb-render:make-color 0 0 0))))
          (dotimes (i 3)
            (let ((pid (xcb:generate-id conn)))
              (xcb-render::create-solid-fill conn pid (aref colors i))
              (setf (aref (xeyes-render-fill w) i) pid))))
        (setf (xeyes-render-p w) t)
        t)
    (error () nil)))

(defun xeyes-teardown-render (w)
  (let ((conn (xact:widget-connection w)))
    (when (xeyes-render-window-pict w)
      (ignore-errors
       (xcb-render::free-picture conn (xeyes-render-window-pict w)))
      (setf (xeyes-render-window-pict w) nil))
    (dotimes (i 3)
      (when (aref (xeyes-render-fill w) i)
        (ignore-errors
         (xcb-render::free-picture conn (aref (xeyes-render-fill w) i)))
        (setf (aref (xeyes-render-fill w) i) nil)))
    (setf (xeyes-render-p w) nil
          (xeyes-render-mask-format w) nil)))

;;; Drawing primitives.

(defun xeyes-present (w)
  (let ((conn (xact:widget-connection w)))
    (xcb::copy-area conn (xeyes-pixmap w) (xact:widget-window w)
                    (xeyes-gc-bg w)
                    0 0 0 0
                    (xact:widget-width w)
                    (xact:widget-height w))))

(defun xeyes-poly-fill-arc-circle (w drawable gc cx cy diam &optional (expand 0))
  (let ((conn (xact:widget-connection w))
        (tr   (xeyes-transform w)))
    (multiple-value-bind (px py pw ph)
        (eye-rect-to-pixel cx cy diam tr)
      (when (and (plusp pw) (plusp ph))
        (xcb::poly-fill-arc
         conn drawable gc
         (list (make-instance 'xcb::arc
                              :x (- px expand)
                              :y (- py expand)
                              :width (+ pw (* 2 expand))
                              :height (+ ph (* 2 expand))
                              :angle1 (* 90 64) :angle2 (* 360 64))))))))

(defun xeyes-render-tri-fan-circle (w part cx cy diam)
  (let ((conn (xact:widget-connection w))
        (tr   (xeyes-transform w)))
    (multiple-value-bind (px py pw ph)
        (eye-rect-to-pixel cx cy diam tr)
      (when (and (plusp pw) (plusp ph))
        (flet ((fix (n) (round (* n 65536.0d0))))
          (let* ((cx-px  (+ px (/ pw 2.0d0)))
                 (cy-px  (+ py (/ ph 2.0d0)))
                 (n      (circle-segment-count pw ph))
                 (scale  (/ 1.0d0 (cos (/ pi (float n 1.0d0)))))
                 (rx-px  (* (/ pw 2.0d0) scale))
                 (ry-px  (* (/ ph 2.0d0) scale))
                 (points (list (make-instance 'xcb-render::pointfix
                                              :x (fix cx-px)
                                              :y (fix cy-px)))))
            (loop for i from 0 to n do
              (let* ((theta (* 2.0d0 pi (/ (float i 1.0d0) (float n))))
                     (x (fix (+ cx-px (* rx-px (cos theta)))))
                     (y (fix (+ cy-px (* ry-px (sin theta))))))
                (push (make-instance 'xcb-render::pointfix :x x :y y)
                      points)))
            (xcb-render::tri-fan
             conn
             runes/xcb:+pict-op-over+
             (aref (xeyes-render-fill w) part)
             (xeyes-render-window-pict w)
             (xeyes-render-mask-format w)
             0 0
             (nreverse points))))))))

(defun xeyes-draw-fill-circle (w cx cy diam part &optional force-aliased)
  (if (and (xeyes-render-p w) (not force-aliased))
      (xeyes-render-tri-fan-circle w part cx cy diam)
      (let ((gc (ecase part
                  (#.+part-outline+ (xeyes-gc-outline w))
                  (#.+part-center+  (xeyes-gc-center w))
                  (#.+part-pupil+   (xeyes-gc-pupil w)))))
        (xeyes-poly-fill-arc-circle w (xeyes-pixmap w) gc cx cy diam))))

(defun xeyes-draw-eye-outline (w num)
  (xeyes-draw-fill-circle w (eye-x num) 0.0d0
                          (+ +eye-diam+ (* 2.0d0 +eye-thick+))
                          +part-outline+
                          (and (xeyes-shape-enabled w) (xeyes-shape-p w))))

(defun xeyes-draw-eye-center (w num)
  (xeyes-draw-fill-circle w (eye-x num) 0.0d0 +eye-diam+ +part-center+))

(defun xeyes-draw-eye-liner (w num)
  (xeyes-draw-eye-outline w num)
  (xeyes-draw-eye-center w num))

(defun xeyes-draw-pupil (w num)
  (xeyes-draw-fill-circle w
                          (aref (xeyes-pupil-x w) num)
                          (aref (xeyes-pupil-y w) num)
                          (+ +ball-diam+ 0.02d0)
                          +part-pupil+))

(defun xeyes-erase-pupil (w num)
  (let ((px (aref (xeyes-pupil-x w) num))
        (py (aref (xeyes-pupil-y w) num)))
    (when (/= px +tpoint-none+)
      (let ((conn (xact:widget-connection w))
            (tr   (xeyes-transform w)))
        (multiple-value-bind (x y ww hh)
            (eye-rect-to-pixel px py +ball-diam+ tr)
          (when (and (plusp ww) (plusp hh))
            (let ((rect (make-instance 'xcb::rectangle
                                       :x (- x 3)
                                       :y (- y 3)
                                       :width (+ ww 7)
                                       :height (+ hh 7))))
              (if (xeyes-render-p w)
                  (xcb-render::fill-rectangles
                   conn runes/xcb:+pict-op-over+
                   (xeyes-render-window-pict w)
                   (xcb-render:make-color #xFFFF #xFFFF #xFFFF)
                   (list rect))
                  (xcb::poly-fill-rectangle
                   conn (xeyes-pixmap w) (xeyes-gc-center w)
                   (list rect))))))))))

(defun xeyes-redraw-all (w)
  (let ((conn (xact:widget-connection w)))
    (xcb::poly-fill-rectangle
     conn (xeyes-pixmap w) (xeyes-gc-bg w)
     (list (make-instance 'xcb::rectangle
                          :x 0 :y 0
                          :width  (xact:widget-width w)
                          :height (xact:widget-height w))))
    (xeyes-draw-eye-liner w 0)
    (xeyes-draw-eye-liner w 1)
    (when (/= (aref (xeyes-pupil-x w) 0) +tpoint-none+)
      (xeyes-draw-pupil w 0))
    (when (/= (aref (xeyes-pupil-x w) 1) +tpoint-none+)
      (xeyes-draw-pupil w 1))
    (xeyes-present w)))

(defmethod xact:draw ((w xeyes-widget) surface)
  (declare (ignore surface))
  (let ((nw (xact:widget-width w))
        (nh (xact:widget-height w)))
    (unless (and (= nw (xeyes-paint-w w))
                 (= nh (xeyes-paint-h w)))
      (setf (xeyes-transform w) (make-fit-transform nw nh))
      (xeyes-recreate-backing-store w)
      (when (xeyes-shape-p w)
        (xeyes-apply-shape w))))
  (xeyes-redraw-all w))

;;; Pupil updates and the pointer poll.

(defun xeyes-screen-rect-in-eye-space (w)
  (when (xeyes-distance w)
    (let ((conn   (xact:widget-connection w))
          (window (xact:widget-window w))
          (tr     (xeyes-transform w)))
      (multiple-value-bind (wx wy) (xcb:window-root-position conn window)
        (let* ((screen (xd:app-screen w))
               (sw (xcb:width-in-pixels screen))
               (sh (xcb:height-in-pixels screen)))
          (list (un-tr-x (- wx)    tr)
                (un-tr-y (- wy)    tr)
                (un-tr-x (- sw wx) tr)
                (un-tr-y (- sh wy) tr)))))))

;; Poll the pointer, move both pupils if the mouse has moved, and return
;; T if it did.  Returns NIL when the pointer is still.  The return
;; value drives the tick backoff; it must track *mouse* movement, not
;; *pupil* movement, or the backoff advances during a fast sweep after
;; the pupils have already saturated against the rim.
(defun xeyes-update-pupils (w)
  (let* ((conn   (xact:widget-connection w))
         (window (xact:widget-window w))
         (tr     (xeyes-transform w))
         (cookie (xcb::query-pointer conn window))
         (reply  (xcb::query-pointer-reply conn cookie))
         (wx     (slot-value reply 'xcb::win-x))
         (wy     (slot-value reply 'xcb::win-y))
         (mx     (un-tr-x wx tr))
         (my     (un-tr-y wy tr)))
    (when (and (eql mx (xeyes-mouse-x w))
               (eql my (xeyes-mouse-y w)))
      (return-from xeyes-update-pupils nil))
    (setf (xeyes-mouse-x w) mx
          (xeyes-mouse-y w) my)
    (let ((screen-rect (xeyes-screen-rect-in-eye-space w))
          (changed nil))
      (dotimes (n 2)
        (multiple-value-bind (px py) (compute-pupil n mx my screen-rect)
          (unless (and (eql px (aref (xeyes-pupil-x w) n))
                       (eql py (aref (xeyes-pupil-y w) n)))
            (xeyes-erase-pupil w n)
            (setf (aref (xeyes-pupil-x w) n) px
                  (aref (xeyes-pupil-y w) n) py)
            (xeyes-draw-pupil w n)
            (setf changed t))))
      (when changed (xeyes-present w)))
    t))

;;; SHAPE.

(defun xeyes-ensure-shape-extension (w)
  (when (xeyes-shape-p w) (return-from xeyes-ensure-shape-extension t))
  (let ((info (handler-case
                  (xcb:ensure-extension (xact:widget-connection w) "XCB-SHAPE")
                (error () nil))))
    (unless (and info (getf info :present))
      (return-from xeyes-ensure-shape-extension nil))
    (setf (xeyes-shape-p w) t)))

(defun xeyes-apply-shape (w)
  (unless (xeyes-ensure-shape-extension w)
    (format t "~&~a; using a rectangular window.~%"
            "SHAPE extension not available")
    (return-from xeyes-apply-shape nil))
  (let ((conn (xact:widget-connection w))
        (window (xact:widget-window w)))
    (when (xeyes-shape-mask w)
      (ignore-errors (xcb::free-pixmap conn (xeyes-shape-mask w)))
      (setf (xeyes-shape-mask w) nil))
    (let ((mask (xcb:generate-id conn))
          (gc   (xcb:generate-id conn))
          (width  (xact:widget-width w))
          (height (xact:widget-height w)))
      (xcb::create-pixmap conn 1 mask window width height)
      (xcb::create-gc conn gc mask +gc-foreground+ :foreground 0)
      (xcb::poly-fill-rectangle
       conn mask gc
       (list (make-instance 'xcb::rectangle
                            :x 0 :y 0 :width width :height height)))
      (xcb::change-gc conn gc +gc-foreground+ :foreground 1)
      (xeyes-poly-fill-arc-circle w mask gc (eye-x 0) 0.0d0
                                  (+ +eye-diam+ (* 2.0d0 +eye-thick+)))
      (xeyes-poly-fill-arc-circle w mask gc (eye-x 1) 0.0d0
                                  (+ +eye-diam+ (* 2.0d0 +eye-thick+)))
      (xcb-shape::mask conn 0 0 window 0 0 mask)
      (xcb::free-gc conn gc)
      (setf (xeyes-shape-mask w) mask)
      t)))

;;; Window creation.

(defun xeyes-create-window (w root decorated x y)
  (let* ((conn (xact:widget-connection w))
         (width  (xact:widget-width w))
         (height (xact:widget-height w))
         (mask  (logior +cw-back-pixel+
                        +cw-event-mask+
                        (if decorated 0 +cw-override-redirect+)))
         (win   (xact:widget-window w)))
    (apply #'xcb::create-window conn 0 win root x y width height 0
            1 0 mask
            (append (list
                     :background-pixel (xeyes-pixel-bg w)
                     :event-mask
                     (logior +event-mask-exposure+
                             +event-mask-key-press+
                             +event-mask-button-press+
                             +event-mask-button-release+
                             +event-mask-button1-motion+
                             +event-mask-enter-window+
                             +event-mask-leave-window+
                             +event-mask-structure-notify+))
                    (unless decorated
                      (list :override-redirect 1))))))

;;; The demo driver.

;; A fresh XEYES-WIDGET for one run on CONN with D's options, placed as
;; they say; nothing on the server is made yet.
(defun make-xeyes (d conn)
  (let ((w (xd:make-application d conn :window (xcb:generate-id conn))))
    ;; Decorated, it is an ordinary managed window; otherwise the WM
    ;; never sees it.
    (setf (xact:toplevel-kind w) (if (xeyes-decorated w) :managed :override-redirect)
          (slot-value w 'positionp) (xd:resolve-placement w)
          (xd:app-x w) (or (xd:app-x w) 100)
          (xd:app-y w) (or (xd:app-y w) 100)
          (xeyes-transform w) (make-fit-transform (xact:widget-width w)
                                                  (xact:widget-height w)))
    w))

;; Make W's window, colours, GCs, pixmaps and, where wanted, RENDER and
;; SHAPE, give a decorated window its WM properties, and add the
;; interactors.  Leaves the window unmapped.
(defun setup-xeyes (w)
  (with-slots (positionp quit) w
    (let* ((win  (xact:widget-window w))
           (decorated (xeyes-decorated w)))
      (xeyes-setup-colors w (xd:app-screen w))
      (xeyes-create-window w (xd:app-root w) decorated (xd:app-x w) (xd:app-y w))
      (xeyes-setup-gcs w)
      (xeyes-recreate-backing-store w)
      (when (xeyes-render-enabled w)
        (xeyes-setup-render w))
      (when (xeyes-shape-enabled w)
        (xeyes-apply-shape w))
      (xact:realize w)
      (when (and decorated positionp)
        (xd:set-placement-hints w))
      (setf quit (make-instance 'xact:quit-interactor :window win))
      (xact:widget-add-interactor w (make-instance 'xact:resize-interactor :window win :widget w))
      (xact:widget-add-interactor w (make-instance 'xeyes-focus :window win :widget w))
      ;; Undecorated, the window has no frame to drag it by.
      (unless decorated
        (xact:widget-add-interactor w (make-instance 'xact:window-drag-interactor
                                                     :window win :widget w)))
      (xact:widget-add-interactor w (make-instance 'xeyes-tick :window win :widget w))
      (xact:widget-add-interactor w quit)
      ;; Last, so in move mode it sees the arrows and Escape before QUIT.
      (xact:widget-add-interactor w (make-instance 'xact:key-move-interactor
                                                   :window win :widget w))
      w)))

;; Free W's RENDER objects, pixmaps, GCs and window.
(defun teardown-xeyes (w)
  (let ((conn (xact:widget-connection w)))
    (xeyes-teardown-render w)
    (ignore-errors
     (when (xeyes-shape-mask w)
       (xcb::free-pixmap conn (xeyes-shape-mask w))))
    (ignore-errors
     (when (xeyes-pixmap w)
       (xcb::free-pixmap conn (xeyes-pixmap w))))
    (dolist (gc (list (xeyes-gc-outline w)
                      (xeyes-gc-center w)
                      (xeyes-gc-pupil w)
                      (xeyes-gc-bg w)))
      (when gc (ignore-errors (xcb::free-gc conn gc))))
    (xact:unrealize w)))

;; Run the xeyes demo body: one XEYES-WIDGET, set up, run and torn down.
(defun run-xeyes (d conn)
  (let ((w (make-xeyes d conn)))
    (unwind-protect
         (let ((win (xact:widget-window w)))
           (setup-xeyes w)
           (format t "~&Drawing backend: ~A~%"
                   (if (xeyes-render-p w)
                       "RENDER (antialiased TriFan)"
                       "PolyFillArc (aliased)"))
           (xact:widget-redraw w win)
           (xact:show w)
           (format t "~&Controls:~%")
           (if (xeyes-decorated w)
               (format t "  q / Escape    exit~%  close via WM  exit~%  Ctrl+m        move with the arrows~%")
               (format t "  ~a~%  q / Escape    exit (hover the eyes first)~%  Ctrl+m        move with the arrows~%"
                       "left-drag     move the window"))
           (xact:run-widget w win
                            :stop-when (lambda () (xact:quit-requested-p (xeyes-quit w)))))
      (teardown-xeyes w)))
  t)

;;; Interactors.

(defclass xeyes-focus (xact:interactor)
  ((widget :initarg :widget :reader xeyes-focus-widget)))

(defun xeyes-focus-in (w)
  (when (xeyes-saved-focus w)
    (return-from xeyes-focus-in))
  (let* ((conn   (xact:widget-connection w))
         (window (xact:widget-window w)))
    (handler-case
        (let* ((cookie (xcb::get-input-focus conn))
               (reply  (xcb::get-input-focus-reply conn cookie)))
          (setf (xeyes-saved-focus w) (slot-value reply 'xcb::focus))
          (xcb::set-input-focus conn +input-focus-pointer-root+ window 0))
      (error ()
        (setf (xeyes-saved-focus w) +input-focus-pointer-root+)))))

(defun xeyes-focus-out (w)
  (let ((prev (xeyes-saved-focus w))
        (conn (xact:widget-connection w)))
    (setf (xeyes-saved-focus w) nil)
    (handler-case
        (cond
          ((null prev)
           (xcb::set-input-focus conn +input-focus-pointer-root+
                                 +input-focus-pointer-root+ 0))
          ((eql prev (xact:widget-window w))
           (xcb::set-input-focus conn +input-focus-pointer-root+
                                 +input-focus-pointer-root+ 0))
          (t
           (xcb::set-input-focus conn +input-focus-pointer-root+ prev 0)))
      (error () nil))))

(defmethod xact:handle-event ((i xeyes-focus) (ev xact:enter-event))
  (xeyes-focus-in (xeyes-focus-widget i))
  t)

(defmethod xact:handle-event ((i xeyes-focus) (ev xact:leave-event))
  (let ((w (xeyes-focus-widget i)))
    ;; A LeaveNotify triggered by a grab (mode = NotifyGrab, 1) is
    ;; transient: typically our own implicit drag grab.  Do not drop
    ;; keyboard focus; otherwise q / Escape stops working until the
    ;; next re-hover.
    (unless (or (xact:widget-dragging-p w)
                (eql (xact:event-mode ev) 1))
      (xeyes-focus-out w)))
  t)

(defclass xeyes-tick (xact:interactor)
  ((widget       :initarg :widget :reader xeyes-tick-widget)
   (delay-index  :initform 0      :accessor xeyes-tick-delay-index)
   (next-poll    :initform 0      :accessor xeyes-tick-next-poll)))

(defmethod xact:handle-tick ((i xeyes-tick))
  (let ((w   (xeyes-tick-widget i))
        (now (get-internal-real-time)))
    (when (>= now (xeyes-tick-next-poll i))
      (if (xeyes-update-pupils w)
          (setf (xeyes-tick-delay-index i) 0)
          (let ((idx (xeyes-tick-delay-index i)))
            (when (and (< (1+ idx) (length *delays*))
                       (/= (aref *delays* (1+ idx)) 0))
              (setf (xeyes-tick-delay-index i) (1+ idx)))))
      (setf (xeyes-tick-next-poll i)
            (+ now (* (aref *delays* (xeyes-tick-delay-index i))
                     (/ internal-time-units-per-second 1000)))))))
