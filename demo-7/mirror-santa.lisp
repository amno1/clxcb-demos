;;; demo-7/mirror-santa.lisp — make the left-facing Santa sprites.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; A standalone script, not part of the clxcb-demos system: it loads
;;; the system itself and writes sprites/BigSantaRudolf<N>-left-facing.XPM
;;; next to the right-facing originals.  Run it from a shell with
;;;
;;;     sbcl --non-interactive --load demo-7/mirror-santa.lisp
;;;
;;; The dependencies must be where ASDF finds them (see the README);
;;; the clxcb-demos system itself is loaded from this checkout.
;;;
;;; One-off generator: write horizontally-mirrored ("left-facing")
;;; copies of the BigSantaRudolf XPM frames, reusing the XPM3 parser
;;; already in xsnow.lisp.  Run once; the mirrored files are checked
;;; in like any other sprite asset, not regenerated at runtime.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:load-asd (merge-pathnames "../clxcb-demos.asd" *load-truename*))
(asdf:load-system "clxcb-demos")

(defparameter *sprites-dir* demo7::*pixmap-dir*)

(defun mirror-row (row)
  "Horizontal (Y-axis) mirror of one pixel row: reflect x -> width-1-x.
   Since these XPMs use one character per pixel, that's exactly
   REVERSE on the row string."
  (reverse row))

(defun write-xpm (path var-name width height colors pixel-rows)
  "Write a plain XPM3 file: same shape PARSE-XPM reads back (one
   values line, one 'key c value' line per colour, then the pixel
   rows).  Iterating COLORS (a hash table) doesn't reproduce the
   original file's colour order, which doesn't matter: XPM colour
   tables are unordered by definition, and our own loader (like this
   generator) only cares about the key -> colour mapping."
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (format out "/* XPM */~%")
    (format out "static char *~A[] = {~%" var-name)
    (format out "/* width height num_colors chars_per_pixel */~%")
    (format out "\"~D ~D ~D 1\",~%" width height (hash-table-count colors))
    (format out "/* colors */~%")
    (loop for key being the hash-keys of colors using (hash-value rgb)
          do (format out "\"~C c ~A\",~%" key
                     (if rgb (format nil "#~6,'0X" rgb) "none")))
    (format out "/* pixels */~%")
    (loop for row in pixel-rows
          for i from 0
          do (format out "\"~A\"~:[,~;~]~%" row (= i (1- height))))
    (format out "};~%")))

(defun mirror-xpm-file (src-path dst-path var-name)
  (multiple-value-bind (width height colors pixel-rows)
      (xcb-demos.xpm:parse-xpm src-path)
    (write-xpm dst-path var-name width height colors
               (mapcar #'mirror-row pixel-rows))
    (format t "~&Wrote ~A (~Dx~D, ~D colours)~%"
            dst-path width height (hash-table-count colors))))

(dolist (name '("BigSantaRudolf1" "BigSantaRudolf2"
                "BigSantaRudolf3" "BigSantaRudolf4"))
  (let ((src (merge-pathnames (format nil "~A.XPM" name) *sprites-dir*))
        (dst (merge-pathnames (format nil "~A-left-facing.XPM" name)
                              *sprites-dir*)))
    (mirror-xpm-file src dst (format nil "~ALeftFacing" name))))

(format t "~&Done.~%")
