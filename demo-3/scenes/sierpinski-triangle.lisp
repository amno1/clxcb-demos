;;; sierpinski-triangle.lisp — The Sierpinski Triangle Fractal Gasket (Wacław Sierpiński, 1915).
;;;
;;; At depth 5, produces 243 filled triangles centered in the 400x400 space.

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

(defun demo ()
  (reset)
  (sierpinski-triangle :side 320.0 :depth 5 :color "crimson"))

(demo)
