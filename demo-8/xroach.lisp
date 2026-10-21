;;; xroach.lisp — XRoach port for CLXCB.
;;; Converted from a C version at:
;;;     https://github.com/interkosmos/xroach
;;; License (as in adapted xroach.c):

;;; Copyright 1991 by J.T. Anderson
;;;
;;; jta@locus.com
;;;
;;; This program may be freely distributed provided that all
;;; copyright notices are retained.
;;;
;;; Dedicated to Greg McFarlane (gregm@otc.otca.oz.au).
;;;
;;; Squish option contributed by Rick Petkiewizc (rick@locus.com).
;;;
;;; Virtual root code (now XD:VIRTUAL-ROOT, lib/virtual-root.lisp) adapted
;;; from a patch sent by Colin Rafferty who
;;; borrowed it from Tom LaStrange. Several other folks sent similar
;;; fixes.
;;;
;;; Some glitches removed by patch from Guus Sliepen
;;; (guus@sliepen.warande.net) in 2001
;;; (see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=102668#5).
;;;
;;; Lisp version: 2026  Arthur Miller <arthur.miller@live.com>

;;; A port of the classic X11 xroach demo to CLXCB.  Cockroaches
;;; crawl on the root window, hide under client windows, and (with
;;; :SQUISH T) can be squished with the mouse.  Every time the
;;; window tree changes, the exposed roaches scamper for cover.
;;;
;;; The program draws directly on the root window, exactly like
;;; xsnow.  Cover detection uses the root's immediate children:
;;; a roach is considered hidden iff its bounding box lies entirely
;;; inside one of the mapped InputOutput child rectangles.  (The C
;;; original used Xlib's region arithmetic, which XCB does not
;;; provide; the single-rect test catches the common case of a
;;; roach under a single window and only differs for roaches
;;; jointly covered by multiple overlapping windows.)
;;;
;;; Sprites: the 24 roach orientations (roach000.xbm .. roach345.xbm)
;;; and squish.xbm are read from demo-8/sprites/ at startup.
;;;
;;; Controls:
;;;   left-click    squish a roach (with :SQUISH T)
;;;   exit          from the REPL: (demo8:stop), or close the session

;;; Lisp version is super-unoptimized. The current goal was just to
;;; get it to run for a demo purpose. Patches welcome.

(xd:define-demo :xroach
    (:resource-class "XRoach"
     :app xroach
     :options (:roach-colour :guts-colour :speed :roaches :squish :verbose))
  (format t "~&========================================~%")
  (format t "   CLXCB XRoach (demo8)                ~%")
  (format t "========================================~%")
  (run-xroach d conn))


;;; The application
;;;
;;; Everything one run of the demo needs lives in an XROACH instance,
;;; made by RUN-XROACH from the demo's options and passed to every
;;; function, so runs never share state.  XROACH is an xact widget: interactors (at the end of the
;;; file) watch the window tree, squish roaches and move the herd, and
;;; XACT:RUN-WIDGET runs the event loop.

(defconstant +roach-headings+   #x00018)
(defconstant +roach-angle-step+ (/ pi 12.0d0))    ; 15°
(defconstant +tick-seconds+     0.02d0)           ; 20 ms

(defparameter *pixmap-dir*
  (asdf:system-relative-pathname "clxcb-demos" "demo-8/sprites/"))

(defclass xroach (xd:application)
  ;; The widget's connection is the demo's, and its window is the one the
  ;; roaches crawl on: the virtual root, where the WM has one (see
  ;; XD:VIRTUAL-ROOT).  Its size is the screen's.  WITH-XROACH binds them
  ;; as CONN, ROOT, WIDTH and HEIGHT.
  ((roach-colour  :initarg :roach-colour :initform "black" :type (or string integer)
                  :documentation "Roach colour: a name, #RRGGBB, or an integer.")
   (guts-colour   :initarg :guts-colour :initform "yellowgreen" :type (or string integer)
                  :documentation "Colour of squished roaches.")
   (roach-sprites :initform nil
                  :documentation "Vector of SPRITE, one per heading (0..23);
                  see lib/sprites.lisp.")
   (squish-sprite :initform nil
                  :documentation "The squish SPRITE, or NIL.")
   (roach-gc      :initform nil
                  :documentation "The GC roach sprites are drawn with.")
   (guts-gc       :initform nil
                  :documentation "Stippled GC for the squish pattern; when NIL,
                  ROACH-GC is used.")
   (roaches       :initform nil
                  :documentation "Vector of ROACH; only the first ROACH-COUNT
                  entries are live.")
   (roach-count   :initform 0)
   (max-roaches   :initarg :roaches :initform 10 :type (integer 1)
                  :documentation "Number of roaches.")
   (roach-speed   :initarg :speed :initform 20.0 :type (real (0))
                  :documentation "Roach speed.")
   (turn-speed)
   (squish-p      :initarg :squish :initform nil :type boolean
                  :documentation "Click to squish roaches.")
   (squish-win    :initform nil)
   (squish-win-up :initform nil)
   (cover-rects   :initform nil
                  :documentation "List of (X Y W H) rectangles for mapped
                  InputOutput children of ROOT.")
   (cover-dirty   :initform t)
   (verbose       :initarg :verbose :initform t :type boolean
                  :documentation "Print diagnostics.")
   (quit          :initform nil
                  :documentation "The QUIT-INTERACTOR that ends the run."))
  (:default-initargs :kind :root))

;;; WITH-SLOTS on an XROACH, with CONN, ROOT, WIDTH and HEIGHT bound as well.
(defmacro with-xroach ((xr &rest slots) &body body)
  `(let ((conn (xact:widget-connection ,xr))
         (root (xact:widget-window ,xr)))
     (declare (ignorable conn root))
     (symbol-macrolet ((width  (xact:widget-width ,xr))
                       (height (xact:widget-height ,xr)))
       (with-slots ,slots ,xr
         ,@body))))

;;; Structs

(declaim (inline heading-sin heading-cos))
(defun heading-sin (index) (sin (* index +roach-angle-step+)))
(defun heading-cos (index) (cos (* index +roach-angle-step+)))

(defstruct roach
  (index 0 :type fixnum)
  (x 0.0d0 :type double-float)
  (y 0.0d0 :type double-float)
  (int-x -1 :type fixnum)
  (int-y -1 :type fixnum)
  (hidden nil)
  (turn-left nil)
  (steps 0 :type fixnum))

(defun roach-sprite (xr r)
  "The sprite for roach R's current heading."
  (aref (slot-value xr 'roach-sprites) (roach-index r)))


;;; Sprite loading

(defun load-all-sprites (xr)
  (with-xroach (xr roach-sprites squish-sprite squish-p verbose)
    (setf roach-sprites (make-array +roach-headings+ :initial-element nil))
    (xcb-demos.sprites:with-xbm-loader (loader conn root)
      (dotimes (i +roach-headings+)
        (setf (aref roach-sprites i)
              (xcb-demos.sprites:load-xbm-sprite
               conn root (merge-pathnames (format nil "roach~3,'0D.xbm" (* i 15)) *pixmap-dir*)
               :loader-gc loader)))
      (when squish-p
        (setf squish-sprite
              (xcb-demos.sprites:load-xbm-sprite
               conn root (merge-pathnames "squish.xbm" *pixmap-dir*) :loader-gc loader))))
    (when verbose
      (format t "~&Loaded ~D roach sprites~@[, squish~].~%"
              (length roach-sprites) squish-p))))


;;; Cover rectangles

(defun refresh-cover-rects (xr)
  "Rebuild COVER-RECTS from the current tree of ROOT's children."
  (with-xroach (xr cover-rects cover-dirty)
    (let ((rects '()))
      (handler-case
          (let* ((cookie (xcb::query-tree conn root))
                 (reply  (xcb::query-tree-reply conn cookie))
                 (children (slot-value reply 'xcb::children)))
            (when (and children (plusp (length children)))
              ;; Phase 1: pipeline GetWindowAttributes requests for all children
              (let* ((attr-cookies
                       (loop for child across children
                             collect (cons child (xcb::get-window-attributes conn child))))
                     ;; Collect children that are viewable, InputOutput, and not override-redirect
                     (matching-children
                       (loop for (child . ac) in attr-cookies
                             when (handler-case
                                      (let* ((ar (xcb::get-window-attributes-reply conn ac))
                                             (map-state (slot-value ar 'xcb::map-state))
                                             (wclass    (slot-value ar 'xcb::class))
                                             (override  (slot-value ar 'xcb::override-redirect)))
                                        (and (= map-state +map-state-viewable+)
                                             (= wclass +window-class-input-output+)
                                             (or (null override)
                                                 (zerop (or override 0)))))
                                    (error () nil))
                               collect child))
                     ;; Phase 2: pipeline GetGeometry requests for matching children
                     (geom-cookies
                       (loop for child in matching-children
                             collect (cons child (xcb::get-geometry conn child)))))
                (loop for (nil . gc) in geom-cookies do
                  (handler-case
                      (let* ((gr (xcb::get-geometry-reply conn gc))
                             (gx (slot-value gr 'xcb::x))
                             (gy (slot-value gr 'xcb::y))
                             (gw (slot-value gr 'xcb::width))
                             (gh (slot-value gr 'xcb::height))
                             (bw (slot-value gr 'xcb::border-width)))
                        (push (list gx gy
                                    (+ gw (* 2 bw))
                                    (+ gh (* 2 bw)))
                              rects))
                    (error () nil))))))
        (error () nil))
      (setf cover-rects rects
            cover-dirty nil))))

(defun rect-contains-p (outer inner)
  (destructuring-bind (ox oy ow oh) outer
    (destructuring-bind (ix iy iw ih) inner
      (and (<= ox ix) (<= oy iy)
           (>= (+ ox ow) (+ ix iw))
           (>= (+ oy oh) (+ iy ih))))))

(defun roach-hidden-p (xr r)
  "True iff R's bounding box lies entirely inside one cover rectangle."
  (let* ((rp (roach-sprite xr r))
         (ix (roach-int-x r))
         (iy (roach-int-y r)))
    (and (>= ix 0)
         (some (lambda (c)
                 (rect-contains-p c (list ix iy
                                          (xcb-demos.sprites:sprite-width rp)
                                          (xcb-demos.sprites:sprite-height rp))))
               (slot-value xr 'cover-rects)))))

(defun mark-hidden-roaches (xr)
  "Update the HIDDEN flag on each roach.
  Return the count of visible ones."
  (with-xroach (xr roaches roach-count)
    (let ((n 0))
      (dotimes (i roach-count)
        (let ((r (aref roaches i)))
          (if (roach-hidden-p xr r)
              (setf (roach-hidden r) t)
              (progn (setf (roach-hidden r) nil) (incf n)))))
      n)))

;;; Roach lifecycle

(defun make-fresh-roach (xr)
  (with-xroach (xr roach-sprites turn-speed)
    (let* ((i (random +roach-headings+))
           (rp (aref roach-sprites i))
           (max-x (max 1 (- width (xcb-demos.sprites:sprite-width rp))))
           (max-y (max 1 (- height (xcb-demos.sprites:sprite-height rp)))))
      (make-roach :index i
                  :x (float (random max-x) 1.0d0)
                  :y (float (random max-y) 1.0d0)
                  :int-x -1 :int-y -1
                  :hidden nil
                  :steps (random (max 1 (round turn-speed)))
                  :turn-left (>= (random 100) 50)))))

(defun roach-turn-speed (speed)
  (max 1.0d0 (/ 200.0d0 (max 1.0d0 (float speed 1.0d0)))))

(defun turn-roach (r)
  (let ((delta (+ 1 (floor (random 30) 10)))
        (idx (roach-index r)))
    (if (roach-turn-left r)
        (setf (roach-index r) (mod (+ idx delta) +roach-headings+))
        (setf (roach-index r) (mod (- idx delta) +roach-headings+)))))

(defun roach-in-bounds-p (xr r nx ny)
  (let ((rp (roach-sprite xr r)))
    (with-xroach (xr)
      (and (>= nx 0) (>= ny 0)
           (<= (+ nx (xcb-demos.sprites:sprite-width rp)) width)
           (<= (+ ny (xcb-demos.sprites:sprite-height rp)) height)))))

(defun move-roach (xr r)
  (with-xroach (xr roach-speed turn-speed)
    (let* ((nx (+ (roach-x r) (* roach-speed (heading-cos (roach-index r)))))
           (ny (- (roach-y r) (* roach-speed (heading-sin (roach-index r))))))
      (if (roach-in-bounds-p xr r (floor nx) (floor ny))
          (progn
            (setf (roach-x r) nx
                  (roach-y r) ny)
            (let ((old-steps (roach-steps r)))
              (decf (roach-steps r))
              (when (<= old-steps 0)
                (turn-roach r)
                (setf (roach-steps r) (random (max 1 (round turn-speed))))
                (when (>= (random 100) 80)
                  (setf (roach-turn-left r) (not (roach-turn-left r)))))))
          (turn-roach r)))))

(defun erase-roach (xr r)
  (let ((ix (roach-int-x r)) (iy (roach-int-y r)))
    (when (>= ix 0)
      (let ((rp (roach-sprite xr r)))
        (with-xroach (xr)
          (xcb::clear-area conn 0 root ix iy
                           (xcb-demos.sprites:sprite-width rp)
                           (xcb-demos.sprites:sprite-height rp)))))))

(defun draw-roach (xr r)
  (with-xroach (xr roach-gc)
    (let ((ix (floor (roach-x r)))
          (iy (floor (roach-y r))))
      (xcb-demos.sprites:draw-sprite conn root roach-gc (roach-sprite xr r) ix iy)
      (setf (roach-int-x r) ix
            (roach-int-y r) iy))))

(defun draw-squish (xr x y)
  (with-xroach (xr guts-gc roach-gc squish-sprite)
    (xcb-demos.sprites:draw-sprite conn root (or guts-gc roach-gc) squish-sprite x y)))

(defun step-roaches (xr)
  "Advance every visible roach one tick and redraw."
  (with-xroach (xr roaches roach-count)
    ;; 1. Move all visible roaches.
    (dotimes (i roach-count)
      (let ((r (aref roaches i)))
        (unless (roach-hidden r)
          (move-roach xr r))))
    ;; 2. Redraw: erase old position, draw at new; erase and reset intX if hidden.
    (dotimes (i roach-count)
      (let ((r (aref roaches i)))
        (if (roach-hidden r)
            (when (>= (roach-int-x r) 0)
              (erase-roach xr r)
              (setf (roach-int-x r) -1))
            (progn (erase-roach xr r) (draw-roach xr r)))))))

(defun erase-all-roaches (xr)
  "Erase every currently-drawn roach.  Called from the teardown path so
   nothing is left behind when the demo exits."
  (with-xroach (xr roaches roach-count)
    (dotimes (i roach-count)
      (erase-roach xr (aref roaches i)))
    ;; Force a round-trip so the server processes the clears before
    ;; the connection is torn down.  Any request with a reply would
    ;; do; the input-focus query is the cheapest one we have.
    (ignore-errors
     (xcb::get-input-focus-reply conn (xcb::get-input-focus conn)))))


;;; Squish handling

(defun check-squish (xr x y)
  "Splat every visible roach whose bounding box contains (X, Y).
   Returns the number killed by this click."
  (with-xroach (xr roaches roach-count)
    (let ((killed nil))
      (dotimes (i roach-count)
        (let* ((r  (aref roaches i))
               (rp (roach-sprite xr r))
               (ix (roach-int-x r))
               (iy (roach-int-y r)))
          (when (and (not (roach-hidden r))
                     (>= ix 0)
                     (> x ix) (< x (+ ix (xcb-demos.sprites:sprite-width rp)))
                     (> y iy) (< y (+ iy (xcb-demos.sprites:sprite-height rp))))
            (draw-squish xr ix iy)
            (push i killed))))
      (when killed
        (let ((survivors '()))
          (dotimes (i roach-count)
            (unless (member i killed)
              (push (aref roaches i) survivors)))
          (setf roaches (coerce (nreverse survivors) 'vector)
                roach-count (length survivors))))
      (length killed))))


;;; Setup helpers

(defun setup-gcs (xr roach-colour guts-colour)
  (with-xroach (xr roach-gc guts-gc squish-p)
    (setf roach-gc (xcb-demos.sprites:make-sprite-gc conn root roach-colour))
    (when squish-p
      (setf guts-gc (xcb-demos.sprites:make-sprite-gc conn root guts-colour)))))

(defun setup-squish-window (xr)
  (with-xroach (xr squish-win squish-win-up)
    (setf squish-win (xcb:generate-id conn))
    (xcb::create-window conn 0 squish-win root
                        0 0 width height
                        0                       ; border-width
                        +window-class-input-only+
                        0                       ; copy-from-parent
                        (logior +cw-event-mask+
                                +cw-override-redirect+)
                        :event-mask (logior +event-mask-button-press+
                                            +event-mask-key-press+)
                        :override-redirect 1)
    ;; Lower to the bottom so client windows above it get clicks.
    (xcb::configure-window
     conn squish-win +config-window-stack-mode+ :stack-mode 1)
    (setf squish-win-up nil)))

(defun ensure-squish-visibility (xr n-visible)
  "Map the squish window only while some roach is exposed."
  (with-xroach (xr squish-p squish-win squish-win-up)
    (when squish-p
      (cond
        ((and (plusp n-visible) (not squish-win-up))
         (xcb::map-window conn squish-win)
         (setf squish-win-up t))
        ((and (zerop n-visible) squish-win-up)
         (xcb::unmap-window conn squish-win)
         (setf squish-win-up nil))))))


;;; Interactors
;;;
;;; The window tree is watched with SubstructureNotify on the root, so
;;; the root's widget sees every client window's structure events; the
;;; squish window, an InputOnly child, reports its clicks with its own
;;; window.  EVENT-WINDOW tells them apart.

(defclass roach-interactor (xact:interactor)
  ((app :initarg :app :reader roach-app)))

(defclass roach-cover-watch (roach-interactor) ()
  (:documentation "Rescans the cover rectangles when a window appears,
   moves, changes or goes, or the root is exposed."))

(defmethod xact:handle-event ((i roach-cover-watch) ev)
  (let ((xr (roach-app i)))
    (when (and (typep ev '(or xact:expose-event xact:configure-event
                           xact:map-event xact:unmap-event xact:destroy-event
                           xact:create-event xact:reparent-event))
               ;; Our own squish window's traffic changes no cover.
               (not (eql (xact:event-window ev) (slot-value xr 'squish-win))))
      (setf (slot-value xr 'cover-dirty) t))
    nil))

(defclass roach-squisher (roach-interactor)
  ((quit :initarg :quit :reader squisher-quit))
  (:documentation "Squishes the roaches under a click on the squish
   window, and quits when the last one is gone."))

(defmethod xact:handle-event ((i roach-squisher) (ev xact:button-press))
  (let ((xr (roach-app i)))
    (when (eql (xact:event-window ev) (slot-value xr 'squish-win))
      (check-squish xr (xact:event-x ev) (xact:event-y ev))
      (when (zerop (slot-value xr 'roach-count))
        (xact:request-quit (squisher-quit i)))
      t)))

(defclass roach-ticker (roach-interactor) ()
  (:documentation "Each tick: rescan cover if needed, and move the herd."))

(defmethod xact:handle-tick ((i roach-ticker))
  (let ((xr (roach-app i)))
    (when (slot-value xr 'cover-dirty)
      (refresh-cover-rects xr))
    (ensure-squish-visibility xr (mark-hidden-roaches xr))
    (step-roaches xr)))

;;; The roaches are drawn by the ticker, straight onto the root; there
;;; is nothing to redraw when the widget is marked dirty.
(defmethod xact:draw ((xr xroach) surface)
  (declare (ignore surface))
  nil)


;;; Entry points

(defun xroach (&rest options)
  "Run the xroach demo.  OPTIONS are the demo's declared options (see
   its DEFINE-DEMO form), e.g. (xroach :roaches 30 :squish t)."
  (apply #'run options))

(defun run-xroach (d conn)
  "Run the xroach demo body."
  (let* ((xr     (xd:make-application d conn :window (xd:virtual-root conn)))
         (screen (xd:app-screen xr)))
    (setf (xact:widget-width xr)  (xcb:width-in-pixels screen)
          (xact:widget-height xr) (xcb:height-in-pixels screen))
    (with-slots (roach-speed turn-speed) xr
      (setf roach-speed (float roach-speed 1.0d0)
            turn-speed  (roach-turn-speed roach-speed)))
    (xact:realize xr)
    (with-xroach (xr roach-gc guts-gc roach-sprites squish-sprite
                  squish-win max-roaches (herd roaches) roach-count
                  roach-colour guts-colour (squish squish-p))
      (setup-gcs xr (xcb:parse-color conn screen roach-colour 0)
                 (when squish (xcb:parse-color conn screen guts-colour 0)))
      (load-all-sprites xr)

      (when squish
        (setup-squish-window xr))

      ;; Spawn the initial herd.
      (setf herd (make-array max-roaches))
      (dotimes (i max-roaches)
        (setf (aref herd i) (make-fresh-roach xr)))
      (setf roach-count max-roaches)

      ;; Watch the root for exposures, window-tree changes, and key presses.
      (xcb::change-window-attributes
       conn root +cw-event-mask+
       :event-mask (logior +event-mask-exposure+
                           +event-mask-substructure-notify+
                           +event-mask-key-press+))

      (format t "~&Screen: ~Dx~D, roaches: ~D~@[, squish on~]~%"
              width height roach-count squish)
      (format t "~&Controls:~%")
      (when squish
        (format t "  left-click   squish a roach (exits when all squished)~%"))
      (format t "  q, Escape    quit~%")
      (format t "  exit         from the REPL: (demo8:stop)~%")

      (let ((quit (make-instance 'xact:quit-interactor :window root
                                 :keys '(#\q :escape (:control #\q)) :close t)))
        (dolist (i (list quit
                         (make-instance 'roach-cover-watch :window root :app xr)
                         (make-instance 'roach-squisher :window root :app xr :quit quit)
                         (make-instance 'roach-ticker :window root :app xr)))
          (xact:widget-add-interactor xr i))
        (setf (slot-value xr 'quit) quit))
      (unwind-protect
           (xact:run-widget xr nil
                            :stop-when (lambda () (xact:quit-requested-p (slot-value xr 'quit)))
                            :idle-sleep +tick-seconds+)
        ;; Tear down.
        (ignore-errors (erase-all-roaches xr))
        (xcb-demos:ignoring-errors
         (when roach-gc
           (xcb::free-gc conn roach-gc))
         (when guts-gc
           (xcb::free-gc conn guts-gc))
         (when roach-sprites
           (loop for sprite across roach-sprites
                 do (xcb-demos.sprites:free-sprite conn sprite)))
         (xcb-demos.sprites:free-sprite conn squish-sprite)
         (when squish-win
           (xcb::destroy-window conn squish-win)))
        (xact:unrealize xr))))
  t)
