;;; basic-window.lisp — Basic Window Manipulation Demo for CLXCB
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+

;;; Commentary:

;;; 2. Basic Window Manipulation
;;;
;;;  Open a connection to the X11 display server.
;;;  Initialize a window.
;;;  Map the window on the screen.
;;;  Run an event loop driven by xact.
;;;  Read mouse and keyboard events.
;;;  Cleanly unmap the window and exit when the frame's close button is
;;;  pressed, or when (XD:STOP 2) is called.

;;; Code:

(xd:define-demo :basic-window (:wm-title "CLXCB Basic Window Demo"
                               :wm-class "basic-window"
                               :app status-widget)
  (format t "~&=== Basic Window Demo ===~%")
  (unless (plusp (hash-table-count runes/xcb:*font-cache*))
    (runes/xcb:cache-fonts))
  (let* ((widget (xd:make-application d conn :width 500 :height 350
                                             :x 100 :y 100))
         (screen (xd:app-screen widget))
         (wid    (xd:realize-application widget
                                         :border-width 2
                                         :background-pixel (xcb:white-pixel screen)
                                         :border-pixel     (xcb:black-pixel screen)
                                         ;; Every event the logger reports.
                                         :event-mask       (logior +event-mask-key-press+
                                                                   +event-mask-key-release+
                                                                   +event-mask-button-press+
                                                                   +event-mask-button-release+
                                                                   +event-mask-enter-window+
                                                                   +event-mask-leave-window+
                                                                   +event-mask-pointer-motion+
                                                                   +event-mask-exposure+
                                                                   +event-mask-structure-notify+)))
         (gc     (xcb:generate-id conn)))
    ;; After the window: a GC is created on an existing drawable.
    (xcb::create-gc conn gc wid +gc-foreground+
                    :foreground (xcb:black-pixel screen))
    (xact:show widget)

    (let* ((tt-win  (make-instance 'runes/xcb:window
                                   :connection conn
                                   :id         wid
                                   :visual     (xd:app-visual widget)
                                   :screen     screen))
           (tt-font (make-instance 'runes/xcb:font
                                   :family    "DejaVu Sans Mono"
                                   :subfamily "Book"
                                   :size      14))
           (logger (make-instance 'logger-interactor
                                  :window wid
                                  :widget widget)))
      (setf (status-widget-tt-window widget) tt-win
            (status-widget-tt-font widget)   tt-font)
      (trivial-garbage:cancel-finalization tt-win)
      (xact:widget-add-interactor widget logger)
      (unwind-protect
           (xact:run-widget widget wid
                            :stop-when (lambda () (logger-done-p logger)))

        (format t "~&=== [6] Cleanly Unmap Window & Exit ===~%")
        ;; The window is the application's: free only the wrapper's
        ;; picture (DESTROY-DRAWABLE would destroy the window too, which
        ;; UNREALIZE does below).
        (runes/xcb:release-drawable tt-win)
        (ignore-errors (xcb::free-gc conn gc))
        (xact:unrealize widget)
        (format t "  Window resources cleanly released.~%")))))

(defun button-name (button-code)
  "Return human-readable mouse button description."
  (case button-code
    (1 "Left Button")
    (2 "Middle Button")
    (3 "Right Button")
    (4 "Scroll Up")
    (5 "Scroll Down")
    (t (format nil "Button #~D" button-code))))

(defun format-modifiers (state)
  "Format active modifier keys from event STATE bitmask."
  (let ((mods nil))
    (unless (zerop (logand state 1))  (push "Shift" mods))
    (unless (zerop (logand state 4))  (push "Control" mods))
    (unless (zerop (logand state 8))  (push "Mod1(Alt)" mods))
    (unless (zerop (logand state 64)) (push "Mod4(Super)" mods))
    (if mods
        (format nil " [~{~A~^, ~}]" (nreverse mods))
        "")))

(defclass status-widget (xd:application)
  ((tt-window :initform nil :accessor status-widget-tt-window)
   (tt-font   :initform nil :accessor status-widget-tt-font)
   (text      :initform "Waiting for events..."
              :accessor status-widget-text)))

(defmethod xact:draw ((w status-widget) surface)
  (let ((conn (xact:widget-connection w)))
    (xcb::clear-area conn 0 surface 0 0 0 0)
    (runes/xcb:draw-text (status-widget-tt-window w)
                            (status-widget-tt-font w)
                            (status-widget-text w)
                            16 32
                            :colour #x000000)))

(defclass logger-interactor (xact:interactor)
  ((widget :initarg :widget :reader logger-widget)
   (done   :initform nil :accessor logger-done-p)))

(defun log-and-show (i summary)
  (format t "~&  ~A~%" summary)
  (let ((w (logger-widget i)))
    (setf (status-widget-text w) summary)
    (setf (xact:widget-dirty-p w) t)))

(defmethod xact:handle-event ((i logger-interactor) (ev xact:key-press))
  (log-and-show i (format nil "KeyPress  keycode ~D~A"
                          (xact:event-keycode ev)
                          (format-modifiers (xact:event-modifiers ev))))
  t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:key-release))
  (log-and-show i (format nil "KeyRelease  keycode ~D" (xact:event-keycode ev)))
  t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:button-press))
  (log-and-show i (format nil "ButtonPress  ~A  at (~D, ~D)"
                          (button-name (xact:event-button ev))
                          (xact:event-x ev) (xact:event-y ev)))
  t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:button-release))
  (log-and-show i (format nil "ButtonRelease  ~A  at (~D, ~D)"
                          (button-name (xact:event-button ev))
                          (xact:event-x ev) (xact:event-y ev)))
  t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:motion-event))
  (log-and-show i (format nil "Motion  (~D, ~D)"
                          (xact:event-x ev) (xact:event-y ev)))
  t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:enter-event))
  (log-and-show i (format nil "EnterWindow  (~D, ~D)"
                          (xact:event-x ev) (xact:event-y ev)))
  t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:leave-event))
  (log-and-show i (format nil "LeaveWindow  (~D, ~D)"
                          (xact:event-x ev) (xact:event-y ev)))
  t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:expose-event))
  (log-and-show i (format nil "Expose  ~Dx~D at (~D, ~D)"
                          (xact:event-width ev) (xact:event-height ev)
                          (xact:event-x ev) (xact:event-y ev)))
  t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:configure-event))
  (log-and-show i (format nil "Configure  ~Dx~D at (~D, ~D)"
                          (xact:event-width ev) (xact:event-height ev)
                          (xact:event-x ev) (xact:event-y ev)))
  t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:map-event))
  (log-and-show i "MapNotify") t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:unmap-event))
  (log-and-show i "UnmapNotify") t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:destroy-event))
  (log-and-show i "DestroyNotify") t)

(defmethod xact:handle-event ((i logger-interactor) (ev xact:close-event))
  (log-and-show i "WM_DELETE_WINDOW")
  (setf (logger-done-p i) t)
  t)

;;; basic-window.lisp ends here
