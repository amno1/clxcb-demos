;;; xpm.lisp — reading XPM pixmap files.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; An XPM file is C source: a static array of strings holding a header
;;; ("WIDTH HEIGHT NCOLORS CHARS-PER-PIXEL"), one line per colour ("c
;;; #RRGGBB" or "c None"), and the pixel rows.  PARSE-XPM reads the
;;; common case of one character per pixel, as xsnow's Santa uses

(in-package #:xcb-demos.xpm)

(defun read-xpm-strings (path)
  "The quoted strings of the XPM file at PATH, in order, skipping
   comments: the header, the colour lines, then the pixel rows."
  (let* ((text (with-open-file (in path)
                 (let ((s (make-string (file-length in))))
                   (subseq s 0 (read-sequence s in)))))
         (n (length text))
         (i 0)
         (strings '()))
    (loop while (< i n) do
      (cond
        ((and (char= (char text i) #\/)
              (< (1+ i) n) (char= (char text (1+ i)) #\*))
         (incf i 2)
         (loop while (and (< (1+ i) n)
                          (not (and (char= (char text i) #\*)
                                    (char= (char text (1+ i)) #\/))))
               do (incf i))
         (incf i 2))
        ((char= (char text i) #\")
         (incf i)
         (let ((start i))
           (loop while (and (< i n) (not (char= (char text i) #\")))
                 do (incf i))
           (push (subseq text start i) strings)
           (incf i)))
        (t (incf i))))
    (nreverse strings)))

(defun parse-xpm (path)
  "Read the XPM file at PATH.  Returns (VALUES WIDTH HEIGHT COLORS ROWS):
   COLORS a hash table from a pixel character to its colour as an
   integer #xRRGGBB, or NIL for the transparent colour (\"None\"); ROWS
   the pixel rows as strings, one character per pixel.  Only XPMs with
   one character per pixel are read."
  (let* ((strings (read-xpm-strings path))
         (header  (mapcar #'parse-integer
                          (remove ""
                                  (uiop:split-string (first strings)
                                                     :separator " ")
                                  :test #'string=)))
         (width   (first header))
         (height  (second header))
         (ncolors (third header))
         (cpp     (fourth header)))
    (unless (= cpp 1)
      (error "parse-xpm: ~A uses ~D chars/pixel, only 1 is supported"
             path cpp))
    (let ((colors (make-hash-table))
          (color-lines (subseq strings 1 (1+ ncolors)))
          (pixel-rows  (subseq strings (1+ ncolors) (+ 1 ncolors height))))
      (dolist (line color-lines)
        (let* ((key   (char line 0))
               (parts (remove ""
                              (uiop:split-string (subseq line 1)
                                                 :separator " ")
                              :test #'string=))
               (value (second parts)))
          (setf (gethash key colors)
                (if (string-equal value "none")
                    nil
                    (parse-integer value :start 1 :radix 16)))))
      (values width height colors pixel-rows))))

;;; xpm.lisp ends here
