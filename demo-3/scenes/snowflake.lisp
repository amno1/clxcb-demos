;;; snowflake.lisp — The Koch Snowflake in Common Lisp Turtle Graphics.
;;;
;;; The Koch snowflake (Niels Fabian Helge von Koch, 1904):
;;; An equilateral triangle whose every side is recursively replaced
;;; by a line with an equilateral triangular bump.
;;;
;;; At depth 4, each of the 3 sides consists of 256 segments, producing
;;; 768 crisp fractal segments that are batched and rendered instantly.

(defun side (length depth)
  "Recursively draw one side of the Koch snowflake of LENGTH and recursion DEPTH.
   At depth 0, moves forward by LENGTH.
   At depth > 0, divides LENGTH into thirds and adds a 60-degree outward bump."
  (if (<= depth 0)
      (forward length)
      (let ((third (/ length 3.0)))
        (side third (1- depth))
        (left 60)
        (side third (1- depth))
        (right 120)
        (side third (1- depth))
        (left 60)
        (side third (1- depth)))))

(defun koch-snowflake (&key (center-x 200.0) (center-y 200.0)
                            (length 280.0) (depth 4)
                            (fill "light cyan") (stroke "royal blue")
                            (width 2))
  "Draw a Koch snowflake centered at (CENTER-X, CENTER-Y).
   LENGTH is the base side length, DEPTH is the fractal recursion level.
   FILL is the optional polygon fill color (or NIL).
   STROKE is the outline stroke color (or NIL).
   WIDTH is the outline line width in pixels."
  (let* ((h-tri (* length (/ (sqrt 3.0) 2.0)))
         (start-x (- center-x (/ length 2.0)))
         (start-y (+ center-y (/ h-tri 3.0))))
    ;; 1. Optional filled interior
    (when fill
      (pen-up)
      (set-position start-x start-y)
      (heading 90)
      (begin-shape)
      (dotimes (i 3)
        (side length depth)
        (right 120))
      (fill-shape fill))

    ;; 2. Optional stroked outline
    (when stroke
      (pen-up)
      (set-position start-x start-y)
      (heading 90)
      (color stroke)
      (width width)
      (pen-down)
      (dotimes (i 3)
        (side length depth)
        (right 120))
      (pen-up))))

(defun draw-snowflake (&optional (length 280.0) (depth 4))
  "Draw the classic Koch snowflake."
  (koch-snowflake :length length :depth depth))

(defun demo ()
  "Draw the default Koch snowflake scene."
  (reset)
  ;; Draw a crystalline Koch snowflake with a soft icy-blue
  ;; interior and crisp royal blue fractal border (768 segments).
  (koch-snowflake :length 280.0 :depth 4
                  :fill "light cyan"
                  :stroke "royal blue"
                  :width 2))

;; Run the demo when loading this drawing file
(demo)
