;;; xclock.lisp — XClock port for CLXCB.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; Copyright 1987, 1988 by Digital Equipment Corporation, Maynard,
;;;     Massachusetts.
;;; Copyright 1987, 1988, 1989, 1994, 1998  The Open Group
;;; Copyright (c) 2004, Oracle and/or its affiliates.
;;;
;;; A Common Lisp port of the classic X11 xclock, derived from the
;;; original C implementation (xclock.c, Clock.c, Clock.h, ClockP.h).
;;; Original authors: Tony Della Fera (MIT-Athena, DEC), Dave Mankins
;;; (MIT-Athena, BBN), Ed Moy (UC Berkeley).  Later contributors whose
;;; changes this port reflects: George Belotsky, Steve Swales, Alan
;;; Coopersmith.
;;;
;;; Permission to use, copy, modify, distribute, and sell this software and its
;;; documentation for any purpose is hereby granted without fee, provided that
;;; the above copyright notice appear in all copies and that both that
;;; copyright notice and this permission notice appear in supporting
;;; documentation.
;;;
;;; The above copyright notice and this permission notice shall be included in
;;; all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
;;; THE OPEN GROUP OR DIGITAL EQUIPMENT CORPORATION BE LIABLE FOR ANY CLAIM,
;;; DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
;;; OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
;;; USE OR OTHER DEALINGS IN THE SOFTWARE.
;;;
;;; Except as contained in this notice, the names of The Open Group and Digital
;;; Equipment Corporation shall not be used in advertising or otherwise to
;;; promote the sale, use or other dealings in this Software without prior
;;; written authorization.
;;;
;;; The event loop is driven by xact.
;;;
;;; The clock has three faces — analog, digital short (12-hour), and
;;; digital long (24-hour) — chosen by two independent settings, one per
;;; key:
;;;
;;;   a  switches between the analog face and the digital one.
;;;   t  switches the digital format between 12-hour (:short) and
;;;      24-hour (:long).  On a digital face the change shows at once;
;;;      on the analog face it chooses the format a will show next.
;;;
;;; :mode is the face on screen; :last-digital is the digital format,
;;; kept while the analog face is shown.  It starts as 24-hour unless
;;; --twentyfour is off.

(xd:define-demo :xclock
    (:wm-title "CLXCB xclock"
     :resource-class "XClock"
     :app clock-widget
     :options (:width :height :x :y :geometry
               :background :foreground :hands :highlight
               :font-family :font-subfamily :font-size
               :analog :analog24 :twentyfour :brief :utime :update :chime :padding
               :decorated :grip :render :sync :ewmh-moveresize))
  (format t "~&========================================~%")
  (format t "   CLXCB XClock (demo6)                ~%")
  (format t "========================================~%")
  (run-xclock d conn))

(defconstant +second-hand-fract+  0.90d0)
(defconstant +minute-hand-fract+  0.70d0)
(defconstant +hour-hand-fract+    0.40d0)
(defconstant +hand-width-fract+   0.07d0)
(defconstant +second-width-fract+ 0.05d0)
(defconstant +second-hand-time+   30)
(defconstant +default-size+       164)

(defconstant +x1+ 0.005d0)
(defconstant +x3+ 0.05d0)
(defconstant +y2+ 0.80d0)
(defconstant +y3+ 0.90d0)
(defconstant +y4+ 0.95d0)

(defconstant +grip-size+ 16)
(defconstant +min-size+  80)

(defconstant +help-width+  340)
(defconstant +help-height+ 260)
(defconstant +help-margin+ 12)
(defconstant +help-line-height+ 24)

(alexandria:define-constant +hour-hand-shape+
  (list (cons 0.0d0     +hour-hand-fract+)
        (cons +hand-width-fract+  (- +hand-width-fract+))
        (cons (- +hand-width-fract+) (- +hand-width-fract+)))
  :test #'equal)

(alexandria:define-constant +minute-hand-shape+
  (list (cons 0.0d0     +minute-hand-fract+)
        (cons +hand-width-fract+  (- +hand-width-fract+))
        (cons (- +hand-width-fract+) (- +hand-width-fract+)))
  :test #'equal)

(alexandria:define-constant +second-hand-shape+
  (list (cons 0.0d0       +second-hand-fract+)
        (cons +x3+        +y2+)
        (cons 0.0d0      -0.05d0)
        (cons (- +x3+)    +y2+))
  :test #'equal)

(alexandria:define-constant +major-tick-shape+
  (list (cons +x1+       +y3+)
        (cons (- +x1+)   1.0d0)
        (cons +x1+       1.0d0)
        (cons (- +x1+)   +y3+))
  :test #'equal)

(alexandria:define-constant +minor-tick-shape+
  (list (cons +x1+       +y4+)
        (cons (- +x1+)   1.0d0)
        (cons +x1+       1.0d0)
        (cons (- +x1+)   +y4+))
  :test #'equal)

(alexandria:define-constant +clock-font-candidates+
  '(("DejaVu Sans Mono" "Bold")
    ("Liberation Mono"  "Bold")
    ("Ubuntu Mono"      "Bold")
    ("Noto Sans Mono"   "Bold")
    ("FreeMono"         "Bold")
    ("Courier New"      "Bold")
    ("DejaVu Sans Mono" "Book")
    ("Liberation Mono"  "Regular")
    ("FreeMono"         "Regular"))
  :test #'equal)

(defun clock-angle (tick-units)
  (let ((angle (* tick-units (/ pi 1800.0d0))))
    (values (sin angle) (cos angle))))

(defun current-time-parts ()
  (multiple-value-bind (sec min hour)
      (decode-universal-time (get-universal-time))
    (values sec min hour)))

(defun choose-clock-font ()
  (unless (plusp (hash-table-count xcb-truetype:*font-cache*))
    (xcb-truetype:cache-fonts))
  (loop for (family subfamily) in +clock-font-candidates+
        when (and (gethash family xcb-truetype:*font-cache*)
                  (gethash subfamily (gethash family xcb-truetype:*font-cache*)))
          do (return-from choose-clock-font (values family subfamily)))
  (error "No monospace clock font found among ~{~A~^, ~}"
         (mapcar #'first +clock-font-candidates+)))

(defun resolve-clock-font (family subfamily)
  (if family
      (values family subfamily)
      (choose-clock-font)))

(defun help-text ()
  '("CLXCB xclock - controls"
    ""
    "  a    analog / digital mode"
    "  s    second hand on / off"
    "  t    12 / 24-hour digital"
    "  c    chime on / off"
    "  r    RENDER backend on / off"
    "  ?    show / hide this help"
    "  q    quit (Escape also)"))

(defclass clock-model ()
  ((state :initarg :state
          :initform (make-instance 'xact:state)
          :reader model-state)))

(defgeneric model-of (object)
  (:documentation "Return the CLOCK-MODEL that OBJECT reads from."))

(defmethod model-of ((m clock-model)) m)

(defmacro defmodel-cell (name key &key writable)
  `(progn
     (defun ,name (x) (xact:cref (model-state (model-of x)) ,key))
     ,@(when writable
         `((defun (setf ,name) (v x)
             (setf (xact:cref (model-state (model-of x)) ,key) v))))))

(defmodel-cell model-mode          :mode          :writable t)
(defmodel-cell model-last-digital  :last-digital  :writable t)
(defmodel-cell model-analog-p      :analog-p)
(defmodel-cell model-short-p       :short-p)
(defmodel-cell model-long-p        :long-p)
(defmodel-cell model-brief-p       :brief)
(defmodel-cell model-utime-p       :utime)
(defmodel-cell model-analog24-p    :analog24)
(defmodel-cell model-update-secs   :update-secs)
(defmodel-cell model-padding       :padding)
(defmodel-cell model-width         :width         :writable t)
(defmodel-cell model-height        :height        :writable t)
(defmodel-cell model-second-hand-p :second-hand   :writable t)
(defmodel-cell model-chime-p       :chime         :writable t)
(defmodel-cell model-chime-beeped-p :chime-beeped :writable t)
(defmodel-cell model-center-x      :center-x)
(defmodel-cell model-center-y      :center-y)
(defmodel-cell model-radius        :radius)

(defun make-clock-model (&key (mode :analog)
                              (last-digital :long)
                              (brief nil)
                              (utime nil)
                              (update-secs 1.0d0)
                              (padding 8)
                              (width +default-size+)
                              (height +default-size+)
                              (second-hand t)
                              (analog24 nil)
                              (chime nil))
  (let* ((s (make-instance 'xact:state))
         (m (make-instance 'clock-model :state s)))
    (setf (xact:cref s :mode)          mode
          (xact:cref s :last-digital)  last-digital
          (xact:cref s :brief)         brief
          (xact:cref s :utime)         utime
          (xact:cref s :update-secs)   update-secs
          (xact:cref s :padding)       padding
          (xact:cref s :width)         width
          (xact:cref s :height)        height
          (xact:cref s :second-hand)   second-hand
          (xact:cref s :analog24)      analog24
          (xact:cref s :chime)         chime
          (xact:cref s :chime-beeped)  nil)
    (xact:install-formula s :analog-p
                          (lambda () (eq (xact:cref s :mode) :analog)))
    (xact:install-formula s :short-p
                          (lambda () (eq (xact:cref s :mode) :short)))
    (xact:install-formula s :long-p
                          (lambda () (eq (xact:cref s :mode) :long)))
    (xact:install-formula s :center-x
                          (lambda () (truncate (xact:cref s :width) 2)))
    (xact:install-formula s :center-y
                          (lambda () (truncate (xact:cref s :height) 2)))
    (xact:install-formula s :radius
                          (lambda ()
                            (max 1 (truncate
                                    (- (min (xact:cref s :width)
                                            (xact:cref s :height))
                                       (* 2 (xact:cref s :padding)))
                                    2))))
    m))

(defclass clock-view () ())

(defgeneric draw-face (view widget sec min hour))
(defgeneric face-name (view))

(defclass analog-view (clock-view) ())

(defmethod face-name ((v analog-view)) "analog")

(defun clock-transform-shape-point (w local-x local-y sin cos)
  (let* ((radius   (model-radius w))
         (center-x (model-center-x w))
         (center-y (model-center-y w))
         (x (+ center-x (* (+ (* local-x cos) (* local-y sin)) radius)))
         (y (+ center-y (* (- (* local-x sin) (* local-y cos)) radius))))
    (values x y)))

(defun shape->points (w shape tick-units)
  (multiple-value-bind (sin cos) (clock-angle tick-units)
    (mapcar (lambda (p)
              (multiple-value-bind (x y)
                  (clock-transform-shape-point w (car p) (cdr p) sin cos)
                (make-instance 'xcb::point :x (round x) :y (round y))))
            shape)))

(defun shape->triangles (w shape tick-units)
  (multiple-value-bind (sin cos) (clock-angle tick-units)
    (flet ((mk (p)
             (multiple-value-bind (x y)
                 (clock-transform-shape-point w (car p) (cdr p) sin cos)
               (make-instance 'xcb-render::pointfix
                              :x (round (* x 65536.0d0))
                              :y (round (* y 65536.0d0))))))
      (let ((pts (coerce shape 'vector))
            (n   (length shape))
            (tris '()))
        (loop for i from 1 below (1- n)
              do (push (make-instance 'xcb-render::triangle
                                      :p1 (mk (aref pts 0))
                                      :p2 (mk (aref pts i))
                                      :p3 (mk (aref pts (1+ i))))
                       tris))
        (nreverse tris)))))

(defun classic-tick-segment (w blank length tick-units)
  (multiple-value-bind (sin cos) (clock-angle tick-units)
    (make-instance 'xcb::segment
                   :x1 (+ (model-center-x w) (round (* blank sin)))
                   :y1 (- (model-center-y w) (round (* blank cos)))
                   :x2 (+ (model-center-x w) (round (* length sin)))
                   :y2 (- (model-center-y w) (round (* length cos))))))

(defun classic-draw-ticks (w)
  (let* ((conn (xact:widget-connection w))
         (radius (model-radius w))
         (step (if (model-analog24-p w) 5 10))
         (second-len (round (* +second-hand-fract+ radius)))
         (delta (truncate (- radius
                             (round (* +second-hand-fract+ radius)))
                          3))
         (segments '()))
    (loop for i from 0 below 120
          for units = (* i 30)
          for hour-p   = (zerop (mod i step))
          for minute-p = (and (not hour-p) (zerop (mod i 2)))
          do (when hour-p
               (push (classic-tick-segment w second-len radius units) segments))
             (when minute-p
               (push (classic-tick-segment w (- radius delta) radius units)
                     segments)))
    (when segments
      (xcb::poly-segment conn (widget-pixmap w) (widget-gc-face w)
                         (nreverse segments)))))

(defun classic-fill-convex (w points)
  (when (plusp (length points))
    (when (/= (widget-pixel-hands w) (widget-pixel-bg w))
      (xcb::fill-poly (xact:widget-connection w)
                      (widget-pixmap w) (widget-gc-hands w)
                      2 0 points))
    (xcb::poly-line (xact:widget-connection w) 0
                    (widget-pixmap w) (widget-gc-highlight w)
                    (append points (list (first points))))))

(defun render-batch (w triangles fill-picture)
  (when triangles
    (xcb-render::triangles (xact:widget-connection w)
                           +render-pict-op-over+
                           fill-picture
                           (widget-render-window-picture w)
                           (widget-render-mask-format w)
                           0 0
                           triangles)))

(defun render-draw-ticks (w)
  (let* ((step (if (model-analog24-p w) 5 10))
         (tris (loop for i from 0 below 120
                     for units = (* i 30)
                     for hour-p   = (zerop (mod i step))
                     for minute-p = (and (not hour-p) (zerop (mod i 2)))
                     append (cond (hour-p
                                   (shape->triangles w +major-tick-shape+ units))
                                  (minute-p
                                   (shape->triangles w +minor-tick-shape+ units))
                                  (t nil)))))
    (render-batch w tris (widget-render-fill-ticks w))))

(defun render-draw-shape (w shape tick-units fill-picture)
  (render-batch w (shape->triangles w shape tick-units) fill-picture))

(defmethod draw-face ((v analog-view) w sec min hour)
  (let ((min-units  (+ (* min 60) sec))
        (hour-units (let ((u (+ (* hour 300) (* min 5))))
                      (if (model-analog24-p w) (truncate u 2) u)))
        (sec-units  (* sec 60)))
    (if (widget-render-p w)
        (progn
          (render-draw-ticks w)
          (render-draw-shape w +minute-hand-shape+ min-units
                             (widget-render-fill-hands w))
          (render-draw-shape w +hour-hand-shape+ hour-units
                             (widget-render-fill-hands w))
          (when (model-second-hand-p w)
            (render-draw-shape w +second-hand-shape+ sec-units
                               (widget-render-fill-hands w))))
        (progn
          (classic-draw-ticks w)
          (classic-fill-convex w (shape->points w +minute-hand-shape+ min-units))
          (classic-fill-convex w (shape->points w +hour-hand-shape+ hour-units))
          (when (model-second-hand-p w)
            (classic-fill-convex w
                                 (shape->points w +second-hand-shape+ sec-units)))))))

(defclass digital-view (clock-view) ())

(defgeneric format-time (view widget sec min hour))

(defmethod draw-face ((v digital-view) w sec min hour)
  (let* ((string (format-time v w sec min hour))
         (width  (model-width w))
         (height (model-height w))
         (box-w  (* width  9/10))
         (box-h  (* height 4/5))
         (size (or (widget-font-size-opt w)
                   (xcb-truetype:fit-font-size
                    (widget-digital-drawable w)
                    (widget-digital-font-family w)
                    (widget-digital-font-subfamily w)
                    string box-w box-h))))
    (if (null (widget-digital-font w))
        (setf (widget-digital-font w)
              (make-instance 'xcb-truetype:font
                             :family    (widget-digital-font-family w)
                             :subfamily (widget-digital-font-subfamily w)
                             :size      size))
        (unless (= size (xcb-truetype:font-size (widget-digital-font w)))
          (setf (xcb-truetype:font-size (widget-digital-font w)) size)))
    (multiple-value-bind (bx by)
        (xcb-truetype:text-center (widget-digital-drawable w)
                                  (widget-digital-font w)
                                  string width height)
      (xcb-truetype:draw-text-line (widget-digital-drawable w)
                                   (widget-digital-font w)
                                   string bx by
                                   :colour (widget-pixel-fg w)))))

(defclass digital-short-view (digital-view) ())

(defmethod face-name ((v digital-short-view)) "digital, 12-hour")

(defmethod format-time ((v digital-short-view) w sec min hour)
  (let ((h12 (if (zerop (mod hour 12)) 12 (mod hour 12)))
        (ampm (if (< hour 12) "AM" "PM")))
    (if (model-brief-p w)
        (format nil "~2,'0D:~2,'0D ~A" h12 min ampm)
        (format nil "~2,'0D:~2,'0D:~2,'0D ~A" h12 min sec ampm))))

(defclass digital-long-view (digital-view) ())

(defmethod face-name ((v digital-long-view)) "digital, 24-hour")

(defmethod format-time ((v digital-long-view) w sec min hour)
  (if (model-brief-p w)
      (format nil "~2,'0D:~2,'0D" hour min)
      (format nil "~2,'0D:~2,'0D:~2,'0D" hour min sec)))

(defun format-utime (w)
  (declare (ignore w))
  (format nil "~D seconds since Epoch" (get-universal-time)))

(defclass clock-help-window ()
  ((owner   :initarg :owner   :reader help-owner
            :documentation "The CLOCK-WIDGET whose help this is.")
   (xid     :initarg :xid     :reader help-xid)
   (bg      :initarg :bg      :reader help-bg)
   (fg      :initarg :fg      :reader help-fg)
   (font    :initform nil     :accessor help-font)
   (visible :initform nil     :accessor help-visible-p)))

(defun help-conn (hw)
  (xact:widget-connection (help-owner hw)))

(defun make-clock-help-window (w bg fg)
  (let* ((conn (xact:widget-connection w))
         (win  (xcb:generate-id conn)))
    (xcb::create-window conn 0 win (xd:app-root w)
                        0 0 +help-width+ +help-height+ 1 1 0
                        (logior +cw-back-pixel+ +cw-border-pixel+
                                +cw-event-mask+ +cw-override-redirect+)
                        :background-pixel bg
                        :border-pixel     fg
                        :override-redirect 1
                        :event-mask +event-mask-exposure+)
    (xcb:set-wm-name conn win "CLXCB xclock help")
    (make-instance 'clock-help-window
                   :owner w :xid win :bg bg :fg fg)))

(defun help-draw (hw)
  (let* ((conn (help-conn hw))
         (font (or (help-font hw)
                   (setf (help-font hw)
                         (make-instance 'xcb-truetype:font
                                        :family    "DejaVu Sans Mono"
                                        :subfamily "Book"
                                        :size      12))))
         (screen (xd:app-screen (help-owner hw)))
         (wrap (make-instance 'xcb-truetype:window
                              :connection conn
                              :id     (help-xid hw)
                              :visual (xcb:root-visual screen)
                              :screen screen)))
    (trivial-garbage:cancel-finalization wrap)
    (unwind-protect
         (loop for line in (help-text)
               for i from 0
               do (xcb-truetype:draw-text wrap font line
                                          +help-margin+
                                          (+ +help-margin+
                                             (* (1+ i) +help-line-height+))
                                          :colour (help-fg hw)))
      (when (xcb-truetype:drawable-picture wrap)
        (xcb-render:free-picture conn (xcb-truetype:drawable-picture wrap))))))

(defun help-show (hw parent-x parent-y parent-w)
  (let ((conn (help-conn hw)))
    (xcb::configure-window conn (help-xid hw)
                           (logior +config-window-x+ +config-window-y+)
                           :x (+ parent-x parent-w 10)
                           :y parent-y)
    (xcb::map-window conn (help-xid hw))
    (setf (help-visible-p hw) t)))

(defun help-hide (hw)
  (xcb::unmap-window (help-conn hw) (help-xid hw))
  (setf (help-visible-p hw) nil))

(defun help-destroy (hw)
  (ignore-errors (xcb::destroy-window (help-conn hw) (help-xid hw))))

(defclass clock-widget (xd:application)
  ;; Everything one run needs: its options, the clock's model and views,
  ;; how its window is placed, its colours, GCs, pixmaps and fonts, and
  ;; the quit interactor.  The size lives in the model once it is made
  ;; (see the WIDGET-WIDTH methods); an unrequested position is 100, 100.
  ((model :initform nil :reader widget-model)
   (position-p :initform nil :documentation "True when the user asked for a position.")
   (quit       :initform nil :reader widget-quit
               :documentation "The CLOCK-QUIT interactor that ends the run.")

   (analog-view :initform (make-instance 'analog-view) :reader widget-analog-view)
   (short-view  :initform (make-instance 'digital-short-view) :reader widget-short-view)
   (long-view   :initform (make-instance 'digital-long-view)  :reader widget-long-view)

   (help :initform nil :accessor widget-help)

   ;; Options for the model, read once when it is made.
   (analog     :initarg :analog     :initform t   :type boolean
               :documentation "start with the analog face")
   (analog24   :initarg :analog24   :initform nil :type boolean
               :documentation "24-hour analog dial")
   (twentyfour :initarg :twentyfour :initform t   :type boolean
               :documentation "24-hour digital face; NIL for 12-hour")
   (brief      :initarg :brief      :initform nil :type boolean
               :documentation "digital face without the date")
   (utime      :initarg :utime      :initform nil :type boolean
               :documentation "digital face shows seconds since the epoch")
   (update     :initarg :update     :initform 1.0 :type (real (0))
               :documentation "seconds between updates; the second hand shows up to 30")
   (chime      :initarg :chime      :initform nil :type boolean
               :documentation "beep on the hour and half hour")
   (padding    :initarg :padding    :initform 8   :type (integer 0)
               :documentation "pixels between the face and the window edge")

   (decorated   :initarg :decorated   :initform nil :type boolean :reader widget-decorated-p
                :documentation "let the WM decorate the window")
   (grip        :initarg :grip        :initform t   :type boolean :reader widget-grip-p
                :documentation "show a resize grip in the bottom-right corner")
   (use-render  :initarg :render      :initform t   :type boolean :reader widget-use-render-p
                :documentation "use the RENDER extension when available")
   (use-sync    :initarg :sync        :initform t   :type boolean :reader widget-use-sync-p
                :documentation "use _NET_WM_SYNC_REQUEST for smooth resizes")
   (ewmh        :initarg :ewmh-moveresize :initform t :type boolean :reader widget-ewmh-p
                :documentation "move and resize through the WM (_NET_WM_MOVERESIZE)")

   (bg-opt       :initarg :background :initform nil :type (or null string integer)
                 :reader widget-bg-opt :documentation "background colour")
   (fg-opt       :initarg :foreground :initform nil :type (or null string integer)
                 :reader widget-fg-opt :documentation "foreground colour")
   (hands-opt    :initarg :hands      :initform nil :type (or null string integer)
                 :reader widget-hands-opt :documentation "colour of the hands")
   (highlight-opt :initarg :highlight :initform nil :type (or null string integer)
                  :reader widget-highlight-opt :documentation "colour of the hands' edges")
   (font-family-opt    :initarg :font-family    :initform nil :type (or null string)
                       :reader widget-font-family-opt
                       :documentation "font family of the digital face")
   (font-subfamily-opt :initarg :font-subfamily :initform nil :type (or null string)
                       :reader widget-font-subfamily-opt
                       :documentation "font subfamily (style) of the digital face")
   (font-size-opt      :initarg :font-size      :initform nil :type (or null (integer 1))
                       :reader widget-font-size-opt
                       :documentation "font size of the digital face; NIL to fit the window")

   (pixel-bg        :initform 0 :accessor widget-pixel-bg)
   (pixel-fg        :initform 0 :accessor widget-pixel-fg)
   (pixel-hands     :initform 0 :accessor widget-pixel-hands)
   (pixel-highlight :initform 0 :accessor widget-pixel-highlight)

   (pixmap     :initform nil :accessor widget-pixmap)
   (paint-w    :initform 0   :accessor widget-paint-w)
   (paint-h    :initform 0   :accessor widget-paint-h)

   (gc-bg        :initform nil :accessor widget-gc-bg)
   (gc-face      :initform nil :accessor widget-gc-face)
   (gc-hands     :initform nil :accessor widget-gc-hands)
   (gc-highlight :initform nil :accessor widget-gc-highlight)

   (digital-font-family    :initform nil :accessor widget-digital-font-family)
   (digital-font-subfamily :initform nil :accessor widget-digital-font-subfamily)
   (digital-font     :initform nil :accessor widget-digital-font)
   (digital-drawable :initform nil :accessor widget-digital-drawable)

   (render-format           :initform nil :accessor widget-render-format)
   (render-p                :initform nil :accessor widget-render-p)
   (render-window-picture   :initform nil :accessor widget-render-window-picture)
   (render-fill-hands       :initform nil :accessor widget-render-fill-hands)
   (render-fill-ticks       :initform nil :accessor widget-render-fill-ticks)
   (render-mask-format      :initform nil :accessor widget-render-mask-format)

   (saved-focus :initform nil :accessor widget-saved-focus)

   (next-tick :initform 0 :accessor widget-next-tick)

   (sync-counter          :initform nil :accessor widget-sync-counter)
   (wm-sync-request-atom  :initform nil :accessor widget-wm-sync-request-atom)
   (wm-protocols-atom     :initform nil :accessor widget-wm-protocols-atom)
   (pending-sync          :initform nil :accessor widget-pending-sync)
   (pending-sync-lo       :initform 0   :accessor widget-pending-sync-lo)
   (pending-sync-hi       :initform 0   :accessor widget-pending-sync-hi)
   (sync-p                :initform nil :accessor widget-sync-p)

   ;; Where the help window was when a drag of the clock began, so it
   ;; can follow (see CLOCK-HELP-FOLLOW).
   (drag-anchor-help-x :initform 0 :accessor widget-drag-anchor-help-x)
   (drag-anchor-help-y :initform 0 :accessor widget-drag-anchor-help-y))
  (:default-initargs :width +default-size+ :height +default-size+))

(defmethod model-of ((w clock-widget)) (widget-model w))

(defmethod xact:widget-width ((w clock-widget))
  (if (widget-model w) (model-width w) (call-next-method)))
(defmethod (setf xact:widget-width) (v (w clock-widget))
  (if (widget-model w) (setf (model-width w) v) (call-next-method)))
(defmethod xact:widget-height ((w clock-widget))
  (if (widget-model w) (model-height w) (call-next-method)))
(defmethod (setf xact:widget-height) (v (w clock-widget))
  (if (widget-model w) (setf (model-height w) v) (call-next-method)))

(defun widget-current-view (w)
  (ecase (model-mode w)
    (:analog (widget-analog-view w))
    (:short  (widget-short-view w))
    (:long   (widget-long-view w))))

(defun draw-grip (w)
  (when (widget-grip-p w)
    (xact:draw-resize-grip (xact:widget-connection w) (widget-pixmap w) (widget-gc-face w)
                           (model-width w) (model-height w) :size +grip-size+)))

(defun widget-present (w)
  (xcb::copy-area (xact:widget-connection w)
                  (widget-pixmap w)
                  (xact:widget-window w)
                  (widget-gc-bg w)
                  0 0 0 0
                  (model-width w)
                  (model-height w)))

(defun widget-redraw-all (w)
  (let ((conn (xact:widget-connection w)))
    (xcb::poly-fill-rectangle
     conn (widget-pixmap w) (widget-gc-bg w)
     (list (make-instance 'xcb::rectangle
                          :x 0 :y 0
                          :width  (model-width w)
                          :height (model-height w))))
    (if (model-utime-p w)
        (let* ((string (format-utime w))
               (width  (model-width w))
               (height (model-height w))
               (size (or (widget-font-size-opt w)
                         (xcb-truetype:fit-font-size
                          (widget-digital-drawable w)
                          (widget-digital-font-family w)
                          (widget-digital-font-subfamily w)
                          string (* width 9/10) (* height 4/5)))))
          (if (null (widget-digital-font w))
              (setf (widget-digital-font w)
                    (make-instance 'xcb-truetype:font
                                   :family    (widget-digital-font-family w)
                                   :subfamily (widget-digital-font-subfamily w)
                                   :size      size))
              (unless (= size (xcb-truetype:font-size (widget-digital-font w)))
                (setf (xcb-truetype:font-size (widget-digital-font w)) size)))
          (multiple-value-bind (bx by)
              (xcb-truetype:text-center (widget-digital-drawable w)
                                        (widget-digital-font w)
                                        string width height)
            (xcb-truetype:draw-text-line (widget-digital-drawable w)
                                         (widget-digital-font w)
                                         string bx by
                                         :colour (widget-pixel-fg w))))
        (multiple-value-bind (sec min hour) (current-time-parts)
          (draw-face (widget-current-view w) w sec min hour)))
    (draw-grip w)
    (widget-present w)))

(defmethod xact:draw ((w clock-widget) surface)
  (declare (ignore surface))
  (let ((nw (model-width w))
        (nh (model-height w)))
    (unless (and (= nw (widget-paint-w w))
                 (= nh (widget-paint-h w)))
      (widget-recreate-backing-store w)))
  (widget-redraw-all w)
  (widget-ack-sync w))

(defun clock-maybe-chime (w min)
  (when (model-chime-p w)
    (cond
      ((and (or (= min 0) (= min 30)) (not (model-chime-beeped-p w)))
       (setf (model-chime-beeped-p w) t)
       (ignore-errors (xcb::bell (xact:widget-connection w) 50))
       (when (= min 0)
         (ignore-errors (xcb::bell (xact:widget-connection w) 50))))
      ((and (/= min 0) (/= min 30))
       (setf (model-chime-beeped-p w) nil)))))

(defun clock-focus-in (w)
  (when (widget-saved-focus w) (return-from clock-focus-in))
  (let ((conn (xact:widget-connection w)))
    (handler-case
        (let* ((cookie (xcb::get-input-focus conn))
               (reply  (xcb::get-input-focus-reply conn cookie)))
          (setf (widget-saved-focus w) (slot-value reply 'xcb::focus))
          (xcb::set-input-focus conn +input-focus-pointer-root+
                                (xact:widget-window w) 0))
      (error ()
        (setf (widget-saved-focus w) +input-focus-pointer-root+)))))

(defun clock-focus-out (w)
  (let ((prev (widget-saved-focus w))
        (conn (xact:widget-connection w)))
    (setf (widget-saved-focus w) nil)
    (handler-case
        (cond
          ((or (null prev) (eql prev (xact:widget-window w)))
           (xcb::set-input-focus conn +input-focus-pointer-root+
                                 +input-focus-pointer-root+ 0))
          (t
           (xcb::set-input-focus conn +input-focus-pointer-root+ prev 0)))
      (error () nil))))

(defun clock-set-mode (w new)
  "Show face NEW (:ANALOG, :SHORT or :LONG).  A digital face also
   becomes the remembered digital format, which a returns to."
  (unless (eq (model-mode w) new)
    (unless (eq new :analog)
      (setf (model-last-digital w) new))
    (setf (model-mode w) new)
    (setf (xact:widget-dirty-p w) t)
    (format t "~&mode: ~A~%" new)))

(defun clock-toggle-digital (w)
  "t: switch the digital format between 12-hour (:short) and 24-hour
   (:long).  On a digital face the new format shows at once; on the
   analog face it becomes the format a shows next."
  (let ((format (if (eq (model-last-digital w) :long) :short :long)))
    (if (eq (model-mode w) :analog)
        (progn
          (setf (model-last-digital w) format)
          (format t "~&digital format: ~:[12~;24~]-hour~%" (eq format :long)))
        (clock-set-mode w format))))

(defun clock-toggle-analog (w)
  "a: from the analog face, show the digital one in the remembered
   format; from a digital face, show the analog one."
  (clock-set-mode w (if (eq (model-mode w) :analog)
                        (model-last-digital w)
                        :analog)))

(defun clock-toggle-second-hand (w)
  (setf (model-second-hand-p w) (not (model-second-hand-p w)))
  (when (model-analog-p w) (setf (xact:widget-dirty-p w) t))
  (format t "~&second hand: ~:[off~;on~]~%" (model-second-hand-p w)))

(defun clock-toggle-chime (w)
  (setf (model-chime-p w) (not (model-chime-p w)))
  (format t "~&chime: ~:[off~;on~]~%" (model-chime-p w)))

(defun clock-toggle-render (w)
  (cond
    ((null (widget-render-window-picture w))
     (format t "~&RENDER not available~%"))
    (t
     (setf (widget-render-p w) (not (widget-render-p w)))
     (setf (xact:widget-dirty-p w) t)
     (format t "~&RENDER backend: ~:[off~;on~]~%" (widget-render-p w)))))

(defun clock-help-show (w)
  (unless (widget-help w)
    (setf (widget-help w)
          (make-clock-help-window w
                                  (widget-pixel-bg w)
                                  (widget-pixel-fg w))))
  (let ((conn (xact:widget-connection w)))
    (multiple-value-bind (rx ry)
        (xcb:window-root-position conn (xact:widget-window w))
      (help-show (widget-help w) rx ry (model-width w)))))

(defun clock-help-hide (w)
  (when (widget-help w)
    (help-hide (widget-help w))))

(defun clock-help-visible-p (w)
  (and (widget-help w) (help-visible-p (widget-help w))))

(defun clock-help-toggle (w)
  (if (clock-help-visible-p w)
      (clock-help-hide w)
      (clock-help-show w)))

(defun clock-help-follow-start (i)
  "Remember where the help window is when a drag of the clock starts."
  (let ((w (xact:interactor-widget i)))
    (when (clock-help-visible-p w)
      (multiple-value-bind (hx hy)
          (xcb:window-root-position (xact:widget-connection w)
                                    (help-xid (widget-help w)))
        (setf (widget-drag-anchor-help-x w) hx
              (widget-drag-anchor-help-y w) hy)))))

(defun clock-help-follow (i dx dy)
  "Move the help window along with the clock, by the drag's DX DY."
  (let ((w (xact:interactor-widget i)))
    (when (clock-help-visible-p w)
      (xcb::configure-window (xact:widget-connection w) (help-xid (widget-help w))
                             (logior +config-window-x+ +config-window-y+)
                             :x (+ (widget-drag-anchor-help-x w) dx)
                             :y (+ (widget-drag-anchor-help-y w) dy)))))

(defun clock-setup-sync (w)
  (unless (widget-use-sync-p w) (return-from clock-setup-sync nil))
  (when (widget-decorated-p w) (return-from clock-setup-sync nil))
  (let* ((conn (xact:widget-connection w))
         (info (handler-case (xcb:ensure-extension conn "XCB-SYNC")
                 (error () nil))))
    (unless (and info (getf info :present))
      (return-from clock-setup-sync nil)))
  (handler-case
      (let* ((conn (xact:widget-connection w))
             (window (xact:widget-window w))
             (counter-xid (xcb:generate-id conn))
             (sync-req-atom (xcb:intern-atom-id conn "_NET_WM_SYNC_REQUEST"))
             (sync-ctr-atom (xcb:intern-atom-id conn "_NET_WM_SYNC_REQUEST_COUNTER"))
             (cardinal-atom (xcb:intern-atom-id conn "CARDINAL"))
             (atom-type (xcb:intern-atom-id conn "ATOM"))
             (wm-protocols (xcb:intern-atom-id conn "WM_PROTOCOLS")))
        (let ((cookie (xcb-sync::initialize conn 3 1)))
          (xcb-sync::initialize-reply conn cookie))
        (xcb-sync::create-counter conn counter-xid
                                  (make-instance 'xcb-sync::int64 :hi 0 :lo 0))
        (xcb:send-change-property conn 0 window sync-ctr-atom cardinal-atom 32
                                  (list counter-xid))
        (xcb:send-change-property conn 2 window wm-protocols atom-type 32
                                  (list sync-req-atom))
        (setf (widget-sync-counter w) counter-xid
              (widget-wm-sync-request-atom w) sync-req-atom
              (widget-wm-protocols-atom w) wm-protocols)
        t)
    (error () nil)))

(defun widget-ack-sync (w)
  (when (and (widget-pending-sync w) (widget-sync-counter w))
    (let ((conn (xact:widget-connection w)))
      (xcb-sync::set-counter conn (widget-sync-counter w)
                             (make-instance 'xcb-sync::int64
                                            :hi (widget-pending-sync-hi w)
                                            :lo (widget-pending-sync-lo w))))
    (setf (widget-pending-sync w) nil)))

(defun clock-handle-sync-message (w ev)
  (when (and (widget-sync-p w)
             (widget-wm-sync-request-atom w)
             (= (slot-value ev 'xcb::format) 32)
             (= (slot-value ev 'xcb::type)
                (or (widget-wm-protocols-atom w)
                    (xcb:intern-atom-id (xact:widget-connection w)
                                        "WM_PROTOCOLS"))))
    (let ((d (slot-value (slot-value ev 'xcb::data) 'xcb::data32)))
      (when (and d (>= (length d) 4)
                 (eql (elt d 0) (widget-wm-sync-request-atom w)))
        (setf (widget-pending-sync-lo w) (elt d 2)
              (widget-pending-sync-hi w) (elt d 3)
              (widget-pending-sync w)    t)
        (setf (xact:widget-dirty-p w) t)
        t))))

(defun clock-setup-colors (w screen)
  (let ((conn (xact:widget-connection w)))
    (setf (widget-pixel-bg w)
          (xcb:parse-color conn screen (widget-bg-opt w) (xcb:white-pixel screen))
          (widget-pixel-fg w)
          (xcb:parse-color conn screen (widget-fg-opt w) (xcb:black-pixel screen))
          (widget-pixel-hands w)
          (xcb:parse-color conn screen (widget-hands-opt w)
                           (widget-pixel-fg w))
          (widget-pixel-highlight w)
          (xcb:parse-color conn screen (widget-highlight-opt w)
                           (widget-pixel-fg w)))))

(defun clock-setup-gcs (w)
  (let ((conn (xact:widget-connection w))
        (window (xact:widget-window w)))
    (setf (widget-gc-face w)      (xcb:generate-id conn)
          (widget-gc-hands w)     (xcb:generate-id conn)
          (widget-gc-highlight w) (xcb:generate-id conn)
          (widget-gc-bg w)        (xcb:generate-id conn))
    (xcb::create-gc conn (widget-gc-face w) window +gc-foreground+
                    :foreground (widget-pixel-fg w))
    (xcb::create-gc conn (widget-gc-hands w) window +gc-foreground+
                    :foreground (widget-pixel-hands w))
    (xcb::create-gc conn (widget-gc-highlight w) window +gc-foreground+
                    :foreground (widget-pixel-highlight w))
    (xcb::create-gc conn (widget-gc-bg w) window +gc-foreground+
                    :foreground (widget-pixel-bg w))))

(defun clock-setup-render (w)
  (let* ((conn (xact:widget-connection w))
         (info (handler-case (xcb:ensure-extension conn "XCB-RENDER")
                 (error (e)
                   (format t "~&RENDER: ensure-extension failed: ~A~%" e)
                   nil))))
    (unless (and info (getf info :present))
      (format t "~&RENDER: extension not reported present by server.~%")
      (return-from clock-setup-render nil)))
  (handler-case
      (let* ((conn (xact:widget-connection w))
             (screen (xd:app-screen w))
             (visual (xcb:root-visual screen))
             (reply (xcb-truetype:pict-formats-reply-for conn))
             (format (xcb-render:find-visual-pict-format reply visual))
             (a8 (xcb-render:find-standard-pict-format
                  reply xcb-render:+pict-standard-a8+)))
        (unless a8
          (format t "~&RENDER: A8 PictFormat not found; falling back.~%")
          (return-from clock-setup-render nil))
        (unless format
          (format t "~&RENDER: no PictFormat for visual #x~X.~%" visual)
          (return-from clock-setup-render nil))
        (setf (widget-render-mask-format w) a8
              (widget-render-format w) format)
        (setf (widget-render-window-picture w)
              (xcb-truetype:drawable-picture-for
               (widget-digital-drawable w) format))
        (setf (widget-render-fill-hands w) (xcb:generate-id conn)
              (widget-render-fill-ticks w) (xcb:generate-id conn))
        (flet ((pixel->color (p)
                 (let ((r (logand (ash p -16) #xFF))
                       (g (logand (ash p -8)  #xFF))
                       (b (logand p #xFF)))
                   (xcb-render:make-color (logior (ash r 8) r)
                                          (logior (ash g 8) g)
                                          (logior (ash b 8) b)))))
          (xcb-render:create-solid-fill conn (widget-render-fill-hands w)
                                        (pixel->color (widget-pixel-hands w)))
          (xcb-render:create-solid-fill conn (widget-render-fill-ticks w)
                                        (pixel->color (widget-pixel-fg w))))
        (setf (widget-render-p w) t)
        t)
    (error (e)
      (format t "~&RENDER: setup failed: ~A~%" e)
      nil)))

(defun clock-teardown-render (w)
  (let ((conn (xact:widget-connection w)))
    (when (widget-render-fill-hands w)
      (ignore-errors (xcb-render:free-picture conn (widget-render-fill-hands w)))
      (setf (widget-render-fill-hands w) nil))
    (when (widget-render-fill-ticks w)
      (ignore-errors (xcb-render:free-picture conn (widget-render-fill-ticks w)))
      (setf (widget-render-fill-ticks w) nil))
    (setf (widget-render-window-picture w) nil
          (widget-render-p w) nil
          (widget-render-mask-format w) nil)))

(defun widget-recreate-backing-store (w)
  (let ((conn (xact:widget-connection w))
        (window (xact:widget-window w)))
    (when (widget-digital-drawable w)
      (trivial-garbage:cancel-finalization (widget-digital-drawable w))
      (ignore-errors (xcb-truetype:destroy-drawable (widget-digital-drawable w)))
      (setf (widget-digital-drawable w) nil))
    (setf (widget-pixmap w) nil (widget-render-window-picture w) nil)
    (let* ((screen (xd:app-screen w))
           (width  (model-width w))
           (height (model-height w)))
      (setf (widget-pixmap w) (xcb:generate-id conn))
      (xcb::create-pixmap conn (xcb:root-depth screen)
                          (widget-pixmap w) window width height)
      (setf (widget-digital-drawable w)
            (make-instance 'xcb-truetype:pixmap :owned t
                           :connection conn :id (widget-pixmap w)))
      (trivial-garbage:cancel-finalization (widget-digital-drawable w))
      (when (widget-render-format w)
        (setf (widget-render-window-picture w)
              (xcb-truetype:drawable-picture-for
               (widget-digital-drawable w) (widget-render-format w))))
      (setf (widget-paint-w w) width
            (widget-paint-h w) height))))

(defun clock-create-window (w x y)
  (let* ((conn (xact:widget-connection w))
         (root (xcb:root-window conn))
         (win  (xact:widget-window w)))
    (apply #'xcb::create-window conn 0 win root x y
           (model-width w) (model-height w) 0
           1 0 (logior +cw-back-pixel+ +cw-event-mask+)
           (list
            :background-pixel (widget-pixel-bg w)
            :event-mask
            (logior +event-mask-exposure+
                    +event-mask-key-press+
                    +event-mask-button-press+
                    +event-mask-button-release+
                    +event-mask-button1-motion+
                    +event-mask-enter-window+
                    +event-mask-leave-window+
                    +event-mask-structure-notify+)))))

(defclass clock-quit (xact:quit-interactor)
  ((widget :initarg :widget :reader quit-widget))
  (:documentation "Q, Escape and the close button quit, except that
   Escape first closes the help window if it is open."))

(defmethod xact:handle-event ((i clock-quit) (ev xact:key-press))
  (if (and (eql (xact:event-keysym ev) :escape)
           (clock-help-visible-p (quit-widget i)))
      (progn (clock-help-hide (quit-widget i)) t)
      (call-next-method)))

;;; Keys: commands in a keymap (see xact's keymap.lisp).  A command runs
;;; with XACT:*WIDGET* bound to the clock.

(xact:defcommand clock-analog ()
  "Switch between the analog face and the digital one."
  (interactive)
  (clock-toggle-analog xact:*widget*))

(xact:defcommand clock-second-hand ()
  "Show or hide the second hand."
  (interactive)
  (clock-toggle-second-hand xact:*widget*))

(xact:defcommand clock-digital ()
  "Switch the digital face between 12 and 24 hours."
  (interactive)
  (clock-toggle-digital xact:*widget*))

(xact:defcommand clock-chime ()
  "Turn the chime on or off."
  (interactive)
  (clock-toggle-chime xact:*widget*))

(xact:defcommand clock-render ()
  "Turn the RENDER backend on or off."
  (interactive)
  (clock-toggle-render xact:*widget*))

(xact:defcommand clock-help ()
  "Show or hide the help window."
  (interactive)
  (clock-help-toggle xact:*widget*))

(defvar *clock-keymap*
  (let ((map (xact:make-keymap)))
    (xact:define-key map #\a 'clock-analog)
    (xact:define-key map #\s 'clock-second-hand)
    (xact:define-key map #\t 'clock-digital)
    (xact:define-key map #\c 'clock-chime)
    (xact:define-key map #\r 'clock-render)
    (xact:define-key map #\? 'clock-help)
    map)
  "The clock's keys.")

(defclass clock-focus (xact:interactor)
  ((widget :initarg :widget :reader focus-widget)))

(defmethod xact:handle-event ((i clock-focus) (ev xact:enter-event))
  (clock-focus-in (focus-widget i))
  t)

(defmethod xact:handle-event ((i clock-focus) (ev xact:leave-event))
  (let ((w (focus-widget i)))
    (unless (xact:widget-dragging-p w)
      (clock-focus-out w)))
  t)

(defclass clock-tick (xact:interactor)
  ((widget :initarg :widget :reader tick-widget)))

(defmethod xact:handle-tick ((i clock-tick))
  (let* ((w (tick-widget i))
         (now (get-internal-real-time)))
    (when (>= now (widget-next-tick w))
      (multiple-value-bind (sec min) (current-time-parts)
        (declare (ignore sec))
        (clock-maybe-chime w min))
      (setf (xact:widget-dirty-p w) t)
      (setf (widget-next-tick w)
            (+ now (round (* (model-update-secs w)
                             internal-time-units-per-second)))))))

(defun make-xclock (d conn)
  "A fresh CLOCK-WIDGET for one run on CONN with D's options: its
   placement resolved, its model made and its font chosen; nothing on
   the server is made yet."
  (let ((w (xd:make-application d conn :window (xcb:generate-id conn)
                                      :keymaps (list *clock-keymap*))))
    ;; A position in the geometry string wins; otherwise :X and :Y, else 100.
    (setf (slot-value w 'position-p) (xd:resolve-placement w :min-size +min-size+)
          (xd:app-x w) (or (xd:app-x w) 100)
          (xd:app-y w) (or (xd:app-y w) 100))
    (with-slots (analog analog24 twentyfour brief utime update chime padding model) w
      (setf model (make-clock-model
                   :mode (cond (analog :analog) (twentyfour :long) (t :short))
                   :last-digital (if twentyfour :long :short)
                   :brief brief :utime utime
                   :update-secs (float update 1.0d0)
                   :padding padding
                   :width (xact:widget-width w) :height (xact:widget-height w)
                   :second-hand (<= (abs update) +second-hand-time+)
                   :analog24 analog24
                   :chime chime)))
    (multiple-value-bind (fam sub) (resolve-clock-font (widget-font-family-opt w)
                                                       (widget-font-subfamily-opt w))
      (setf (widget-digital-font-family w) fam
            (widget-digital-font-subfamily w) sub))
    w))

(defun setup-xclock (w)
  "Make W's window, colours, GCs, backing store and, where wanted, RENDER
   and SYNC, give it its size hints, and add the interactors.  Leaves the
   window unmapped."
  (with-slots (position-p quit) w
    (let ((win (xact:widget-window w)))
      (clock-setup-colors w (xd:app-screen w))
      (clock-create-window w (xd:app-x w) (xd:app-y w))
      ;; Before SYNC, which adds _NET_WM_SYNC_REQUEST to the WM_PROTOCOLS
      ;; that REALIZE sets.
      (setf (xact:toplevel-kind w) (if (widget-decorated-p w) :managed :undecorated))
      (xact:realize w)
      (clock-setup-gcs w)
      (widget-recreate-backing-store w)
      (when (widget-use-render-p w)
        (clock-setup-render w))
      (setf (widget-sync-p w) (clock-setup-sync w))
      (when position-p
        (xd:set-placement-hints w))
      (setf quit (make-instance 'clock-quit :window win :widget w))
      (dolist (i (list (make-instance 'xact:resize-interactor :window win :widget w)
                               (make-instance 'clock-focus :window win :widget w)
                               ;; Moving by a drag, resizing by the grip; with a WM
                               ;; frame too, which only duplicates the frame's.
                               (make-instance 'xact:window-resize-interactor
                                              :window win :widget w
                                              :grip-size (if (widget-grip-p w) +grip-size+ 0)
                                              :min-width +min-size+ :min-height +min-size+
                                              :ewmh (widget-ewmh-p w)
                                              :on-start #'clock-help-follow-start
                                              :on-move #'clock-help-follow)
                               (make-instance 'clock-tick :window win :widget w)
                               quit
                               ;; Last, so it sees keys before QUIT does.
                               (make-instance 'xact:key-resize-interactor
                                              :window win :widget w
                                              :min-width +min-size+ :min-height +min-size+
                                              :on-start
                                              (lambda (i)
                                                (declare (ignore i))
                                                (format t "~&Resize: arrows, Return keeps, Escape cancels~%")))
                               (make-instance 'xact:key-move-interactor
                                              :window win :widget w
                                              :on-start
                                              (lambda (i)
                                                (declare (ignore i))
                                                (format t "~&Move: arrows, Return keeps, Escape cancels~%")))))
        (xact:widget-add-interactor w i))
      (setf (widget-next-tick w)
            (+ (get-internal-real-time)
               (round (* (model-update-secs w) internal-time-units-per-second))))
      w)))

(defun clock-other-event (w xcb-ev)
  "Events no interactor of W handles: the help window's Expose, and the
   WM's _NET_WM_SYNC_REQUEST messages."
  (cond
    ((and (typep xcb-ev 'xcb::expose)
          (widget-help w)
          (eql (slot-value xcb-ev 'xcb::window) (help-xid (widget-help w))))
     (help-draw (widget-help w))
     t)
    ((typep xcb-ev 'xcb::client-message)
     (or (clock-handle-sync-message w xcb-ev) nil))
    (t nil)))

(defun print-xclock-banner (w)
  (format t "~&Geometry: ~Dx~D+~D+~D~%"
          (model-width w) (model-height w) (xd:app-x w) (xd:app-y w))
  (format t "~&Mode: ~A, update ~As~@[, second hand~]~%"
          (face-name (widget-current-view w))
          (model-update-secs w)
          (and (model-analog-p w) (model-second-hand-p w)))
  (when (model-analog-p w)
    (format t "Drawing backend: ~A~%"
            (if (widget-render-p w) "RENDER (antialiased)" "classic (aliased)")))
  (format t "~&Controls (press ? in the window for the full list):~%")
  (format t "  a  analog / digital     s  second hand~%")
  (format t "  t  12 / 24-hour         c  chime~%")
  (format t "  r  RENDER on / off      ?  help~%")
  (format t "  q  quit                Ctrl+r  resize with the arrow keys~%")
  (format t "                          Ctrl+m  move with the arrow keys~%")
  (if (widget-grip-p w)
      (format t "  left-drag: move    bottom-right grip: resize~%")
      (format t "  left-drag: move (no resize grip)~%")))

(defun teardown-xclock (w)
  "Free W's help window, RENDER objects, digital-face drawable, GCs and
   window."
  (let ((conn (xact:widget-connection w)))
    (when (widget-help w)
      (help-destroy (widget-help w))
      (setf (widget-help w) nil))
    (clock-teardown-render w)
    (when (widget-digital-drawable w)
      (trivial-garbage:cancel-finalization (widget-digital-drawable w))
      (ignore-errors (xcb-truetype:destroy-drawable (widget-digital-drawable w)))
      (setf (widget-digital-drawable w) nil))
    (ignore-errors (xcb::free-gc conn (widget-gc-face w)))
    (ignore-errors (xcb::free-gc conn (widget-gc-hands w)))
    (ignore-errors (xcb::free-gc conn (widget-gc-highlight w)))
    (ignore-errors (xcb::free-gc conn (widget-gc-bg w)))
    (xact:unrealize w)))

(defun run-xclock (d conn)
  "Run the xclock demo body: one CLOCK-WIDGET, set up, run and torn
   down."
  (let ((w (make-xclock d conn)))
    (unwind-protect
         (let ((win (xact:widget-window w)))
           (setup-xclock w)
           (print-xclock-banner w)
           (xact:show w)
           (setf (xact:widget-dirty-p w) t)
           (xact:run-widget w win
                            :stop-when
                            (lambda ()
                              (xact:quit-requested-p (widget-quit w)))
                            :on-other-event
                            (lambda (ev)
                              (clock-other-event w ev))))
      (teardown-xclock w)))
  t)

(defun xclock (&rest options)
  (apply #'run options))
