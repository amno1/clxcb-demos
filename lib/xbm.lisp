;;; xbm.lisp — XBM (X BitMap) reader and depth-1 pixmap loader.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+

(in-package #:xcb-demos.xbm)

;;; On-disk format vs. wire format
;;;
;;; An XBM file is a C source fragment of the form:
;;;
;;;     #define NAME_width  N
;;;     #define NAME_height M
;;;     static unsigned char NAME_bits[] = {
;;;         0x00, 0x00, ...
;;;     };
;;;
;;; Bits are stored MSB-first, row-major, with each row padded up to a
;;; byte boundary.  The X11 wire format for a PutImage request with
;;; format XYBitmap, depth 1 is *almost* the same, but differs in two
;;; respects:
;;;
;;;   1. Wire rows are padded to BITMAP-FORMAT-SCANLINE-PAD bits (32
;;;      bits on every server in practice), not to a whole byte.  For
;;;      a 32-wide sprite the two happen to coincide; for a 16-wide or
;;;      24-wide sprite they do not, and a request that ships raw XBM
;;;      bytes will be rejected with a BadLength error.
;;;
;;;   2. Wire bits are emitted in BITMAP-FORMAT-BIT-ORDER order.  This
;;;      is LSBFirst on little-endian servers, the opposite of XBM's
;;;      MSB-first convention, so a raw upload draws each 8-pixel group
;;;      in the wrong horizontal order.
;;;
;;; XBM-BYTES->WIRE below bridges both differences.  READ-XBM only
;;; parses the file into (VALUES WIDTH HEIGHT BYTES); the repacking
;;; happens at upload time, in XBM->PIXMAP, once the connection's
;;; scanline-pad and bit-order are known.

(defconstant +gc-foreground+ #x4
  "GCValue: foreground pixel.")
(defconstant +gc-background+ #x8
  "GCValue: background pixel.")

(defun %line-value (line)
  "Return the integer following the last space in LINE."
  (parse-integer line :start (1+ (position #\Space line :from-end t))))

(defun read-xbm (path)
  "Parse the XBM file at PATH.  Returns (values WIDTH HEIGHT BYTES)
   where BYTES is a (simple-array (unsigned-byte 8) (*)) containing
   the file's bytes in file order, exactly as they appear in the file.

   The bytes are *not* in the wire format a PutImage request expects:
   rows are byte-aligned, not scanline-pad aligned, and bits are MSB-
   first.  Pass BYTES through XBM-BYTES->WIRE before uploading, or
   use XBM->PIXMAP which does both steps."
  (let ((width  nil)
        (height nil)
        (bytes  '()))
    (with-open-file (in path :direction :input)
      (loop for line = (read-line in nil nil)
            while line do
            (cond
              ((and (not width) (search "_width " line))
               (setf width (%line-value line)))
              ((and (not height) (search "_height " line))
               (setf height (%line-value line)))
              (t
               ;; A data line may contain many "0xNN" tokens; collect
               ;; them all, ignoring anything else on the line.
               (let ((i 0) (n (length line)))
                 (loop while (< i n) do
                   (if (and (< (+ i 2) n)
                            (char= (char line i) #\0)
                            (char= (char line (1+ i)) #\x)
                            (digit-char-p (char line (+ i 2)) 16))
                       (let ((end (or (position-if-not
                                       (lambda (c) (digit-char-p c 16))
                                       line :start (+ i 2))
                                      n)))
                         (push (parse-integer line :start (+ i 2)
                                                    :end   end
                                                    :radix 16)
                               bytes)
                         (setf i end))
                       (incf i))))))))
    (unless (and width height)
      (error "read-xbm: ~A: missing _width or _height" path))
    (values width height
            (coerce (nreverse bytes)
                    '(simple-array (unsigned-byte 8) (*))))))

(defun xbm-files (directory)
  "Return a sorted list of *.xbm files in DIRECTORY."
  (sort (directory (merge-pathnames "*.xbm" directory))
        #'string< :key #'file-namestring))

(defun %reverse-byte (b)
  "Reverse the bit order of the low 8 bits of B."
  (declare (type (unsigned-byte 8) b))
  (loop with r of-type (unsigned-byte 8) = 0
        for i from 0 below 8
        do (setf r (logior (ash r 1) (logand b 1))
                 b (ash b -1))
        finally (return r)))

(defun xbm-bytes->wire (bytes width height scanline-pad bit-order)
  "Repack raw XBM bytes into the wire format X11's PUT-IMAGE expects
   for XYBitmap at depth 1.  SCANLINE-PAD is the server's
   BITMAP-FORMAT-SCANLINE-PAD in bits; BIT-ORDER is its
   BITMAP-FORMAT-BIT-ORDER (0 = LSBFirst, 1 = MSBFirst).  When
   BIT-ORDER is 0, bits within each byte are reversed to convert from
   XBM's MSB-first convention."
  (let* ((xbm-row   (ceiling width 8))
         (wire-row  (* (ceiling width scanline-pad)
                       (ceiling scanline-pad 8)))
         (out       (make-array (* wire-row height)
                                :element-type '(unsigned-byte 8)
                                :initial-element 0))
         (reverse-p (zerop bit-order)))
    (dotimes (row height)
      (let ((in-base  (* row xbm-row))
            (out-base (* row wire-row)))
        (dotimes (col xbm-row)
          (let ((b (aref bytes (+ in-base col))))
            (setf (aref out (+ out-base col))
                  (if reverse-p (%reverse-byte b) b))))))
    out))

(defun make-xbm-loader-gc (conn root)
  "Create a depth-1 GC suitable for uploading XBM data via PUT-IMAGE.

   BACKGROUND is set explicitly to 0.  The default for a new depth-1
   GC is all-ones, which would make PUT-IMAGE with format XYBitmap
   store a 1 in every target pixel regardless of the source data,
   producing a solid all-ones pixmap.  The convenience wrapper cannot
   be used here because it drops keyword arguments whose value is 0.

   The 1x1 depth-1 pixmap the GC is homed on is freed immediately;
   per the X11 spec a GC does not retain a reference to its creation
   drawable, so the GC outlives it.  The caller owns the GC."
  (let* ((temp (xcb:generate-id conn))
         (gc   (xcb:generate-id conn)))
    (xcb::create-pixmap conn 1 temp root 1 1)
    (xcb:send-request
     conn
     (make-instance 'xcb::create-gc-request
                    :cid        gc
                    :drawable   temp
                    :value-mask (logior +gc-foreground+ +gc-background+)
                    :foreground 1
                    :background 0))
    (ignore-errors (xcb::free-pixmap conn temp))
    gc))

(defun xbm->pixmap (conn root loader-gc path)
  "Load the XBM at PATH as a fresh depth-1 Pixmap on ROOT.  LOADER-GC
   must be a depth-1 GC, such as one from MAKE-XBM-LOADER-GC; it is
   used as the PUT-IMAGE upload channel and left untouched.
   Returns (values PIXMAP WIDTH HEIGHT)."
  (multiple-value-bind (w h bytes) (read-xbm path)
    (let* ((wire (xbm-bytes->wire
                  bytes w h
                  (xcb:conn-bitmap-format-scanline-pad conn)
                  (xcb:conn-bitmap-format-bit-order conn)))
           (pm   (xcb:generate-id conn)))
      (xcb::create-pixmap conn 1 pm root w h)
      (xcb::put-image conn 0 pm loader-gc w h 0 0 0 1
                      (coerce wire 'list))
      (values pm w h))))
