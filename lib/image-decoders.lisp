;;; image-decoders.lisp — pluggable image decoding for CLXCB demos.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+.
;;;
;;; A backend is a named function that takes a pathname and returns
;;; (values WIDTH HEIGHT RGB-BYTES), where RGB-BYTES is a
;;; (simple-array (unsigned-byte 8) (*)) of length WIDTH*HEIGHT*3, one
;;; byte per channel, row-major, RGB order.
;;;
;;; Backends are discovered by trying to dlopen() a shared library and,
;;; if that succeeds, registering a decoder function against a set of
;;; filename extensions.  decode-image dispatches by extension, so an
;;; application only ever calls decode-image.

(in-package #:xcb-demos.image-decoders)

(defstruct decoder
  (name       "" :type string)
  (extensions () :type list)
  (library    nil)
  (decode-fn  nil))

(defvar *decoders* '()
  "Registered decoders, most recently added first.")

(defun register-decoder (name extensions library decode-fn)
  (setf *decoders*
        (cons (make-decoder :name name
                            :extensions extensions
                            :library library
                            :decode-fn decode-fn)
              ;; Replace any previous decoder for the same name.
              (remove name *decoders* :key #'decoder-name :test #'string=))))

(defun supported-extensions ()
  "List of file extensions (lowercase strings) that at least one
   registered decoder claims to handle."
  (remove-duplicates
   (loop for d in *decoders* append (decoder-extensions d))
   :test #'string-equal))

(defun decoder-for-extension (ext)
  (find ext *decoders*
        :key #'decoder-extensions
        :test (lambda (e exts) (member e exts :test #'string-equal))))

(defun decode-image (path)
  "Read PATH, decode it with the appropriate backend, and return
   (values WIDTH HEIGHT RGB-BYTES).  Signals an error if no backend is
   registered for the file's extension, or if the backend fails."
  (let* ((ext (pathname-type path))
         (dec (and ext (decoder-for-extension ext))))
    (unless dec
      (error "decode-image: no decoder registered for extension ~S (~A)"
             ext path))
    (funcall (decoder-decode-fn dec) path)))

#+cffi
(cffi:define-foreign-library libpng
  (:unix (:or "libpng16.so.16" "libpng16.so"
              "libpng.so.16"   "libpng.so"
              "libpng16.16.dylib" "libpng.dylib"))
  (:darwin (:or "libpng16.16.dylib" "libpng.dylib"))
  (t (:default "libpng16")))

#+cffi
(cffi:defcstruct png-image-struct
  ;; Matches png_image in png.h, which is ABI-stable since libpng 1.6.
  (opaque           :pointer)
  (version          :unsigned-int)
  (width            :unsigned-int)
  (height           :unsigned-int)
  (format           :unsigned-int)
  (flags            :unsigned-int)
  (colormap-entries :unsigned-int)
  (warning-or-error :unsigned-int)
  (message          :char :count 64))

#+cffi
(cffi:defcfun ("png_image_begin_read_from_file" %png-image-begin-read-from-file)
    :int
  (image     :pointer)
  (file-name :string))

#+cffi
(cffi:defcfun ("png_image_finish_read" %png-image-finish-read)
    :int
  (image      :pointer)
  (background :pointer)
  (buffer     :pointer)
  (row-stride :int32)
  (colormap   :pointer))

#+cffi
(cffi:defcfun ("png_image_free" %png-image-free)
    :void
  (image :pointer))

#+cffi
(defun %zero-foreign (ptr n)
  (cffi:foreign-funcall "memset" :pointer ptr :int 0 :size n :pointer))

#+cffi
(defun decode-png (path)
  "Decode a PNG file with libpng's simplified png_image API.  Returns
   (values WIDTH HEIGHT RGB-BYTES)."
  (let* ((struct-size (cffi:foreign-type-size '(:struct png-image-struct)))
         (png-image-version 1)
         (png-format-rgb    #x02))
    (cffi:with-foreign-object (image '(:struct png-image-struct))
      (%zero-foreign image struct-size)
      (setf (cffi:foreign-slot-value image '(:struct png-image-struct) 'version)
            png-image-version)
      (unless (= 1 (%png-image-begin-read-from-file
                    image (uiop:native-namestring path)))
        (error "libpng: cannot read PNG header from ~A" path))
      (setf (cffi:foreign-slot-value image '(:struct png-image-struct) 'format)
            png-format-rgb)
      (let* ((w (cffi:foreign-slot-value image '(:struct png-image-struct) 'width))
             (h (cffi:foreign-slot-value image '(:struct png-image-struct) 'height))
             (size (* w h 3)))
        (cffi:with-foreign-pointer (buf size)
          (unless (= 1 (%png-image-finish-read
                        image (cffi:null-pointer) buf 0 (cffi:null-pointer)))
            (%png-image-free image)
            (error "libpng: cannot decode PNG ~A" path))
          (let ((result (make-array size :element-type '(unsigned-byte 8))))
            (dotimes (i size)
              (setf (aref result i) (cffi:mem-aref buf :unsigned-char i)))
            (%png-image-free image)
            (values w h result)))))))

(defun try-register-png ()
  "Attempt to load libpng and register the PNG backend.  Returns T on
   success, NIL if the library isn't available on this system."
  #+cffi
  (handler-case
      (progn
        (cffi:load-foreign-library 'libpng)
        (register-decoder "libpng" '("png") 'libpng #'decode-png)
        (format t "~&[decoders] registered libpng for *.png~%")
        t)
    (error (e)
      (format t "~&[decoders] libpng not available: ~A~%" e)
      nil))
  #-cffi
  (progn
    (format t "~&[decoders] CFFI not available; libpng backend disabled.~%")
    nil))

(defun register-all ()
  "Try every known backend and register whatever loads."
  (try-register-png))
