;;; quickstart.lisp — Quickstart / server-info demo.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: MIT
;;;
;;; A one-shot demo: connect, print a report on the server's
;;; configuration, demonstrate atom interning and resource-ID
;;; generation, then close the connection and exit.
;;;
;;; Unlike the interactive demos this one has no event loop, so
;;; STOP-REQUESTED-P is never consulted; the thread exits on its
;;  own
;;; once QUICKSTART returns.  START and STOP are still provided,
;;; uniformly with the other demos, by the framework
;;; in packages.lisp.

(xd:define-demo :quickstart ()
  (format t "~&========================================~%")
  (format t "       CLXCB Quickstart Demo           ~%")
  (format t "========================================~%")
  (format t "Connected.~%")

  (print-server          (xdi:query-server conn))
  (print-wire-format     (xdi:query-wire-format conn))
  (print-keycodes        (xdi:query-keycode-range conn))
  (print-pixmap-formats  (xdi:query-pixmap-formats conn))
  (loop for s in (xdi:query-screens conn)
        for i from 0
        do (print-screen s i))
  (print-extensions      (xdi:query-extensions conn))

  (print-root-geometry   conn)
  (print-atom-interning  conn)
  (print-generated-ids   conn)

  (format t "~&~%Demo completed successfully.~%")
  t)


;;; Small helpers

(defun section (title)
  (format t "~&~%=== ~A ===~%" title))


;;; Section printers.  All of them take a plist that came from
;;; one of the QUERY-* functions in XCB-DEMOS.

(defun print-server (info)
  (section "Server")
  (format t "  Vendor           : ~A~%" (getf info :vendor))
  (format t "  Protocol version : X~D.~D (server release ~D)~%"
          (getf info :protocol-major-version)
          (getf info :protocol-minor-version)
          (getf info :release-number))
  (format t "  Byte order       : ~A~%"
          (xdi:connection-order-name (getf info :byte-order)))
  (format t "  Resource ID base : #x~8,'0X~%"
          (getf info :resource-id-base))
  (format t "  Resource ID mask : #x~8,'0X~%"
          (getf info :resource-id-mask))
  (format t "  Max request len  : ~D words (~D bytes)~%"
          (getf info :maximum-request-length)
          (* 4 (getf info :maximum-request-length)))
  (format t "  Motion buf size  : ~D~%"
          (getf info :motion-buffer-size)))

(defun print-wire-format (info)
  (section "Wire format")
  (format t "  Image byte order     : ~A~%"
          (xdi:image-order-name (getf info :image-byte-order)))
  (format t "  Bitmap bit order     : ~A~%"
          (xdi:bit-order-name (getf info :bitmap-bit-order)))
  (format t "  Bitmap scanline unit : ~D bits~%"
          (getf info :bitmap-scanline-unit))
  (format t "  Bitmap scanline pad  : ~D bits~%"
          (getf info :bitmap-scanline-pad)))

(defun print-keycodes (info)
  (section "Keycodes")
  (let ((min (getf info :min))
        (max (getf info :max)))
    (format t "  Range : ~D .. ~D (~D keys)~%"
            min max (1+ (- max min)))))

(defun print-pixmap-formats (formats)
  (section (format nil "Pixmap formats (~D)" (length formats)))
  (dolist (f formats)
    (format t "  depth ~2D  bpp ~2D  scanline-pad ~D~%"
            (getf f :depth)
            (getf f :bits-per-pixel)
            (getf f :scanline-pad))))

(defun print-visual (v)
  (format t "      #x~8,'0X  class ~D  bpp ~D  cmap-entries ~D~%"
          (getf v :visual-id)
          (getf v :class)
          (getf v :bits-per-rgb-value)
          (getf v :colormap-entries))
  (format t "        masks  R:#x~8,'0X  G:#x~8,'0X  B:#x~8,'0X~%"
          (getf v :red-mask)
          (getf v :green-mask)
          (getf v :blue-mask)))

(defun print-screen (s idx)
  (let ((w-px (getf s :width-in-pixels))
        (h-px (getf s :height-in-pixels))
        (w-mm (getf s :width-in-millimeters))
        (h-mm (getf s :height-in-millimeters)))
    (section (format nil "Screen ~D" idx))
    (format t "  Root window      : #x~8,'0X~%" (getf s :root))
    (format t "  Dimensions       : ~D x ~D pixels (~D x ~D mm)~%"
            w-px h-px w-mm h-mm)
    (when (and (plusp w-mm) (plusp h-mm))
      (format t "  Resolution       : ~,1F x ~,1F dpi~%"
              (/ (* w-px 25.4) w-mm)
              (/ (* h-px 25.4) h-mm)))
    (format t "  Root depth       : ~D bpp~%"
            (getf s :root-depth))
    (format t "  Root visual      : #x~8,'0X~%"
            (getf s :root-visual))
    (format t "  Default colormap : #x~8,'0X~%"
            (getf s :default-colormap))
    (format t "  White / black    : #x~8,'0X / #x~8,'0X~%"
            (getf s :white-pixel) (getf s :black-pixel))
    (format t "  Backing stores   : ~D~%"
            (getf s :backing-stores))
    (format t "  Save unders      : ~:[no~;yes~]~%"
            (getf s :save-unders))
    (format t "  Installed maps   : min ~D, max ~D~%"
            (getf s :min-installed-maps)
            (getf s :max-installed-maps))
    (format t "  Allowed depths   : ~{~D~^, ~}~%"
            (mapcar (lambda (d)
                      (getf d :depth)) (getf s :depths)))
    (dolist (d (getf s :depths))
      (let ((visuals (getf d :visuals)))
        (format t "    depth ~2D, ~D visual~:P:~%"
                (getf d :depth) (length visuals))
        (dolist (v visuals) (print-visual v))))))

(defun print-extensions (exts)
  (section (format nil "Extensions (~D)" (length exts)))
  (let ((col (1+ (reduce #'max exts
                         :key (lambda (e) (length (getf e :name)))
                         :initial-value 0))))
    (dolist (e exts)
      (let ((name (getf e :name)))
        (cond
          ((getf e :error)
           (format t "  ~A~VT [query failed: ~A]~%"
                   name col (getf e :error)))
          ((getf e :present)
           (format
            t "  ~A~VT opcode ~3D  events ~3D..  errors ~3D..~%"
            name col
            (getf e :major-opcode)
            (getf e :first-event)
            (getf e :first-error)))
          (t
           (format t "  ~A~VT [not present]~%" name col)))))))


;;; Live demonstrations

(defun print-atom-interning (conn)
  (section "Atom interning")
  (dolist (atom-name '("WM_NAME" "WM_CLASS" "WM_PROTOCOLS"
                       "_NET_WM_NAME" "_NET_WM_PID" "STRING"))
    (let ((id (xcb:intern-atom-id conn atom-name)))
      (format t "  ~16A -> ~5D   (resolved: ~S)~%"
              atom-name id (xcb:atom-name conn id)))))

(defun print-generated-ids (conn)
  (section "Resource ID generation")
  (dotimes (i 3)
    (format t "  #x~8,'0X~%" (xcb:generate-id conn))))

(defun print-root-geometry (conn)
  (section "Root window geometry")
  (let* ((root   (xcb:root-window conn))
         (cookie (xcb::get-geometry conn root))
         (reply  (xcb::get-geometry-reply conn cookie)))
    (format
     t "  Sent GET-GEOMETRY for root #x~8,'0X (serial ~D)~%"
     root cookie)
    (format t "  Received reply:~%")
    (format t "    Position       : (~D, ~D)~%"
            (slot-value reply 'xcb::x)
            (slot-value reply 'xcb::y))
    (format t "    Size           : ~D x ~D~%"
            (slot-value reply 'xcb::width)
            (slot-value reply 'xcb::height))
    (format t "    Border width   : ~D px~%"
            (slot-value reply 'xcb::border-width))
    (format t "    Depth          : ~D bpp~%"
            (slot-value reply 'xcb::depth))))


