;;; xviewer.lisp — Image viewer demo for CLXCB.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+.
;;;
;;; Scans the current directory for image files, decodes them via the
;;; registered backends in image-decoders.lisp, uploads each decoded
;;; bitmap to a pixmap with PUT-IMAGE, and displays it with COPY-AREA.
;;; A translucent prev/next overlay is alpha-blended into the pixmap
;;; before display, and click regions are hit-tested on the main window.
;;;
;;; Controls:
;;;   space / right / r / n   next image
;;;   left / l / p            previous image
;;;   s                       stop slideshow (display static image)
;;;   R (Shift+r)             run slideshow timer
;;;   t                       toggle auto-advance timer
;;;   f / F11                 toggle fullscreen
;;;   h                       hide / show controls
;;;   g                       hide / show the corner grip
;;;   i                       image fit / native size
;;;   c                       shrink-only scaling (don't enlarge small images)
;;;   ?                       show / hide this help
;;;   Ctrl+o                  open directory dialog to choose images
;;;   left / right            previous / next image (arrow keys)
;;;   q / Escape              exit
;;;   Ctrl-+ / Ctrl-- / Ctrl-0  help, controls and grip bigger / smaller /
;;;                           normal; also Alt- or Super-drag
;;;   click on left tri       previous image
;;;   click on right tri      next image
;;;
;;; The window's size and position, the initial state of the h, g, i
;;; and c toggles, the slideshow, and the help overlay's font are the
;;; demo's options: (demo11:run :controls
;;; nil :grip t), --no-controls through XD:MAIN, or
;;; "XViewer.fontSize: 16" in the user's X resources.
;;;
;;; The overlays scale together, as in the thermometer (demo 12): :SCALE
;;; and :FONT-SIZE are cells of the widget's state tied by a relation, so
;;; Ctrl-+ (or a drag) writes the scale and --font-size the size, and the
;;; help panel's font and padding, the triangles and the grip are sized
;;; from the scale when they are drawn.  The image scales with the window
;;; as before.

(xd:define-demo :xviewer (:wm-title "CLXCB XViewer"
                          :wm-class "clxcb-xviewer"
                          ;; What the framework would derive from the
                          ;; name anyway, stated so the header's
                          ;; "XViewer.fontSize" is visibly true.
                          :resource-class "XViewer"
                          :app xviewer
                          :options (:width :height :x :y :geometry
                                    :directory :interval :slideshow :controls :grip
                                    :shrink-only :max-width :max-height :fit-fullscreen
                                    :font-family :font-subfamily :font-size))
  (format t "~&========================================~%")
  (format t "   CLXCB XViewer (demo11)               ~%")
  (format t "========================================~%")
  (run-xviewer d conn))


;;; State

(defclass xviewer (xd:application)
  ((keymap
    :initform (make-hash-table :test 'eql)
    :reader viewer-keymap
    :documentation "Numeric X keysym -> function of no arguments, set up
    by SETUP-KEYBINDINGS.")
   (gc
    :initform nil
    :accessor viewer-gc
    :documentation "Graphics context used for image blits (COPY-AREA)
    and for CLEAR-AREA when no image is loaded.")

   ;; The window, its size and the connection are xact's WIDGET-WINDOW,
   ;; WIDGET-WIDTH, WIDGET-HEIGHT and WIDGET-CONNECTION; the size is kept
   ;; in sync with CONFIGURE-NOTIFY and clamps the visible portion of the
   ;; displayed image.  Without a :WIDTH or :HEIGHT the window starts at
   ;; 800x600 and fits itself to each image (see FIXED-SIZE-P).

   (fixed-size-p
    :initform nil
    :accessor viewer-fixed-size-p
    :documentation "T when the user gave the window's size (the :WIDTH,
    :HEIGHT or :GEOMETRY option).  FIT-VIEWER then leaves the window at
    that size instead of resizing it to each image.")

   (max-width
    :initarg :max-width
    :initform 1200
    :type (integer 1)
    :accessor viewer-max-width
    :documentation "Largest window width when fitting an image.  Images
    wider than this are shown clipped.")

   (max-height
    :initarg :max-height
    :initform 900
    :type (integer 1)
    :accessor viewer-max-height
    :documentation "Largest window height when fitting an image.  See
    VIEWER-MAX-WIDTH.")

   (image-directory
    :initarg :directory
    :initform nil
    :type (or null string pathname)
    :accessor viewer-image-directory
    :documentation "Directory to scan for images.  NIL means the default
    directory (see DEFAULT-IMAGE-DIRECTORY).")

   (images
    :initform nil
    :accessor viewer-images
    :documentation "List of pathnames, in display order.")

   (current
    :initform 0
    :accessor viewer-current
    :documentation "Index into VIEWER-IMAGES of the displayed image.
    Wrapped modulo (LENGTH VIEWER-IMAGES) by ADVANCE-IMAGE.")

   (source-rgb
    :initform nil
    :accessor viewer-source-rgb
    :documentation "Native-resolution RGB bytes of the currently loaded
    image (WIDTH*HEIGHT*3, one byte per channel, no overlays).  The
    scaled buffer shown in the window is derived from this on every
    render, so the source is kept even after the window is resized or
    fullscreened.  NIL when no image is loaded.")

   (source-width
    :initform 0
    :accessor viewer-source-width
    :documentation "Native pixel width of VIEWER-SOURCE-RGB.")

   (source-height
    :initform 0
    :accessor viewer-source-height
    :documentation "Native pixel height of VIEWER-SOURCE-RGB.")

   (current-pixmap
    :initform nil
    :accessor viewer-current-pixmap
    :documentation "Pixmap ID of the currently displayed image, or NIL.
    Reused by RERENDER while the window keeps its size; see
    RELEASE-PIXMAP.")

   (pixmap-drawable
    :initform nil
    :accessor viewer-pixmap-drawable
    :documentation "XCB-TRUETYPE:PIXMAP wrapper for VIEWER-CURRENT-PIXMAP,
    made the first time text is drawn on it, or NIL.  It owns the RENDER
    picture text is composited through, so the picture lives as long as
    the pixmap instead of being made and freed on every render.")

   (current-size
    :initform nil
    :accessor viewer-current-size
    :documentation "(WIDTH . HEIGHT) of VIEWER-CURRENT-PIXMAP.  Always
    equal to the window size at the moment the pixmap was rendered, and
    therefore changes on every resize, not just on load.")

   (prev-tri
    :initform nil
    :accessor viewer-prev-tri
    :documentation "Overlay triangle for previous image button, or NIL.")

   (next-tri
    :initform nil
    :accessor viewer-next-tri
    :documentation "Overlay triangle for next image button, or NIL.")

   (auto-advance
    :initform nil
    :accessor viewer-auto-advance
    :documentation "Whether the viewer automatically advances through
    images on a timer.  Defaults to NIL (static mode).")

   (interval
    :initarg :interval
    :initform 4.0d0
    :type (real (0))
    :accessor viewer-interval
    :documentation "Slideshow interval in seconds.")

   (slideshow-p
    :initarg :slideshow
    :initform nil
    :type boolean
    :reader viewer-slideshow-p
    :documentation "Start with the slideshow running.")

   (slideshow-next
    :initform 0
    :accessor viewer-slideshow-next
    :documentation "Internal real time for the next scheduled slide
    advance.")

   (fullscreen-p
    :initform nil
    :accessor viewer-fullscreen-p
    :documentation "T when the viewer has asked the WM to fullscreen it,
    and has not yet asked to leave.  Used by FIT-VIEWER to keep the
    window's size out of the client's hands in that state.")

   (show-controls-p
    :initarg :controls
    :initform t
    :type boolean
    :accessor viewer-show-controls-p
    :documentation "Show the prev/next overlay triangles.  Toggled
    by the h key; when NIL, RERENDER skips the overlay blend and
    HANDLE-CLICK ignores clicks in the triangle zones.")

   (show-grip-p
    :initarg :grip
    :initform nil
    :type boolean
    :accessor viewer-show-grip-p
    :documentation "Show a corner grip that resizes the window.  Toggled by
    the g key.  NIL by default: a WM-decorated window already has its own
    resize affordance.  Dragging the grip hands the resize to the window
    manager (_NET_WM_MOVERESIZE), through GRIP-INTERACTOR.")

   (grip-interactor
    :initform nil
    :accessor viewer-grip-interactor
    :documentation "The resize-only XACT:WINDOW-RESIZE-INTERACTOR behind the
    grip; its grip size is 0 while the grip is hidden.")

   (fit-fullscreen-p
    :initarg :fit-fullscreen
    :initform t
    :type boolean
    :accessor viewer-fit-fullscreen-p
    :documentation "Scale images to fit the window (letterboxed and
    centred, aspect preserved).  NIL shows the image at native pixel
    size, centred, cropped by the window if larger.  Toggled by the i key.")

   (shrink-only-p
    :initarg :shrink-only
    :initform nil
    :type boolean
    :accessor viewer-shrink-only-p
    :documentation "With fit-fullscreen, don't enlarge images smaller than
    the window.  Only meaningful when VIEWER-FIT-FULLSCREEN-P is T: images
    smaller than the window are shown at native size instead of being
    enlarged; images larger than the window are still scaled down.  Toggled by the c key.")

   (help-visible-p
    :initform nil
    :accessor viewer-help-visible-p
    :documentation "T when the help panel is overlaid on the displayed
    image.  Toggled by the ? key; RERENDER draws the panel after the
    image is uploaded when set.")

   (help-fonts
    :initform (make-hash-table)
    :reader viewer-help-fonts
    :documentation "XCB-TRUETYPE:FONT instances for the help overlay, by
    size, made as the scale asks for them.")

   (help-font-family
    :initarg :font-family
    :initform nil
    :type (or null string)
    :accessor viewer-help-font-family
    :documentation "Help overlay font family; NIL picks the first
    installed of a few common sans families.")

   (help-font-subfamily
    :initarg :font-subfamily
    :initform nil
    :type (or null string)
    :accessor viewer-help-font-subfamily
    :documentation "Help overlay font subfamily; NIL lets XCB-TRUETYPE
    pick Regular, Book, or the first available.")

   (help-font-size
    :initarg :font-size
    :initform 12
    :type (integer 1)
    :accessor viewer-help-font-size
    :documentation "Help overlay font pixel size.")

   (done
    :initform nil
    :accessor viewer-done
    :documentation "Set by the quit key binding, polled by the event
    loop.  Reset at the start of each run by RUN-XVIEWER."))
  ;; NIL, not XD:APPLICATION's 1x1: "no size given", which
  ;; INITIALIZE-INSTANCE below turns into 800x600 and FIXED-SIZE-P NIL.
  (:default-initargs :width nil :height nil))

(defmethod initialize-instance :around ((v xviewer) &rest initargs
                                       &key width height &allow-other-keys)
  ;; The size is always a positive integer, as XD:APPLICATION requires;
  ;; whether one was given is FIXED-SIZE-P.  A NIL :WIDTH or :HEIGHT --
  ;; the default above, or what the option parser passes for an option
  ;; not given -- counts as none.
  (let ((result (apply #'call-next-method v :width (or width 800) :height (or height 600)
                       initargs)))
    (setf (viewer-fixed-size-p v) (and (or width height) t))
    result))

(deftype image-viewer () 'xviewer)


;;; Generic functions

(defgeneric display-image (viewer image)
  (:documentation "Blit IMAGE (a pixmap ID matching VIEWER-CURRENT-SIZE) to the viewer window."))

(defgeneric load-image (viewer path)
  (:documentation "Decode PATH, upload to a pixmap, and return (values PIXMAP-ID WIDTH HEIGHT)."))

(defgeneric repaint-viewer (viewer)
  (:documentation "Repaint VIEWER with the current image or clear the window."))

(defgeneric advance-image (viewer delta)
  (:documentation "Advance the displayed image by DELTA positions."))

(defgeneric fit-viewer (viewer width height)
  (:documentation "Resize VIEWER's window to fit WIDTH and HEIGHT, capped at max bounds."))


;; Triangles (overlay)
;;
;; Each triangle is defined in window coordinates as three vertices and
;; a fill colour.  ALPHA is the blend factor against the underlying
;; image pixel (0.0 = invisible, 1.0 = opaque).  Because we bake them
;; into the pixmap, "translucent" here means genuine per-pixel alpha
;; compositing in Lisp -- which works on every X server, compositor or
;; not.  See the file header for why this is preferred over a RENDER
;; child window in a demo.

(defstruct tri
  x1 y1 x2 y2 x3 y3
  (color        #x202020 :type (unsigned-byte 24))
  (alpha        0.50     :type single-float)
  (border-color #xF0F0F0 :type (unsigned-byte 24))
  (border-alpha 0.90     :type single-float)
  (border-width 2        :type fixnum))

(defun layout-triangles (v)
  "Recompute triangle positions from the current window size."
  (let* ((w (xact:widget-width v))
         (h (xact:widget-height v))
         (s (viewer-scale v))
         (size (min (round (* 80 s)) (round (min w h) 6)))
         (margin (round (* 24 s)))
         (border (max 1 (round (* 2 s)))))
    (setf (viewer-prev-tri v)
          (make-tri :x1 (+ margin size) :y1 (- (round h 2) size)
                    :x2 (+ margin size) :y2 (+ (round h 2) size)
                    :x3 margin          :y3 (round h 2)
                    :border-width border))
    (setf (viewer-next-tri v)
          (make-tri :x1 (- w margin size) :y1 (- (round h 2) size)
                    :x2 (- w margin size) :y2 (+ (round h 2) size)
                    :x3 (- w margin)        :y3 (round h 2)
                    :border-width border))))

(defun triangle-bounds (tri)
  (values (min (tri-x1 tri) (tri-x2 tri) (tri-x3 tri))
          (min (tri-y1 tri) (tri-y2 tri) (tri-y3 tri))
          (max (tri-x1 tri) (tri-x2 tri) (tri-x3 tri))
          (max (tri-y1 tri) (tri-y2 tri) (tri-y3 tri))))

(defun point-in-triangle-p (px py tri)
  "Standard three-half-plane test.  Assumes counter-clockwise winding;
   we treat the sign uniformly so winding doesn't matter."
  (flet ((cross (ax ay bx by cx cy)
           (- (* (- bx ax) (- cy ay))
              (* (- by ay) (- cx ax)))))
    (let ((d1 (cross px py (tri-x1 tri) (tri-y1 tri) (tri-x2 tri) (tri-y2 tri)))
          (d2 (cross px py (tri-x2 tri) (tri-y2 tri) (tri-x3 tri) (tri-y3 tri)))
          (d3 (cross px py (tri-x3 tri) (tri-y3 tri) (tri-x1 tri) (tri-y1 tri))))
      (or (and (>= d1 0) (>= d2 0) (>= d3 0))
          (and (<= d1 0) (<= d2 0) (<= d3 0))))))

(defun edge-distance (px py ax ay bx by)
  "Perpendicular distance from (PX,PY) to the infinite line through
   (AX,AY) and (BX,BY)."
  (let* ((dx (- bx ax))
         (dy (- by ay))
         (len (sqrt (+ (* dx dx) (* dy dy)))))
    (if (zerop len)
        most-positive-double-float
        (/ (abs (- (* dx (- py ay)) (* dy (- px ax)))) len))))

(defun blend-triangle (rgb width height tri)
  "Alpha-blend TRI into RGB (a WIDTH*HEIGHT*3 byte vector), in place.
   A band of width (TRI-BORDER-WIDTH TRI) along the triangle's three
   edges is drawn in TRI-BORDER-COLOR; the interior is filled with
   TRI-COLOR."
  (multiple-value-bind (bx0 by0 bx1 by1) (triangle-bounds tri)
    (let* ((x0 (max 0 (floor bx0)))
           (y0 (max 0 (floor by0)))
           (x1 (min (1- width)  (ceiling bx1)))
           (y1 (min (1- height) (ceiling by1)))
           (ax (tri-x1 tri)) (ay (tri-y1 tri))
           (bx (tri-x2 tri)) (by (tri-y2 tri))
           (cx (tri-x3 tri)) (cy (tri-y3 tri))
           (fr (ldb (byte 8 16) (tri-color tri)))
           (fg (ldb (byte 8  8) (tri-color tri)))
           (fb (ldb (byte 8  0) (tri-color tri)))
           (fa (tri-alpha tri))
           (br (ldb (byte 8 16) (tri-border-color tri)))
           (bg (ldb (byte 8  8) (tri-border-color tri)))
           (bb (ldb (byte 8  0) (tri-border-color tri)))
           (ba (tri-border-alpha tri))
           (bw (float (tri-border-width tri) 1.0)))
      (loop for y from y0 to y1 do
        (loop for x from x0 to x1
              when (point-in-triangle-p x y tri)
                do (let* ((d  (min (edge-distance x y ax ay bx by)
                                   (edge-distance x y bx by cx cy)
                                   (edge-distance x y cx cy ax ay)))
                          (ep (< d bw))
                          (a  (if ep ba fa))
                          (cr (if ep br fr))
                          (cg (if ep bg fg))
                          (cb (if ep bb fb))
                          (a1 (- 1.0 a))
                          (i  (* (+ (* y width) x) 3)))
                     (setf (aref rgb i)
                           (min 255 (round (+ (* a cr) (* a1 (aref rgb i)))))
                           (aref rgb (+ i 1))
                           (min 255 (round (+ (* a cg) (* a1 (aref rgb (+ i 1))))))
                           (aref rgb (+ i 2))
                           (min 255 (round (+ (* a cb) (* a1 (aref rgb (+ i 2)))))))))))))


;; Pixel packing for PUT-IMAGE

(defun pack-rgb-for-put-image (v rgb width height)
  "Pack a WIDTH*HEIGHT*3 RGB byte vector into the wire format X11
   expects for PUT-IMAGE with format ZPixmap at the root visual's depth:
   WIDTH*HEIGHT*4 bytes, in the connection's byte order (see
   XCB:PACK-RGB-IMAGE)."
  (xcb:pack-rgb-image (xcb:pixel-format (xcb:find-root-visual (xd:app-screen v))
                                        (xcb:conn-byte-order (xact:widget-connection v)))
                      rgb width height))


;; Image loading and display

(defun image-layout (src-w src-h dst-w dst-h fit-p shrink-only-p)
  "Return (values SCALE OFFSET-X OFFSET-Y) for placing a SRC-W by
   SRC-H image into a DST-W by DST-H window.  With FIT-P NIL, scale is
   1.0 (native pixel size) and the image is centred.  With FIT-P T,
   scale is the aspect-preserving fit, optionally clamped to <= 1.0
   when SHRINK-ONLY-P, and the result is centred.  In every case the
   returned offsets are the integer coordinates of the scaled image's
   top-left corner in destination space and may be negative (image
   larger than window) or positive (image smaller, letterboxed)."
  (if (not fit-p)
      (values 1.0d0
              (floor (- dst-w src-w) 2)
              (floor (- dst-h src-h) 2))
      (let* ((raw   (min (/ (float dst-w 1.0d0) src-w)
                         (/ (float dst-h 1.0d0) src-h)))
             (scale (if shrink-only-p (min 1.0d0 raw) raw))
             (dw    (round (* scale src-w)))
             (dh    (round (* scale src-h))))
        (values scale
                (floor (- dst-w dw) 2)
                (floor (- dst-h dh) 2)))))

(defun scale-into (dst dst-w dst-h src src-w src-h scale ox oy)
  "Nearest-neighbour scale SRC (SRC-W x SRC-H x 3 bytes) into DST
   (DST-W x DST-H x 3 bytes), with the top-left of the scaled image at
   (OX, OY) in destination coordinates.  Pixels of the scaled image
   that fall outside DST are clipped, and DST pixels outside the
   scaled image are left as they were -- so a negative offset (image
   larger than the window) simply crops, and a positive one leaves a
   margin of whatever was pre-filled.

   Each destination column's source offset is worked out once, so the
   inner loop is three byte copies."
  ;; Sizes are X sizes, under 2^16, and offsets far smaller than 2^31,
  ;; so every index below is a fixnum.
  (declare (type (simple-array (unsigned-byte 8) (*)) dst src)
           (type (unsigned-byte 16) dst-w dst-h src-w src-h)
           (type (signed-byte 32) ox oy)
           (type real scale))
  (let* ((scale   (float scale 1.0d0))
         (drawn-w (round (* scale src-w)))
         (drawn-h (round (* scale src-h)))
         (x-start (max 0 ox))
         (y-start (max 0 oy))
         (x-end   (min dst-w (+ ox drawn-w)))
         (y-end   (min dst-h (+ oy drawn-h)))
         (columns (make-array (max 0 (- x-end x-start)) :element-type 'fixnum)))
    (declare (type double-float scale)
             (type (signed-byte 32) x-start y-start x-end y-end))
    (loop for dx of-type fixnum from x-start below x-end
          for k of-type fixnum from 0
          do (setf (aref columns k)
                   (* 3 (min (1- src-w) (floor (- dx ox) scale)))))
    (locally (declare (optimize speed (safety 0)))
      (loop for dy of-type (unsigned-byte 16) from y-start below y-end do
        (let* ((sy      (min (1- src-h) (the (unsigned-byte 16) (floor (- dy oy) scale))))
               (src-row (* sy src-w 3))
               (di      (* 3 (+ (* dy dst-w) x-start))))
          (declare (type (unsigned-byte 16) sy) (type (unsigned-byte 40) src-row di))
          (loop for k of-type fixnum below (length columns)
                do (let ((si (+ src-row (aref columns k))))
                     (declare (type fixnum si))
                     (setf (aref dst di)       (aref src si)
                           (aref dst (+ di 1)) (aref src (+ si 1))
                           (aref dst (+ di 2)) (aref src (+ si 2)))
                     (incf di 3))))))))

(defun release-pixmap (v)
  "Free V's current pixmap, and with it the RENDER picture of its text
   wrapper if it has one."
  (let ((conn (xact:widget-connection v))
        (drawable (viewer-pixmap-drawable v))
        (pixmap (viewer-current-pixmap v)))
    (setf (viewer-pixmap-drawable v) nil
          (viewer-current-pixmap v)  nil
          (viewer-current-size v)    nil)
    (cond
      ;; DESTROY-DRAWABLE frees the picture and then the pixmap.
      (drawable (ignore-errors (xcb-truetype:destroy-drawable drawable)))
      (pixmap   (ignore-errors (xcb::free-pixmap conn pixmap))))))

(defun pixmap-drawable (v)
  "Return the XCB-TRUETYPE wrapper for V's current pixmap, making it the
   first time.  The kept wrapper always belongs to the current pixmap:
   RELEASE-PIXMAP drops both together, and RERENDER installs a new
   pixmap as current before it draws anything on it."
  (or (viewer-pixmap-drawable v)
      (let ((drawable (make-instance 'xcb-truetype:pixmap :owned t
                                     :connection (xact:widget-connection v)
                                     :id (or (viewer-current-pixmap v)
                                             (error "PIXMAP-DRAWABLE: ~S has no current pixmap." v))
                                     :visual (xcb:find-root-visual (xd:app-screen v))
                                     :screen (xd:app-screen v))))
        ;; Freed explicitly by RELEASE-PIXMAP, never by the GC.
        (trivial-garbage:cancel-finalization drawable)
        (setf (viewer-pixmap-drawable v) drawable))))

(defun rerender (v)
  "Render the viewer's source image and overlays into the window-sized
   pixmap, and install it as the current pixmap.  When the help panel
   is visible, it is drawn on top of the image.  The pixmap is reused
   while the window keeps its size -- the image upload overwrites all
   of it -- and replaced when the size changes, since X pixmaps cannot
   be resized in place.  A no-op clear when there is nothing to draw."
  (let* ((conn  (xact:widget-connection v))
         (win-w (xact:widget-width v))
         (win-h (xact:widget-height v)))
    (unless (equal (viewer-current-size v) (cons win-w win-h))
      (release-pixmap v))
    (unless (xact:widget-window v)
      (return-from rerender nil))
    (let ((src    (viewer-source-rgb v))
          (help-p (viewer-help-visible-p v)))
      (unless (or src help-p)
        (release-pixmap v)
        (xcb::clear-area conn 0 (xact:widget-window v) 0 0 0 0)
        (return-from rerender nil))
      (let ((dst (make-array (* win-w win-h 3)
                             :element-type '(unsigned-byte 8)
                             :initial-element 0)))
        (when src
          (let ((src-w (viewer-source-width v))
                (src-h (viewer-source-height v)))
            (multiple-value-bind (scale ox oy)
                (image-layout src-w src-h win-w win-h
                              (viewer-fit-fullscreen-p v)
                              (viewer-shrink-only-p v))
              (scale-into dst win-w win-h src src-w src-h scale ox oy))
            (when (viewer-show-controls-p v)
              (layout-triangles v)
              (when (viewer-prev-tri v)
                (blend-triangle dst win-w win-h (viewer-prev-tri v)))
              (when (viewer-next-tri v)
                (blend-triangle dst win-w win-h (viewer-next-tri v))))))
        (let ((pixmap (or (viewer-current-pixmap v)
                          (let ((new (xcb:generate-id conn)))
                            (xcb::create-pixmap conn (xd:app-depth v) new
                                                (xact:widget-window v) win-w win-h)
                            new))))
          ;; Current from the start, so the overlays below draw through
          ;; the wrapper of this pixmap (see PIXMAP-DRAWABLE).
          (setf (viewer-current-pixmap v) pixmap
                (viewer-current-size v)   (cons win-w win-h))
          (xcb-truetype:put-image-chunked conn 2 pixmap (viewer-gc v)
                                          win-w win-h 0 0 0 (xd:app-depth v)
                                          (pack-rgb-for-put-image v dst win-w win-h))
          (when help-p
            (draw-help-panel v pixmap win-w win-h))
          (draw-grip v pixmap))))))

(defmethod fit-viewer ((v xviewer) width height)
  "Resize the window to fit WIDTH x HEIGHT, capped by the viewer's max
   bounds, unless the viewer is currently fullscreen -- in which case
   the window's size is the WM's business, not ours, and asking to
   resize here would briefly drop us out of fullscreen and make the
   image flash at the wrong size before it scales back up.  Nor when
   the user gave the window's size (VIEWER-FIXED-SIZE-P)."
  (unless (or (viewer-fullscreen-p v) (viewer-fixed-size-p v))
    (let ((nw (min width  (viewer-max-width v)))
          (nh (min height (viewer-max-height v))))
      (unless (and (= nw (xact:widget-width v)) (= nh (xact:widget-height v)))
        (setf (xact:widget-width v)  nw
              (xact:widget-height v) nh)
        (when (xact:widget-window v)
          (xcb::configure-window (xact:widget-connection v) (xact:widget-window v)
                                 (logior +config-window-width+
                                         +config-window-height+)
                                 :width nw :height nh))))))

(defmethod load-image ((v xviewer) path)
  "Decode PATH, cache its native pixels on V, size the window to fit
   the image, and render a fresh window-sized pixmap.  Returns (values
   PIXMAP-ID WIDTH HEIGHT) describing the pixmap."
  (multiple-value-bind (w h rgb)
      (xcb-demos.image-decoders:decode-image path)
    ;; The typed pixel loops (SCALE-INTO, XCB:PACK-RGB-IMAGE) want a
    ;; simple octet vector; COERCE copies only if it is not one.
    (setf (viewer-source-rgb v)    (coerce rgb '(simple-array (unsigned-byte 8) (*)))
          (viewer-source-width v)  w
          (viewer-source-height v) h)
    (fit-viewer v w h)
    (rerender v)
    (values (viewer-current-pixmap v)
            (car (viewer-current-size v))
            (cdr (viewer-current-size v)))))

(defmethod display-image ((v xviewer) image)
  "Blit IMAGE (a pixmap sized to VIEWER-CURRENT-SIZE) to the viewer
   window.  Since RERENDER keeps the pixmap at window size, this is a
   1:1 copy."
  (let ((w (car (viewer-current-size v)))
        (h (cdr (viewer-current-size v))))
    (xcb::copy-area (xact:widget-connection v) image (xact:widget-window v) (viewer-gc v)
                    0 0 0 0 w h)))

(defmethod repaint-viewer ((v xviewer))
  "Blit the current pixmap to the window, or clear the window if none."
  (if (viewer-current-pixmap v)
      (display-image v (viewer-current-pixmap v))
      (xcb::clear-area (xact:widget-connection v) 0 (xact:widget-window v) 0 0 0 0)))

(defun show-image (v index)
  (when (viewer-images v)
    (setf (viewer-current v) (mod index (length (viewer-images v))))
    (let ((path (nth (viewer-current v) (viewer-images v))))
      (handler-case
          (progn
            (load-image v path)
            (repaint-viewer v)
            (format t "~&[~D/~D] ~A  (~Dx~D)~%"
                    (1+ (viewer-current v)) (length (viewer-images v))
                    (file-namestring path)
                    (car (viewer-current-size v))
                    (cdr (viewer-current-size v))))
        (error (e)
          (format *error-output* "~&Could not load ~A: ~A~%" path e))))))

(defmethod advance-image ((v xviewer) delta)
  "Advance the displayed image by DELTA positions."
  (show-image v (+ (viewer-current v) delta)))

(defun reset-slideshow-timer (v)
  "Reset the timer for the next slide advance."
  (setf (viewer-slideshow-next v)
        (+ (get-internal-real-time)
           (round (* (viewer-interval v) internal-time-units-per-second)))))

(defun stop-slideshow (v)
  "Stop the automatic timer so the slideshow displays a static image."
  (setf (viewer-auto-advance v) nil)
  (format t "~&Slideshow stopped (displaying static image).~%")
  nil)

(defun start-slideshow (v)
  "Run the slideshow timer to cycle images automatically."
  (reset-slideshow-timer v)
  (setf (viewer-auto-advance v) t)
  (format t "~&Slideshow running (interval: ~,1F s).~%" (viewer-interval v))
  t)

(defun run-slideshow (v)
  "Run the slideshow timer to cycle images automatically (alias for START-SLIDESHOW)."
  (start-slideshow v))

(defun toggle-slideshow (v)
  "Toggle the slideshow timer between running and static."
  (if (viewer-auto-advance v)
      (stop-slideshow v)
      (start-slideshow v)))


;; Directory scan

(defun scan-images (dir)
  "Return a sorted list of readable image pathnames in DIR, matching any
   extension registered by a loaded decoder."
  (let ((exts (xcb-demos.image-decoders:supported-extensions)))
    (when exts
      (sort
       (loop for ext in exts
             append (directory (merge-pathnames
                                (format nil "*.~A" ext) dir)))
       #'string< :key #'file-namestring))))


;; Help panel

(defparameter *help-text*
  '("right arrow / r / n / space   next image"
    "left arrow / l / p            previous image"
    "s                             stop slideshow"
    "R (Shift+r)                   run slideshow"
    "t                             toggle auto-advance"
    "h                             hide / show controls"
    "g                             hide / show grip"
    "i                             fit image / native size"
    "c                             shrink-only scaling"
    "f / F11                       toggle fullscreen"
    "Ctrl+o                        choose directory"
    "Ctrl+r                        resize: arrows, Return / Escape"
    "Ctrl+m                        move: arrows, Return / Escape"
    "Ctrl-+ / Ctrl-- / Ctrl-0      this help, bigger / smaller / normal"
    "Alt- or Super-drag            the same, with the mouse"
    "?                             show / hide this help"
    "click left / right triangle   previous / next"
    "q / Escape                    exit")
  "The viewer's controls, one line each: the help overlay shows them, and
   RUN-XVIEWER prints them at start.")

(defconstant +base-font-size+ 12
  "The help overlay's font size at scale 1.")

(defun viewer-scale (v) (xact:cref (xact:widget-state v) :scale))

(defun setup-scale-cells (v)
  "The scale and the help font size, tied both ways: the --font-size
   option sets the size, Ctrl-+ and the scale drag the scale."
  (let ((st (xact:widget-state v)))
    (setf (xact:cref st :font-size) (viewer-help-font-size v)
          (xact:cref st :scale) (/ (viewer-help-font-size v) +base-font-size+))
    (xact:relate st
                 '(:scale) '(:font-size) (lambda (s) (max 6 (round (* s +base-font-size+))))
                 '(:font-size) '(:scale) (lambda (fs) (/ fs +base-font-size+)))))

(defun help-font (v)
  "The help overlay's font at the current size."
  (let ((size (xact:cref (xact:widget-state v) :font-size)))
    (or (gethash size (viewer-help-fonts v))
        (setf (gethash size (viewer-help-fonts v)) (find-help-font v size)))))

(defun find-help-font (v size)
  "Return a font for V's help overlay: the viewer's font family when
   one was given, else the first installed of a few common sans
   families, else any family.  A NIL subfamily lets XCB-TRUETYPE pick
   Regular, Book or the first available -- not an arbitrary one, which
   is what the first entry of the subfamily table would be."
  (unless (xcb-truetype:get-font-families)
    (xcb-truetype:cache-fonts))
  (let* ((families (xcb-truetype:get-font-families))
         (family (or (viewer-help-font-family v)
                     (find-if (lambda (cand) (member cand families :test #'string-equal))
                              '("DejaVu Sans" "Noto Sans" "FreeSans" "Liberation Sans"))
                     (first families))))
    (unless family
      (error "No TrueType fonts found for the help overlay."))
    ;; A family or subfamily the user named but that is not installed
    ;; signals here, from XCB-TRUETYPE's own check, as it should.
    (make-instance 'xcb-truetype:font
                   :family family
                   :subfamily (viewer-help-font-subfamily v)
                   :size size)))

(defun split-help-line (line)
  "(VALUES KEYS DESCRIPTION) of a *HELP-TEXT* line, split at its first run
   of two or more spaces; DESCRIPTION is NIL for a line without one.  The
   spaces line the columns up in a terminal; the panel's proportional
   font lines them up by measuring instead."
  (let ((gap (search "  " line)))
    (if gap
        (values (string-trim " " (subseq line 0 gap))
                (string-trim " " (subseq line gap)))
        (values line nil))))

(defun draw-help-panel (v pixmap win-w win-h)
  "Draw the help panel onto PIXMAP, centred in a WIN-W x WIN-H window.
   Uses XCB-TRUETYPE:DRAW-TEXT with antialiased text rendering."
  (let* ((conn       (xact:widget-connection v))
         (gc         (viewer-gc v))
         (font       (help-font v))
         (screen     (xd:app-screen v))
         (lines      (append '("CLXCB XViewer" "") *help-text*
                             '("" "press ? again to dismiss this help")))
         (ascent     (xcb-truetype:font-ascent screen font))
         (b2b        (xcb-truetype:baseline-to-baseline screen font))
         (width-of   (lambda (text)
                       (if (zerop (length text)) 0 (xcb-truetype:text-line-width screen font text))))
         (col-gap    (round (* 20 (viewer-scale v))))
         ;; The keys' column is as wide as the widest key.
         (keys-w     (reduce #'max lines
                             :key (lambda (line)
                                    (multiple-value-bind (keys desc) (split-help-line line)
                                      (if desc (funcall width-of keys) 0)))))
         (max-text-w (reduce #'max lines
                             :key (lambda (line)
                                    (multiple-value-bind (keys desc) (split-help-line line)
                                      (if desc
                                          (+ keys-w col-gap (funcall width-of desc))
                                          (funcall width-of keys))))))
         (text-h     (xcb-truetype:font-lines-height screen font (length lines)))
         (pad-x      (round (* 28 (viewer-scale v))))
         (pad-y      (round (* 22 (viewer-scale v))))
         (box-w      (+ max-text-w (* 2 pad-x)))
         (box-h      (+ text-h (* 2 pad-y)))
         (box-x      (max 0 (floor (- win-w box-w) 2)))
         (box-y      (max 0 (floor (- win-h box-h) 2)))
         (x1         (+ box-x box-w -1))
         (y1         (+ box-y box-h -1)))
    ;; Dark background
    (xcb::change-gc conn gc +gc-foreground+ :foreground #x101820)
    (xcb::poly-fill-rectangle
     conn pixmap gc
     (list (make-instance 'xcb::rectangle
                          :x box-x :y box-y
                          :width box-w :height box-h)))
    ;; Border, drawn as four segments
    (xcb::change-gc conn gc +gc-foreground+ :foreground #x4060A0)
    (xcb::poly-segment
     conn pixmap gc
     (list (make-instance 'xcb::segment
                          :x1 box-x :y1 box-y :x2 x1 :y2 box-y)
           (make-instance 'xcb::segment
                          :x1 x1 :y1 box-y :x2 x1 :y2 y1)
           (make-instance 'xcb::segment
                          :x1 x1 :y1 y1 :x2 box-x :y2 y1)
           (make-instance 'xcb::segment
                          :x1 box-x :y1 y1 :x2 box-x :y2 box-y)))
    ;; Text lines, through the pixmap's kept wrapper (and its picture).
    (let ((pm-drawable (pixmap-drawable v)))
      (loop for line in lines
            for i from 0
            for baseline = (+ box-y pad-y ascent (* i b2b))
            when (plusp (length line))
              do (multiple-value-bind (keys desc) (split-help-line line)
                   (xcb-truetype:draw-text pm-drawable font keys
                                           (+ box-x pad-x) baseline
                                           :colour (if desc #xA0C8FF #xE0E0E0))
                   (when desc
                     (xcb-truetype:draw-text pm-drawable font desc
                                             (+ box-x pad-x keys-w col-gap) baseline
                                             :colour #xE0E0E0)))))
    ;; Leave the GC's foreground as SETUP-WINDOW set it.
    (xcb::change-gc conn gc +gc-foreground+ :foreground (xcb:black-pixel screen))))

(defun grip-size (v)
  "Side of the square the corner grip occupies, in pixels: 16 at scale 1."
  (round (* 16 (viewer-scale v))))

(defun draw-grip (v pixmap)
  "Draw the bottom-right corner grip on PIXMAP, when
   (VIEWER-SHOW-GRIP-P V): three diagonal strokes in grey."
  (when (viewer-show-grip-p v)
    (let ((conn (xact:widget-connection v))
          (gc   (viewer-gc v)))
      (xcb::change-gc conn gc +gc-foreground+
                      :foreground (xcb:rgb->pixel (xcb:find-root-visual (xd:app-screen v)) #x80 #x80 #x80))
      (xact:draw-resize-grip conn pixmap gc (xact:widget-width v) (xact:widget-height v)
                             :size (grip-size v))
      ;; Leave the GC's foreground as SETUP-WINDOW set it.
      (xcb::change-gc conn gc +gc-foreground+ :foreground (xcb:black-pixel (xd:app-screen v))))))

(defun setup-window (v position-p)
  "Create V's window at its X, Y (100, 100 when not asked for).  With
   POSITION-P, the position was asked for, so it is also passed to the
   window manager in WM_NORMAL_HINTS, with V's gravity for the anchored
   corner; otherwise the WM places the window as it likes."
  (let* ((conn   (xact:widget-connection v))
         (black  (xcb:black-pixel (xd:app-screen v)))
         (win    (xd:realize-application
                  v :x 100 :y 100
                    :background-pixel black
                    :event-mask (logior +event-mask-exposure+
                                        +event-mask-key-press+
                                        +event-mask-button-press+
                                        ;; For drags: the scale drag, the grip.
                                        +event-mask-button-release+
                                        +event-mask-button1-motion+
                                        +event-mask-structure-notify+)))
         (gc     (xcb:generate-id conn)))
    (setf (viewer-gc v) gc)
    (xcb::create-gc conn gc win +gc-foreground+ :foreground black)
    (when position-p
      (xd:set-placement-hints v))))

(defun setup-keybindings (v)
  "Fill V's keymap with the viewer's shortcuts."
  (flet ((bind-key (keysym fn) (setf (gethash keysym (viewer-keymap v)) fn))
         (quit-key   () (setf (viewer-done v) t))
         (stop-key   () (stop-slideshow v))
         (run-key    () (run-slideshow v))
         (toggle-key () (toggle-slideshow v))
         (next-key   () (advance-image v  1))
         (prev-key   () (advance-image v -1))
         (full-key   ()
           (let* ((conn  (xact:widget-connection v))
                  (win   (xact:widget-window v))
                  (state (xcb:net-wm-state-p conn win :fullscreen)))
             (case state
               ((t)   (xcb:set-fullscreen conn win nil)
                      (setf (viewer-fullscreen-p v) nil))
               ((nil) (xcb:set-fullscreen conn win t)
                      (setf (viewer-fullscreen-p v) t))
               (:unknown
                (format *error-output*
                        "~&WM does not implement EWMH; cannot fullscreen.~%")))))
         (toggle-controls ()
           (setf (viewer-show-controls-p v) (not (viewer-show-controls-p v)))
           (rerender v)
           (repaint-viewer v)
           (format t "~&Controls: ~:[hidden~;shown~]~%"
                   (viewer-show-controls-p v)))
         (toggle-grip ()
           (setf (viewer-show-grip-p v) (not (viewer-show-grip-p v)))
           (when (viewer-grip-interactor v)
             (setf (xact:resize-grip-size (viewer-grip-interactor v))
                   (if (viewer-show-grip-p v) (grip-size v) 0)))
           (rerender v)
           (repaint-viewer v)
           (format t "~&Grip: ~:[hidden~;shown~]~%" (viewer-show-grip-p v)))
         (toggle-fit-fullscreen ()
           (setf (viewer-fit-fullscreen-p v) (not (viewer-fit-fullscreen-p v)))
           (rerender v)
           (repaint-viewer v)
           (format t "~&Image scaling: ~A~%"
                   (if (viewer-fit-fullscreen-p v)
                       "fit to window"
                       "native size")))
         (toggle-shrink-only ()
           (setf (viewer-shrink-only-p v) (not (viewer-shrink-only-p v)))
           (rerender v)
           (repaint-viewer v)
           (format t "~&Shrink-only: ~:[off~;on~]~%" (viewer-shrink-only-p v)))
         (toggle-help ()
           (setf (viewer-help-visible-p v) (not (viewer-help-visible-p v)))
           (rerender v)
           (repaint-viewer v)))

    ;; Quit
    (bind-key +xk-q-small+   #'quit-key)
    (bind-key +xk-q-capital+ #'quit-key)
    (bind-key +xk-escape+    #'quit-key)

    ;; Slideshow timer
    (bind-key +xk-s-small+   #'stop-key)
    (bind-key +xk-s-capital+ #'stop-key)
    (bind-key +xk-r-capital+ #'run-key)
    (bind-key +xk-t-small+   #'toggle-key)
    (bind-key +xk-t-capital+ #'toggle-key)

    ;; Next / previous
    (bind-key +xk-right+     #'next-key)
    (bind-key +xk-r-small+   #'next-key)
    (bind-key +xk-n-small+   #'next-key)
    (bind-key +xk-n-capital+ #'next-key)
    (bind-key +xk-space+     #'next-key)
    (bind-key +xk-left+      #'prev-key)
    (bind-key +xk-l-small+   #'prev-key)
    (bind-key +xk-l-capital+ #'prev-key)
    (bind-key +xk-p-small+   #'prev-key)
    (bind-key +xk-p-capital+ #'prev-key)

    ;; Fullscreen
    (bind-key +xk-f-small+   #'full-key)
    (bind-key +xk-f-capital+ #'full-key)
    (bind-key +xk-f11+       #'full-key)

    ;; Display modes
    (bind-key +xk-h-small+   #'toggle-controls)
    (bind-key +xk-h-capital+ #'toggle-controls)
    (bind-key +xk-g-small+   #'toggle-grip)
    (bind-key +xk-g-capital+ #'toggle-grip)
    (bind-key +xk-i-small+   #'toggle-fit-fullscreen)
    (bind-key +xk-i-capital+ #'toggle-fit-fullscreen)
    (bind-key +xk-c-small+   #'toggle-shrink-only)
    (bind-key +xk-c-capital+ #'toggle-shrink-only)

    ;; Help
    (bind-key +xk-question+  #'toggle-help)))

(defun teardown (v)
  "Release server resources allocated by the viewer."
  (let ((conn (xact:widget-connection v)))

    (release-pixmap v)
    (when (viewer-gc v)
      (let ((gc (viewer-gc v)))
        (setf (viewer-gc v) nil)
        (ignore-errors (xcb::free-gc conn gc))))
    (xact:unrealize v)))


;; Directory selection dialog

(defun set-image-directory (v dir)
  "Set the active image directory to DIR, scan for images, and display the first image."
  (let* ((dir-pathname (uiop:ensure-directory-pathname dir))
         (new-images   (scan-images dir-pathname)))
    (if (null new-images)
        (format *error-output* "~&No supported images found in ~A~%"
                (uiop:native-namestring dir-pathname))
        (progn
          (setf (viewer-image-directory v) dir-pathname
                (viewer-images v)          new-images
                (viewer-current v)         0)
          (format t "~&Loaded ~D image~:P from ~A~%"
                  (length (viewer-images v)) (uiop:native-namestring dir-pathname))
          (show-image v 0)
          t))))

(defun choose-image-directory (v &optional (default-dir (viewer-image-directory v)))
  "Open a system dialog to choose a directory with images, and reload images."
  (let ((selected (org.shirakumo.file-select:existing
                   :title "Choose Directory with Images"
                   :filter :directory
                   :default (or default-dir (uiop:getcwd)))))
    (when selected
      (set-image-directory v selected))))


;; Event loop

(defun handle-click (v x y)
  (when (and (viewer-images v) (viewer-show-controls-p v))
    (cond
      ((and (viewer-prev-tri v) (point-in-triangle-p x y (viewer-prev-tri v)))
       (advance-image v -1))
      ((and (viewer-next-tri v) (point-in-triangle-p x y (viewer-next-tri v)))
       (advance-image v  1)))))

;;; Scaling the overlays: Ctrl-+ / Ctrl-- / Ctrl-0, as commands in a keymap,
;;; and the scale drag.  Both write :SCALE; the overlays are drawn from it.

(defun set-viewer-scale (v scale)
  (let ((size (xact:cref (xact:widget-state v) :font-size)))
    (setf (xact:cref (xact:widget-state v) :scale) scale)
    (unless (eql size (xact:cref (xact:widget-state v) :font-size))
      (when (viewer-grip-interactor v)
        (setf (xact:resize-grip-size (viewer-grip-interactor v))
              (if (viewer-show-grip-p v) (grip-size v) 0)))
      (rerender v)
      (repaint-viewer v))))

(defun rescale-viewer (v factor)
  (let ((new (if factor (* factor (viewer-scale v)) 1)))
    (when (<= 1/2 new 4)
      (set-viewer-scale v new)
      (format t "~&Scale ~,2F, help font size ~D~%"
              (float (viewer-scale v)) (xact:cref (xact:widget-state v) :font-size)))))

(xact:defcommand viewer-bigger ()
  "Help, controls and grip bigger."
  (interactive)
  (rescale-viewer xact:*widget* 6/5))

(xact:defcommand viewer-smaller ()
  "Help, controls and grip smaller."
  (interactive)
  (rescale-viewer xact:*widget* 5/6))

(xact:defcommand viewer-normal-size ()
  "Back to scale 1."
  (interactive)
  (rescale-viewer xact:*widget* nil))

(defvar *viewer-scale-keymap*
  (let ((map (xact:make-keymap)))
    (xact:define-key map (xact:kbd "C-+") 'viewer-bigger)
    (xact:define-key map (xact:kbd "C-=") 'viewer-bigger)
    (xact:define-key map (xact:kbd "C--") 'viewer-smaller)
    (xact:define-key map (xact:kbd "C-0") 'viewer-normal-size)
    map))

(defclass viewer-tick (xact:interactor)
  ((viewer :initarg :viewer :reader tick-viewer))
  (:documentation "Advances the slideshow when its time comes."))

(defmethod xact:handle-tick ((i viewer-tick))
  (let ((v (tick-viewer i)))
    (when (and (viewer-auto-advance v)
               (>= (get-internal-real-time) (viewer-slideshow-next v)))
      (advance-image v 1)
      (reset-slideshow-timer v))))

(defun viewer-event (v ev)
  "Handle EV, an XCB event: keys through the keymap, clicks, exposes,
   resizes, and the close button (or XD:STOP)."
  (typecase ev
    (xcb::key-press
     (let* ((ks    (xact:xcb-event-keysym (xact:widget-connection v) ev))
            (state (slot-value ev 'xcb::state)))
       ;; Ctrl+O is the one modifier-sensitive binding.  The keymap keys
       ;; on the bare keysym only, so intercept it here and let
       ;; everything else fall through to the keymap.
       (if (and ks
                (= ks +xk-o-small+)
                (plusp (logand state +mod-mask-control+)))
           (choose-image-directory v)
           (let ((fn (and ks (gethash ks (viewer-keymap v)))))
             (when fn (funcall fn))))))
    (xcb::button-press
     (handle-click v
                   (slot-value ev 'xcb::event-x)
                   (slot-value ev 'xcb::event-y)))
    (xcb::expose (repaint-viewer v))
    (xcb::configure-notify
     (let ((w (slot-value ev 'xcb::width))
           (h (slot-value ev 'xcb::height)))
       (when (and (plusp w) (plusp h)
                  (or (/= w (xact:widget-width v)) (/= h (xact:widget-height v))))
         (setf (xact:widget-width v)  w
               (xact:widget-height v) h)
         ;; The window just changed size under us -- fullscreen toggle,
         ;; WM resize, user dragging an edge.  Rebuild the pixmap at the
         ;; new size so the image scales up (or down) and recentres.
         (rerender v)
         (repaint-viewer v))))
    (xcb::client-message
     (when (xcb:wm-delete-window-message-p (xact:widget-connection v) ev)
       (setf (viewer-done v) t)))
    (xcb::destroy-notify (setf (viewer-done v) t))
    (t nil)))

(defun event-loop (v)
  "Run V's loop with XACT:RUN-WIDGET: every event goes to VIEWER-EVENT,
   and a VIEWER-TICK runs the slideshow."
  (reset-slideshow-timer v)
  (let ((win (xact:widget-window v)))
    (xact:widget-add-interactor v (make-instance 'viewer-tick :window win :viewer v))
    ;; The grip only resizes, and lets the WM do it; presses elsewhere
    ;; stay the viewer's (the prev/next triangles).
    (setf (viewer-grip-interactor v)
          (make-instance 'xact:window-resize-interactor
                         :window win :widget v :move nil :ewmh t
                         :grip-size (if (viewer-show-grip-p v) (grip-size v) 0)))
    (xact:widget-add-interactor v (viewer-grip-interactor v))
    (xact:widget-add-interactor
     v (make-instance 'xact:scale-drag-interactor
                      :window win
                      :get (lambda () (viewer-scale v))
                      :set (lambda (scale) (set-viewer-scale v scale))))
    ;; Before the keymap: in resize mode the arrows and Escape are its.
    (xact:widget-add-interactor
     v (make-instance 'xact:key-resize-interactor
                      :window win :widget v
                      :on-start (lambda (i) (declare (ignore i))
                                  (format t "~&Resize: arrows, Return keeps, Escape cancels~%"))
                      :on-end (lambda (i confirmed) (declare (ignore i))
                                ;; A size the user chose stays, image after image.
                                (when confirmed (setf (viewer-fixed-size-p v) t)))))
    (xact:widget-add-interactor
     v (make-instance 'xact:key-move-interactor
                      :window win :widget v
                      :on-start (lambda (i) (declare (ignore i))
                                  (format t "~&Move: arrows, Return keeps, Escape cancels~%")))))
  (xact:run-widget v (xact:widget-window v)
                   :stop-when (lambda () (viewer-done v))
                   :on-other-event (lambda (ev) (viewer-event v ev))
                   :idle-sleep 0.03))


;; Entry points

(defun default-image-directory ()
  "Return (VALUES DIR IMAGES) for the viewer to open without a
   :DIRECTORY option: whichever of the current directory and the demos'
   own screenshots/ holds more images, the current directory on a tie
   (including when neither has any)."
  (let* ((cwd (uiop:getcwd))
         (screenshots (asdf:system-relative-pathname "clxcb-demos" "screenshots/"))
         (cwd-images (and (probe-file cwd) (scan-images cwd)))
         (shot-images (and (probe-file screenshots) (scan-images screenshots))))
    (if (> (length shot-images) (length cwd-images))
        (values screenshots shot-images)
        (values cwd cwd-images))))

(defun xviewer (&rest options)
  "Run the xviewer demo.  OPTIONS are the demo's declared options,
   e.g. (xviewer :directory \"~/Pictures/\" :slideshow t).  Without
   :DIRECTORY the demo falls back to DEFAULT-IMAGE-DIRECTORY."
  (apply #'run options))

(defun image-viewer (&rest options)
  "Backward-compatible alias for XVIEWER."
  (apply #'xviewer options))

(defun run-xviewer (d conn)
  "Run the xviewer demo body: one XVIEWER made from D's options."
  ;; Discover image libraries before scanning the directory -- the
  ;; scan is driven by which extensions have a registered decoder.
  (xcb-demos.image-decoders:register-all)
  (let ((exts (xcb-demos.image-decoders:supported-extensions)))
    (unless exts
      (format *error-output*
              "~&No image backends available; install libpng and CFFI.~%")
      (return-from run-xviewer nil))
    (format t "~&Supported extensions: ~{~A~^, ~}~%" exts))

  (let* ((v (xd:make-application d conn :keymaps (list *viewer-scale-keymap*)))
         (geometry (progn (setup-scale-cells v) (xd:app-geometry v)))
         (spec (and geometry (xcb:parse-geometry geometry))))
    (setf (viewer-interval v) (float (viewer-interval v) 1.0d0))
    ;; A size given by :WIDTH or :HEIGHT (see INITIALIZE-INSTANCE) or by
    ;; the geometry string fixes the window's size (see FIT-VIEWER);
    ;; otherwise it starts at 800x600 and follows each image.
    (when (or (getf spec :width) (getf spec :height))
      (setf (viewer-fixed-size-p v) t))

    (setup-keybindings v)
    (if (viewer-image-directory v)
        (let ((target-dir (uiop:ensure-directory-pathname (viewer-image-directory v))))
          (setf (viewer-image-directory v) target-dir
                (viewer-images v)          (scan-images target-dir)))
        (multiple-value-bind (target-dir cached-images)
            (default-image-directory)
          (setf (viewer-image-directory v) (and target-dir (uiop:ensure-directory-pathname target-dir))
                (viewer-images v)          cached-images)))
    (if (viewer-images v)
        (format t "~&Found ~D image~:P in ~A~%"
                (length (viewer-images v)) (uiop:native-namestring (viewer-image-directory v)))
        (format t "~&No images found in ~A. Press Ctrl+o to choose a directory.~%"
                (if (viewer-image-directory v)
                    (uiop:native-namestring (viewer-image-directory v))
                    "<none>")))

    (setup-window v (xd:resolve-placement v))
    (xcb::map-window conn (xact:widget-window v))
    (when (and (viewer-slideshow-p v) (viewer-images v))
      (start-slideshow v))

    ;; Drain the initial map/configure/expose burst.
    (loop for i from 0 below 64
          for ev = (xcb:poll-for-event conn)
          while ev
          do (typecase ev
               (xcb::configure-notify
                (let ((w (slot-value ev 'xcb::width))
                      (h (slot-value ev 'xcb::height)))
                  (when (and (plusp w) (plusp h))
                    (setf (xact:widget-width v) w
                          (xact:widget-height v) h))))
               (t nil)))

    (when (viewer-images v)
      (show-image v 0))

    (format t "~&Controls:~%~{  ~A~%~}" *help-text*)

    (unwind-protect
         (event-loop v)
      (teardown v))
    t))
