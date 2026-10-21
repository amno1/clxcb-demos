;;; virtual-root.lisp — the window that root-drawing demos draw on.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; Virtual root code adapted, like the C xroach's and xsnow's (vroot.h),
;;; from a patch sent by Colin Rafferty, who borrowed it from Tom
;;; LaStrange.
;;;
;;; Some window managers and desktops cover the real root with a window
;;; of their own, a virtual root, and make client windows its children.
;;; Anything drawn on the real root is then hidden behind it.  Such a
;;; window advertises itself with a __SWM_VROOT property, on itself,
;;; naming itself; the classic X toys (xsnow, xroach, xpenguins) look
;;; for it among the root's children and draw there instead.
;;;
;;; VIRTUAL-ROOT does the same.  Drawing, the stacking of overlays, and
;;; the cover detection that asks for the root's children should all use
;;; the window it returns.

(in-package #:xcb-demos)

(defun virtual-root (conn)
  "The window root-drawing demos should draw on: the child of CONN's
   root window that a __SWM_VROOT property names, if there is one, else
   the root window itself."
  (let* ((real-root (xcb:root-window conn))
         (vroot-atom (xcb:intern-atom-id conn "__SWM_VROOT" t)))
    ;; No client ever created the atom: no WM uses a virtual root.
    (when (zerop vroot-atom)
      (return-from virtual-root real-root))
    (let* ((children (handler-case
                         (slot-value (xcb::query-tree-reply conn (xcb::query-tree conn real-root))
                                     'xcb::children)
                       (error () #())))
           (window-atom (xcb:intern-atom-id conn "WINDOW"))
           (order (xcb:conn-byte-order conn))
           ;; Send every GetProperty, then read the replies.
           (cookies (loop for child across children
                          collect (xcb::get-property conn nil child vroot-atom window-atom 0 1))))
      ;; Read every reply, so none is left pending, and keep the first
      ;; window named.
      (let ((found nil))
        (dolist (cookie cookies)
          (handler-case
              (let* ((reply (xcb::get-property-reply conn cookie))
                     (value (slot-value reply 'xcb::value)))
                (when (and (null found)
                           (plusp (slot-value reply 'xcb::value-len))
                           (>= (length value) 4))
                  (setf found (xcb:read-card32-at
                               (coerce value '(simple-array (unsigned-byte 8) (*)))
                               0 order))))
            ;; A child can vanish between QueryTree and GetProperty.
            (error () nil)))
        (or found real-root)))))


;;; virtual-root.lisp ends here
