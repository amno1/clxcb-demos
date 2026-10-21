;;; sprites.lisp — depth-1 sprites from XBM files, drawn as stipples.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; The classic X toys draw their sprites the way the X core protocol
;;; makes cheap: a sprite is a depth-1 pixmap, and drawing it fills its
;;; bounding box with a GC whose stipple is that pixmap, placed at the
;;; sprite's position.  Where the stipple has a 1 the GC's foreground is
;;; drawn; where it has a 0, nothing (FillStippled) or the background
;;; (FillOpaqueStippled).  A mask, when there is one, is a second
;;; pixmap of the same size, for the SHAPE extension or a cursor.
;;;
;;;   (xcb-demos.sprites:with-xbm-loader (loader conn root)
;;;     (setf roach (load-xbm-sprite conn root "roach000.xbm" :loader-gc loader)))
;;;   (setf gc (make-sprite-gc conn root black-pixel))
;;;   (draw-sprite conn root gc roach x y)
;;;   ...
;;;   (free-sprite conn roach)
;;;
;;; Used by xroach and xneko.  xsnow draws its sprites as point lists on
;;; an off-screen canvas instead, which suits its many small flakes and
;;; its colour Santa (see xpm.lisp) better.

(in-package #:xcb-demos.sprites)

(defconstant +gc-foreground+ #x4)
(defconstant +gc-background+ #x8)
(defconstant +gc-fill-style+ #x100)
(defconstant +gc-stipple+    #x800)
(defconstant +gc-tile-stipple-origin-x+ #x1000)
(defconstant +gc-tile-stipple-origin-y+ #x2000)
(defconstant +fill-style-stippled+ 2)
(defconstant +fill-style-opaque-stippled+ 3)

(defstruct (sprite (:constructor %make-sprite))
  "A depth-1 sprite: PIXMAP, WIDTH by HEIGHT, and an optional MASK
   pixmap of the same size."
  (pixmap nil)
  (mask   nil)
  (width  0 :type fixnum)
  (height 0 :type fixnum))

(defmacro with-xbm-loader ((gc conn drawable) &body body)
  "Run BODY with GC bound to a depth-1 GC for uploading XBMs (see
   XCB-DEMOS.XBM:MAKE-XBM-LOADER-GC), freed afterwards.  DRAWABLE gives
   the screen."
  (let ((c (gensym "CONN")))
    `(let* ((,c ,conn)
            (,gc (xcb-demos.xbm:make-xbm-loader-gc ,c ,drawable)))
       (unwind-protect (progn ,@body)
         (ignore-errors (xcb::free-gc ,c ,gc))))))

(defun load-xbm-sprite (conn drawable path &key mask-path loader-gc)
  "Load the XBM at PATH, and the one at MASK-PATH as its mask when given,
   into depth-1 pixmaps on DRAWABLE's screen.  Returns a SPRITE.  Uses
   LOADER-GC to upload, or a GC of its own made for this call.  If a load
   fails, the pixmaps already made are freed before the error goes on."
  (unless loader-gc
    (return-from load-xbm-sprite
      (with-xbm-loader (gc conn drawable)
        (load-xbm-sprite conn drawable path :mask-path mask-path :loader-gc gc))))
  (let ((pixmap nil) (mask nil) (sprite nil))
    (unwind-protect
         (multiple-value-bind (pm w h)
             (xcb-demos.xbm:xbm->pixmap conn drawable loader-gc path)
           (setf pixmap pm)
           (when mask-path
             (setf mask (xcb-demos.xbm:xbm->pixmap conn drawable loader-gc mask-path)))
           (setf sprite (%make-sprite :pixmap pixmap :mask mask :width w :height h)))
      (unless sprite
        (when pixmap (ignore-errors (xcb::free-pixmap conn pixmap)))
        (when mask (ignore-errors (xcb::free-pixmap conn mask)))))
    sprite))

(defun free-sprite (conn sprite)
  "Free SPRITE's pixmaps."
  (when sprite
    (when (sprite-pixmap sprite) (ignore-errors (xcb::free-pixmap conn (sprite-pixmap sprite))))
    (when (sprite-mask sprite)   (ignore-errors (xcb::free-pixmap conn (sprite-mask sprite))))
    (setf (sprite-pixmap sprite) nil
          (sprite-mask sprite) nil)))

(defun make-sprite-gc (conn drawable foreground &key background)
  "A GC on DRAWABLE for DRAW-SPRITE: sprite pixels in FOREGROUND, and the
   rest of the sprite's box in BACKGROUND when given, else left as it
   was.  The caller frees it."
  (let ((gc (xcb:generate-id conn)))
    ;; Sent as a request object: the generated CREATE-GC wrapper drops
    ;; arguments whose value is 0, such as a black pixel.
    (xcb:send-request
     conn
     (if background
         (make-instance 'xcb::create-gc-request
                        :cid gc :drawable drawable
                        :value-mask (logior +gc-foreground+ +gc-background+ +gc-fill-style+)
                        :foreground foreground :background background
                        :fill-style +fill-style-opaque-stippled+)
         (make-instance 'xcb::create-gc-request
                        :cid gc :drawable drawable
                        :value-mask (logior +gc-foreground+ +gc-fill-style+)
                        :foreground foreground
                        :fill-style +fill-style-stippled+)))
    gc))

(defun draw-sprite (conn drawable gc sprite x y)
  "Draw SPRITE on DRAWABLE with its top-left corner at X Y, using GC
   (see MAKE-SPRITE-GC)."
  (xcb::change-gc conn gc
                  (logior +gc-stipple+ +gc-tile-stipple-origin-x+ +gc-tile-stipple-origin-y+)
                  :stipple (sprite-pixmap sprite)
                  :tile-stipple-x-origin x
                  :tile-stipple-y-origin y)
  (xcb::poly-fill-rectangle
   conn drawable gc
   (list (make-instance 'xcb::rectangle :x x :y y
                                        :width (sprite-width sprite)
                                        :height (sprite-height sprite)))))

(defun make-xbm-cursor (conn drawable path mask-path foreground background
                        &key (x-hot 0) (y-hot 0))
  "A cursor from the XBM at PATH and its mask at MASK-PATH, in the
   colours FOREGROUND and BACKGROUND, each a list of 16-bit (R G B).
   Returns the cursor, or NIL when either file is missing."
  (when (and (probe-file path) (probe-file mask-path))
    (let ((sprite (load-xbm-sprite conn drawable path :mask-path mask-path))
          (cursor (xcb:generate-id conn)))
      (unwind-protect
           (destructuring-bind (fr fg fb) foreground
             (destructuring-bind (br bg bb) background
               (xcb::create-cursor conn cursor (sprite-pixmap sprite) (sprite-mask sprite)
                                   fr fg fb br bg bb x-hot y-hot)))
        ;; The server keeps what it needs; the pixmaps can go.
        (free-sprite conn sprite))
      cursor)))

;;; sprites.lisp ends here
