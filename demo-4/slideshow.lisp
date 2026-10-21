;;; slideshow.lisp — Pixmap slideshow demo for CLXCB.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; Six off-screen pixmaps are painted at the current window size, then
;;; cycled into the window on a timer.  Every slide change is one
;;; COPY-AREA request.  The pixmaps are rebuilt whenever the window is
;;; resized, so the slides always fill the window.  The event loop is
;;; driven by xact.

(xd:define-demo :slideshow (:wm-title "CLXCB Pixmap Slideshow"
                            :app xslideshow
                            :options (:width :height :x :y :geometry))
  (format t "~&========================================~%")
  (format t "   CLXCB Pixmap Slideshow (demo4)      ~%")
  (format t "========================================~%")
  (run-xslideshow d conn))

(defconstant +initial-width+ 480)
(defconstant +initial-height+ 360)
(defconstant +interval+ 1.5d0 "Seconds per slide.")

(defun pick-font (conn)
  (dolist (candidate '("10x20" "9x15" "8x13" "fixed"))
    (let* ((cookie (xcb::list-fonts conn 1 candidate))
           (reply  (xcb::list-fonts-reply conn cookie))
           (names  (slot-value reply 'xcb::names)))
      (when (and names (plusp (length names)))
        (return-from pick-font candidate))))
  "fixed")

(defun draw-text (sw window x y text)
  (let ((n (length text)))
    (when (> n 254)
      (error "draw-text: string too long for poly-text8 (~D chars)" n))
    (let ((buf (make-array (+ 2 n) :element-type '(unsigned-byte 8))))
      (setf (aref buf 0) n (aref buf 1) 0)
      (loop for i from 0 below n
            do (setf (aref buf (+ 2 i))
                     (logand (char-code (char text i)) #xFF)))
      (xcb::poly-text8 (xact:widget-connection sw) window
                       (slideshow-text-gc sw) x y (coerce buf 'list)))))

(defun set-foreground (sw color)
  (xcb::change-gc (xact:widget-connection sw) (slideshow-gc sw) +gc-foreground+ :foreground color))

(defun fill-rect (sw pixmap x y w h)
  (xcb::poly-fill-rectangle
   (xact:widget-connection sw) pixmap (slideshow-gc sw)
   (list (make-instance 'xcb::rectangle :x x :y y :width w :height h))))

(defun fill-rects (sw pixmap rects)
  (when rects
    (xcb::poly-fill-rectangle (xact:widget-connection sw) pixmap (slideshow-gc sw) rects)))

(defun clear-pixmap (sw pixmap color)
  (set-foreground sw color)
  (fill-rect sw pixmap 0 0 (xact:widget-width sw) (xact:widget-height sw)))

(defun paint-rainbow (sw pixmap)
  (let ((colors #(#xE53935 #xFB8C00 #xFDD835 #x43A047 #x1E88E5 #x3949AB #x8E24AA))
        (n 7))
    (loop for i from 0 below n
          for y  = (round (* i (xact:widget-height sw)) n)
          for y2 = (round (* (1+ i) (xact:widget-height sw)) n)
          do (set-foreground sw (aref colors i))
             (fill-rect sw pixmap 0 y (xact:widget-width sw) (- y2 y)))))

(defun paint-gradient (sw pixmap)
  (let ((bands 32)
        (r0 30) (g0 60)  (b0 200)
        (r1 220) (g1 40) (b1 40))
    (loop for i from 0 below bands
          for x    = (round (* i (xact:widget-width sw)) bands)
          for x2   = (round (* (1+ i) (xact:widget-width sw)) bands)
          for frac = (/ i (float (1- bands)))
          for r    = (round (+ (* r0 (- 1 frac)) (* r1 frac)))
          for g    = (round (+ (* g0 (- 1 frac)) (* g1 frac)))
          for b    = (round (+ (* b0 (- 1 frac)) (* b1 frac)))
          do (set-foreground sw (logior (ash r 16) (ash g 8) b))
             (fill-rect sw pixmap x 0 (- x2 x) (xact:widget-height sw)))))

(defun paint-checker (sw pixmap)
  (let ((cell 30))
    (clear-pixmap sw pixmap #xDDDDDD)
    (set-foreground sw #x202020)
    (let ((rects nil))
      (loop for y from 0 below (xact:widget-height sw) by cell
            do (loop for x from 0 below (xact:widget-width sw) by cell
                     when (evenp (+ (floor x cell) (floor y cell)))
                       do (push (make-instance 'xcb::rectangle
                                               :x x :y y
                                               :width cell :height cell)
                                rects)))
      (fill-rects sw pixmap (nreverse rects)))))

(defun paint-concentric (sw pixmap)
  (let* ((steps 24)
         (cx (/ (xact:widget-width sw)  2.0))
         (cy (/ (xact:widget-height sw) 2.0))
         (max-radius (min cx cy)))
    (clear-pixmap sw pixmap #x101820)
    (loop for i from 0 below steps
          for frac   = (/ i (float (1- steps)))
          for radius = (round (* max-radius (- 1 frac)))
          for r      = (round (* 255 frac))
          for g      = (round (* 128 (- 1 (abs (- frac 0.5)))))
          for b      = (round (* 255 (- 1 frac)))
          do (set-foreground sw (logior (ash r 16) (ash g 8) b))
             (fill-rect sw pixmap
                        (round (- cx radius))
                        (round (- cy radius))
                        (* 2 radius)
                        (* 2 radius)))))

(defun paint-fan (sw pixmap)
  (clear-pixmap sw pixmap #x101820)
  (set-foreground sw #x00D080)
  (let ((segments nil)
        (n 24)
        (x0 0)
        (y0 (1- (xact:widget-height sw))))
    (loop for i from 0 below n
          for x = (round (* i (xact:widget-width sw)) n)
          for y = (round (* i (xact:widget-height sw)) n)
          do (push (make-instance 'xcb::segment
                                  :x1 x0 :y1 y0
                                  :x2 x  :y2 y)
                   segments))
    (xcb::poly-segment (xact:widget-connection sw) pixmap (slideshow-gc sw) (nreverse segments))))

(defun paint-text (sw pixmap)
  (clear-pixmap sw pixmap #x1A1A2E)
  (xcb::change-gc (xact:widget-connection sw) (slideshow-text-gc sw) +gc-foreground+ :foreground #xFFD866)
  (draw-text sw pixmap 30 60 "Pixmaps")
  (draw-text sw pixmap 30 90 "in CLXCB")
  (xcb::change-gc (xact:widget-connection sw) (slideshow-text-gc sw) +gc-foreground+ :foreground #xCCCCCC)
  (draw-text sw pixmap 30 (- (xact:widget-height sw) 40)
             "each slide = one off-screen drawable"))

(defun make-slide (sw name painter)
  "A slide: NAME and a pixmap the size of SW's window, painted by PAINTER."
  (let* ((conn (xact:widget-connection sw))
         (pixmap (xcb:generate-id conn)))
    (xcb::create-pixmap conn (xd:app-depth sw)
                        pixmap (xact:widget-window sw)
                        (xact:widget-width sw) (xact:widget-height sw))
    (funcall painter sw pixmap)
    (cons name pixmap)))

(defun build-slides (sw)
  (list (make-slide sw "Rainbow"      #'paint-rainbow)
        (make-slide sw "Gradient"     #'paint-gradient)
        (make-slide sw "Checkerboard" #'paint-checker)
        (make-slide sw "Concentric"   #'paint-concentric)
        (make-slide sw "Fan"          #'paint-fan)
        (make-slide sw "Text"         #'paint-text)))

(defun free-slides (sw)
  (dolist (slide (slideshow-slides sw))
    (ignore-errors (xcb::free-pixmap (xact:widget-connection sw) (cdr slide))))
  (setf (slideshow-slides sw) nil))

;;; The application
;;;
;;; Everything one run needs lives in an XSLIDESHOW, an xact widget: the
;;; slides and which one shows, the GCs and font they are painted with,
;;; and the quit interactor.

(defclass xslideshow (xd:application)
  ((slides   :initform nil :accessor slideshow-slides)
   (current  :initform 0   :accessor slideshow-current)
   (gc       :initform nil :accessor slideshow-gc)
   (text-gc  :initform nil :accessor slideshow-text-gc)
   (font     :initform nil :accessor slideshow-font)
   (quit     :initform nil      :reader slideshow-quit
             :documentation "The QUIT-INTERACTOR that ends the run.")
   (paint-w  :initform 0   :accessor slideshow-paint-width)
   (paint-h  :initform 0   :accessor slideshow-paint-height))
  (:default-initargs :width +initial-width+ :height +initial-height+))

(defun rebuild-slides (w)
  (let ((nw (xact:widget-width w))
        (nh (xact:widget-height w)))
    (when (and (plusp nw) (plusp nh)
               (or (/= nw (slideshow-paint-width w))
                   (/= nh (slideshow-paint-height w))))
      (free-slides w)
      (setf (slideshow-slides w)  (build-slides w)
            (slideshow-paint-width w)  nw
            (slideshow-paint-height w) nh))))

(defmethod xact:draw ((w xslideshow) surface)
  (rebuild-slides w)
  (let ((pixmap (cdr (nth (slideshow-current w) (slideshow-slides w)))))
    (xcb::copy-area (xact:widget-connection w)
                    pixmap surface (slideshow-gc w)
                    0 0 0 0
                    (xact:widget-width w)
                    (xact:widget-height w))))

(defun slideshow-advance (w delta)
  (let ((slides (slideshow-slides w)))
    (setf (slideshow-current w)
          (mod (+ (slideshow-current w) delta) (length slides)))
    (format t "~&Slide ~D/~D: ~A~%"
            (1+ (slideshow-current w)) (length slides)
            (car (nth (slideshow-current w) slides)))
    (setf (xact:widget-dirty-p w) t)))

(defclass slideshow-timer (xact:interactor)
  ((widget   :initarg :widget   :reader slideshow-timer-widget)
   (interval :initarg :interval :reader slideshow-timer-interval)
   (next     :initform 0        :accessor slideshow-timer-next)))

(defmethod xact:handle-tick ((i slideshow-timer))
  (let ((now  (get-internal-real-time))
        (next (slideshow-timer-next i)))
    (when (or (zerop next) (>= now next))
      (setf (slideshow-timer-next i)
            (+ now (round (* (slideshow-timer-interval i)
                             internal-time-units-per-second))))
      (slideshow-advance (slideshow-timer-widget i) 1))))

(defclass slideshow-nav (xact:interactor)
  ((widget :initarg :widget :reader slideshow-nav-widget)))

(defmethod xact:handle-event ((i slideshow-nav) (ev xact:key-press))
  (let ((w (slideshow-nav-widget i)))
    (case (xact:event-keysym ev)
      ((#\space #\n) (slideshow-advance w 1)  t)
      (#\p           (slideshow-advance w -1) t)
      (t nil))))


;;; Setting up, running and tearing down one run

(defun make-xslideshow (d conn)
  "A fresh XSLIDESHOW on CONN: its window (not mapped), GCs and font."
  (let* ((sw      (xd:make-application d conn))
         ;; A position in the geometry string or :X / :Y wins; else 100, 100.
         (position-p (xd:resolve-placement sw))
         (black   (xcb:black-pixel (xd:app-screen sw)))
         (win     (xd:realize-application
                   sw :x 100 :y 100
                      :background-pixel black
                      :event-mask (logior +event-mask-exposure+
                                          +event-mask-key-press+
                                          +event-mask-structure-notify+)))
         (gc      (xcb:generate-id conn))
         (text-gc (xcb:generate-id conn))
         (font    (xcb:generate-id conn)))
    (xcb::create-gc conn gc win +gc-foreground+ :foreground black)
    (xcb::open-font conn font (pick-font conn))
    (xcb::create-gc conn text-gc win (logior +gc-foreground+ +gc-font+)
                    :foreground black
                    :font font)
    (setf (slideshow-gc sw) gc
          (slideshow-text-gc sw) text-gc
          (slideshow-font sw) font)
    (when position-p
      (xd:set-placement-hints sw))
    sw))

(defun setup-xslideshow (sw)
  "Give SW its interactors: the slide timer, the keys, following the
   window's size, and quitting."
  (let ((win (xact:widget-window sw)))
    (setf (slot-value sw 'quit) (make-instance 'xact:quit-interactor :window win))
    (dolist (i (list (make-instance 'slideshow-timer :window win :widget sw :interval +interval+)
                     (make-instance 'slideshow-nav :window win :widget sw)
                     (make-instance 'xact:resize-interactor :window win :widget sw)
                     (slideshow-quit sw)
                     ;; Last, so in resize mode it sees the arrows and
                     ;; Escape before QUIT does.
                     (make-instance 'xact:key-resize-interactor :window win :widget sw)
                     (make-instance 'xact:key-move-interactor :window win :widget sw)))
      (xact:widget-add-interactor sw i))
    sw))

(defun teardown-xslideshow (sw)
  "Free SW's slides, GCs, font and window."
  (let ((conn (xact:widget-connection sw)))
    (free-slides sw)
    (ignore-errors (xcb::free-gc conn (slideshow-gc sw)))
    (ignore-errors (xcb::free-gc conn (slideshow-text-gc sw)))
    (ignore-errors (xcb::close-font conn (slideshow-font sw)))
    (xact:unrealize sw)))

(defun run-xslideshow (d conn)
  "Run the slideshow demo body: one XSLIDESHOW, set up, run and torn
   down."
  (let ((sw (make-xslideshow d conn)))
    (unwind-protect
         (let ((win (xact:widget-window sw)))
           (setup-xslideshow sw)
           (xact:show sw)
           (format t "~&Controls:~%")
           (format t "  q / Esc    exit~%")
           (format t "  space / n  next slide~%")
           (format t "  p          previous slide~%")
           (format t "  resize     slides rebuilt to fit~%")
           (format t "  Ctrl+r     resize with the arrows, Return / Escape~%")
           (format t "  Ctrl+m     move with the arrows, Return / Escape~%")
           (format t "  close the window via the WM to exit~%")
           (xact:run-widget sw win
                            :stop-when
                            (lambda ()
                              (xact:quit-requested-p (slideshow-quit sw))))
           (format t "Demo completed successfully.~%"))
      (teardown-xslideshow sw))))
