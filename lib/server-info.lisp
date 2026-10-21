;;; server-info.lisp — query X server configuration.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: MIT
;;;
;;; Pure query functions returning plists, plus two tiny value
;;; formatters (byte-order-name, bit-order-name) useful for rendering
;;; the data.  No printing happens here: callers decide what to show.

(in-package #:xcb-demos.server-info)

;;; Value formatters

(defun image-order-name (order)
  "Format the IMAGE-BYTE-ORDER field, which uses the IMAGE-ORDER enum
   (0 = LSBFirst, 1 = MSBFirst), not the connection byte-order encoding."
  (case order
    (0 "LSBFirst (little-endian)")
    (1 "MSBFirst (big-endian)")
    (t (format nil "unknown (~D)" order))))

(defun connection-order-name (order)
  (cond ((= order xcb:+LSB+) "LSB (little-endian)")
        ((= order xcb:+MSB+) "MSB (big-endian)")
        (t (format nil "unknown (~D)" order))))

(defun bit-order-name (order)
  (case order
    (0 "LSBFirst")
    (1 "MSBFirst")
    (t (format nil "unknown (~D)" order))))


;;; Server and wire format

(defun query-server (conn)
  "Return a plist of the setup handshake data CONN received."
  (list :vendor                 (map 'string #'code-char (xcb:conn-vendor conn))
        :protocol-major-version (xcb:conn-protocol-major-version conn)
        :protocol-minor-version (xcb:conn-protocol-minor-version conn)
        :release-number         (xcb:conn-release-number conn)
        :byte-order             (xcb:conn-byte-order conn)
        :resource-id-base       (xcb:conn-resource-id-base conn)
        :resource-id-mask       (xcb:conn-resource-id-mask conn)
        :maximum-request-length (xcb:conn-maximum-request-length conn)
        :motion-buffer-size     (xcb:conn-motion-buffer-size conn)))

(defun query-wire-format (conn)
  "Return a plist of the byte-order and bitmap-padding fields that
   govern how the client must serialize binary data."
  (list :image-byte-order     (xcb:conn-image-byte-order conn)
        :bitmap-bit-order     (xcb:conn-bitmap-format-bit-order conn)
        :bitmap-scanline-unit (xcb:conn-bitmap-format-scanline-unit conn)
        :bitmap-scanline-pad  (xcb:conn-bitmap-format-scanline-pad conn)))

(defun query-keycode-range (conn)
  "Return a plist (:MIN N :MAX M)."
  (list :min (xcb:conn-min-keycode conn)
        :max (xcb:conn-max-keycode conn)))


;;; Pixmap formats

(defun query-pixmap-formats (conn)
  "Return a list of plists, one per supported depth/pixel-size pair."
  (loop for f in (xcb:conn-pixmap-formats conn)
        collect (list :depth          (slot-value f 'xcb::depth)
                      :bits-per-pixel (slot-value f 'xcb::bits-per-pixel)
                      :scanline-pad   (slot-value f 'xcb::scanline-pad))))


;;; Screens, depths, visuals

(defun query-visual (v)
  "Return a plist describing one visual."
  (list :visual-id          (slot-value v 'xcb::visual-id)
        :class              (slot-value v 'xcb::class)
        :bits-per-rgb-value (slot-value v 'xcb::bits-per-rgb-value)
        :colormap-entries   (slot-value v 'xcb::colormap-entries)
        :red-mask           (slot-value v 'xcb::red-mask)
        :green-mask         (slot-value v 'xcb::green-mask)
        :blue-mask          (slot-value v 'xcb::blue-mask)))

(defun query-depth (d)
  "Return a plist describing one depth and the visuals it supports."
  (list :depth   (slot-value d 'xcb::depth)
        :visuals (loop for v in (slot-value d 'xcb::visuals)
                       collect (query-visual v))))

(defun query-screen (screen)
  "Return a plist describing one screen."
  (list :root                 (xcb:root screen)
        :width-in-pixels      (xcb:width-in-pixels screen)
        :height-in-pixels     (xcb:height-in-pixels screen)
        :width-in-millimeters (xcb:width-in-millimeters screen)
        :height-in-millimeters (xcb:height-in-millimeters screen)
        :root-depth           (xcb:root-depth screen)
        :root-visual          (xcb:root-visual screen)
        :default-colormap     (xcb:default-colormap screen)
        :white-pixel          (xcb:white-pixel screen)
        :black-pixel          (xcb:black-pixel screen)
        :backing-stores       (slot-value screen 'xcb::backing-stores)
        :save-unders          (slot-value screen 'xcb::save-unders)
        :min-installed-maps   (slot-value screen 'xcb::min-installed-maps)
        :max-installed-maps   (slot-value screen 'xcb::max-installed-maps)
        :depths               (loop for d in (slot-value screen 'xcb::allowed-depths)
                                    collect (query-depth d))))

(defun query-screens (conn)
  "Return a list of plists, one per attached screen."
  (loop for s in (xcb:conn-roots conn)
        collect (query-screen s)))


;;; Extensions

(defun query-extension-names (conn)
  "Return a sorted list of extension name strings the server advertises."
  (let* ((cookie (xcb::list-extensions conn))
         (reply  (xcb::list-extensions-reply conn cookie))
         (names  (slot-value reply 'xcb::names)))
    (sort (loop for s across names collect (slot-value s 'xcb::name))
          #'string<)))

(defun query-extension (conn name)
  "Return a plist describing extension NAME (a string).  On failure the
   plist has :PRESENT NIL and an :ERROR string; a truly absent
   extension also has :PRESENT NIL."
  (handler-case
      (let* ((cookie (xcb::query-extension conn name))
             (reply  (xcb::query-extension-reply conn cookie)))
        (list :name         name
              :present      (not (zerop (slot-value reply 'xcb::present)))
              :major-opcode (slot-value reply 'xcb::major-opcode)
              :first-event  (slot-value reply 'xcb::first-event)
              :first-error  (slot-value reply 'xcb::first-error)))
    (error (e)
      (list :name name :present nil :error (princ-to-string e)))))

(defun query-extensions (conn)
  "Return a list of plists, one per advertised extension."
  (loop for name in (query-extension-names conn)
        collect (query-extension conn name)))


;;; Everything

(defun query-all (conn)
  "Return a single plist containing every queryable datum about CONN."
  (list :server         (query-server conn)
        :wire-format    (query-wire-format conn)
        :keycodes       (query-keycode-range conn)
        :pixmap-formats (query-pixmap-formats conn)
        :screens        (query-screens conn)
        :extensions     (query-extensions conn)))
