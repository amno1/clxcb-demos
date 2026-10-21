;;; square-and-star.lisp — A geometric square with diagonal, and a five-pointed star.

(pen-down)
(forward 100)
(heading 90)
(forward 100)
(heading 180)
(forward 100)
(heading 270)
(forward 100)

(pen-up)
(forward 50)
(heading 45)
(pen-down)
(forward 141)                    ; the square's diagonal

(pen-up)
(heading 0)
(forward 30)
(pen-down)
(loop repeat 5
      do (forward 60)
         (heading (+ 144 (heading))))
