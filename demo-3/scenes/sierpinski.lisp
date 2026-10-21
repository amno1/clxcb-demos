;;; sierpinski.lisp — The Sierpinski Curve and Triangle in Common Lisp Turtle Graphics.
;;;
;;; Ported from js-turtle (https://github.com/bjpop/js-turtle, 3-clause BSD / FreeBSD license).
;;; Copyright (c) 2020 Bernard Pope
;;; Common Lisp conversion copyright (c) 2026 Arthur Miller <arthur.miller@live.com>
;;;
;;; Features:
;;;   1. SIERPINSKI-CURVE: Continuous space-filling fractal curve (Wacław Sierpiński, 1912).
;;;      At level 4, produces 1024 segments that are batched and drawn instantly.
;;;   2. SIERPINSKI-TRIANGLE: The recursive Sierpinski triangle fractal gasket (1915).
;;;      At depth 5, produces 243 filled triangles.

;;; ====================================================================
;;; 1. The Sierpinski Curve
;;; ====================================================================

(defun half-sierpinski (size level)
  "Recursive helper for the Sierpinski curve."
  (if (<= level 0)
      (forward size)
      (flet ((part ()
               (half-sierpinski size (1- level))
               (left 45)
               (forward (* size (sqrt 2.0)))
               (left 45)
               (half-sierpinski size (1- level))))
        (part)
        (right 90)
        (forward size)
        (right 90)
        (part))))

(defun sierpinski-curve (&key (center-x 200.0) (center-y 200.0)
                              (span 340.0) (level 4)
                              (color "royal blue") (width 2))
  "Draw a closed Sierpinski curve centered at (CENTER-X, CENTER-Y).
   SPAN is the total width and height of the bounding square.
   LEVEL is the recursion depth (level 4 = 1024 segments)."
  (let* ((num-units (- (* 4 (expt 2 level)) 3))
         (unit-size (/ span num-units))
         (start-x (- center-x (/ unit-size 2.0)))
         (start-y (- center-y (/ span 2.0))))
    (pen-up)
    (set-position start-x start-y)
    (heading 0)
    (color color)
    (width width)
    (pen-down)
    (flet ((part ()
             (half-sierpinski unit-size level)
             (right 90)
             (forward unit-size)
             (right 90)))
      (part)
      (part))
    (pen-up)))

;;; ====================================================================
;;; 2. The Sierpinski Triangle (Recursive Fractal Gasket)
;;; ====================================================================

(defun %draw-sierpinski-triangle (order side col)
  (if (<= order 0)
      (progn
        (begin-shape)
        (forward side)
        (left 120)
        (forward side)
        (left 120)
        (forward side)
        (left 120)
        (fill-shape col))
      (let ((half (/ side 2.0)))
        (pen-up)
        (forward half)
        (pen-down)
        (%draw-sierpinski-triangle (1- order) half col)
        (pen-up)
        (left 120)
        (forward half)
        (right 120)
        (pen-down)
        (%draw-sierpinski-triangle (1- order) half col)
        (pen-up)
        (right 120)
        (forward half)
        (left 120)
        (pen-down)
        (%draw-sierpinski-triangle (1- order) half col))))

(defun sierpinski-triangle (&key (center-x 200.0) (center-y 200.0)
                                 (side 320.0) (depth 5)
                                 (color "crimson"))
  "Draw a Sierpinski triangle fractal centered at (CENTER-X, CENTER-Y).
   SIDE is the base edge length, DEPTH is recursion depth (depth 5 = 243 filled triangles)."
  (let* ((h-tri (* side (/ (sqrt 3.0) 2.0)))
         (start-x (- center-x (/ side 2.0)))
         (start-y (- center-y (/ h-tri 2.0))))
    (pen-up)
    (set-position start-x start-y)
    (heading 90)
    (pen-down)
    (%draw-sierpinski-triangle depth side color)
    (pen-up)))

(defun demo (&optional (variant :curve))
  "Draw the Sierpinski demo. VARIANT is :CURVE (default) or :TRIANGLE."
  (reset)
  (case variant
    (:triangle
     (sierpinski-triangle :side 320.0 :depth 5 :color "crimson"))
    (otherwise
     ;; Draw the continuous Sierpinski curve from js-turtle with 1024 segments.
     (sierpinski-curve :span 340.0 :level 4 :color "royal blue" :width 2))))

;; Run the demo when loading this drawing file
(demo)
