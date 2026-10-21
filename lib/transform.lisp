;;; transform.lisp — scene-to-pixel affine transform for CLXCB demos.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; A demo that draws a scene describes that scene once, in its own
;;; coordinates, independent of the window's current size.  A transform
;;; maps those scene coordinates onto pixel coordinates each time the
;;; demo redraws.  Resizing the window therefore means recomputing the
;;; transform and redrawing — no change to the scene description itself.
;;;
;;; The transform here has four parameters: two scales and two offsets,
;;; with an implicit Y flip (scene Y up, pixel Y down).  That covers
;;; scale, translate, and Y-flip — the three operations every resizable
;;; demo needs.  Rotation and mirroring would need a full 2x3 affine
;;; matrix; if and when a demo wants them, this struct grows the other
;;; two parameters and TRANSFORM-POINT grows two multiplications.
;;;
;;; The struct is named SCENE-TRANSFORM rather than TRANSFORM so that a
;;; demo porting C code that has its own Transform — XEYES and XCLOCK
;;; both do — can define it locally without the name colliding with
;;; this one through the package inheritance that DEFINE-DEMO sets up.

(in-package #:xcb-demos)

(defstruct (scene-transform (:constructor %make-scene-transform))
  (sx 1.0 :type single-float :read-only t)
  (sy 1.0 :type single-float :read-only t)
  (tx 0.0 :type single-float :read-only t)
  (ty 0.0 :type single-float :read-only t))

(defun fit-transform (scene-width scene-height
                      pixel-width pixel-height
                      &key (padding 0))
  "Return the transform that maps a SCENE-WIDTH x SCENE-HEIGHT scene
   onto a PIXEL-WIDTH x PIXEL-HEIGHT window, uniformly scaled to fit
   and centred.

   Uniform scale means a circle in the scene stays a circle on screen,
   rather than stretching into an ellipse when the window's aspect
   ratio differs from the scene's.  If the window is wider than the
   scene, the scene is centred horizontally with empty margins; if
   taller, vertically.

   PADDING, if supplied, is the number of pixels to leave on every side."
  (let* ((usable-w (max 1 (- pixel-width (* 2 padding))))
         (usable-h (max 1 (- pixel-height (* 2 padding))))
         (s (min (/ usable-w (float scene-width))
                 (/ usable-h (float scene-height))))
         (drawn-w (* s scene-width))
         (drawn-h (* s scene-height)))
    (%make-scene-transform
     :sx (float s 1.0)
     :sy (float s 1.0)
     :tx (float (/ (- pixel-width drawn-w) 2) 1.0)
     :ty (float (/ (+ pixel-height drawn-h) 2) 1.0))))

(defun stretch-transform (scene-width scene-height
                          pixel-width pixel-height)
  "Return the transform that maps the scene onto the window,
   non-uniformly: the scene's horizontal axis maps onto the window's
   horizontal axis and its vertical onto the vertical, so a circle
   becomes an ellipse when the window is not the scene's aspect ratio.

   Cheaper to compute than FIT-TRANSFORM and useful when the scene has
   no circular elements, or when filling the window matters more than
   preserving shape."
  (%make-scene-transform
   :sx (float (/ pixel-width  (float scene-width))  1.0)
   :sy (float (/ pixel-height (float scene-height)) 1.0)
   :tx 0.0
   :ty (float pixel-height 1.0)))

(defun transform-x (tr scene-x)
  (round (+ (* (scene-transform-sx tr) scene-x) (scene-transform-tx tr))))

(defun transform-y (tr scene-y)
  (round (- (scene-transform-ty tr) (* (scene-transform-sy tr) scene-y))))

(defun transform-point (tr scene-x scene-y)
  (values (transform-x tr scene-x)
          (transform-y tr scene-y)))

(defun transform-segment (tr seg)
  "Return SEG (an XCB::SEGMENT in scene coordinates) transformed into a
   fresh XCB::SEGMENT in pixel coordinates.  A new object is returned
   rather than mutating SEG, so the scene's own representation stays in
   scene coordinates and the transform can be recomputed without
   losing the original."
  (multiple-value-bind (x1 y1)
      (transform-point tr (slot-value seg 'xcb::x1) (slot-value seg 'xcb::y1))
    (multiple-value-bind (x2 y2)
        (transform-point tr (slot-value seg 'xcb::x2) (slot-value seg 'xcb::y2))
      (make-instance 'xcb::segment :x1 x1 :y1 y1 :x2 x2 :y2 y2))))

(defun transform-segments (tr segments)
  (mapcar (lambda (s) (transform-segment tr s)) segments))
