;;; color-picker.lisp — Colour Picker demo for CLXCB.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; A modern, antialiased colour picker window.  The picker is xact's
;;; COLOR-PICKER widget (system xact/color-picker): an SV square, a hue
;;; strip, a Pick button that samples the screen, and three sliders, RGB
;;; or HSV.  The demo's application is that widget in a managed window,
;;; with q / Escape to quit and r / h to switch the sliders.

(xd:define-demo :color-picker
    (:wm-title "CLXCB Colour Picker"
     :wm-class  "clxcb-colour-picker"
     :resource-class "ColorPicker"
     :app color-picker-app
     :options (:width :height :x :y :geometry
               :background :foreground
               :font-family :font-subfamily :font-size :mode))
  (format t "~&========================================~%")
  (format t "   CLXCB Colour Picker (demo10)        ~%")
  (format t "========================================~%")
  (run-color-picker d conn))

(defclass color-picker-app (xd:application xact:color-picker)
  ;; The picker's own slots hold :MODE and the font options; the colours
  ;; are names here, turned into the picker's pixels when the window is
  ;; made.  An unrequested position is 100, 100.
  ((xact::width :type (integer 240)
                :documentation "Initial window width.")
   (xact::height :type (integer 320)
                 :documentation "Initial window height.")
   (background :initarg :background :initform nil :type (or null string integer)
               :documentation "Background colour.")
   (foreground :initarg :foreground :initform nil :type (or null string integer)
               :documentation "Foreground colour."))
  (:default-initargs :width 360 :height 500))

(defclass picker-mode-keys (xact:interactor)
  ((picker :initarg :picker :reader keys-picker))
  (:documentation "r and h switch the picker to RGB and HSV sliders."))

(defmethod xact:handle-event ((i picker-mode-keys) (ev xact:key-press))
  (case (xact:event-keysym ev)
    ((#\r #\R) (xact:set-picker-mode (keys-picker i) :rgb) t)
    ((#\h #\H) (xact:set-picker-mode (keys-picker i) :hsv) t)))

(defun run-color-picker (d conn)
  (let* ((app    (xd:make-application d conn
                                      :on-change
                                      (lambda (r g b)
                                        (format t "~&Selected #~2,'0X~2,'0X~2,'0X (R:~D G:~D B:~D)~%"
                                                r g b r g b))))
         (screen (xd:app-screen app))
         (visual (xcb:find-root-visual screen))
         ;; A position in the geometry string or :X / :Y wins; else 100, 100.
         (position-p (xd:resolve-placement app :min-size 240)))
    (with-slots (background foreground) app
      (setf (xact:picker-pixel-bg app)
            (xcb:parse-color conn screen background (xcb:rgb->pixel visual 24 24 28))
            (xact:picker-pixel-fg app)
            (xcb:parse-color conn screen foreground (xcb:rgb->pixel visual 240 240 245))
            (xact:widget-width app)  (max 240 (xact:widget-width app))
            (xact:widget-height app) (max 320 (xact:widget-height app))))
    (unwind-protect
         (let* ((win  (xd:realize-application        ; builds the picker in it, too
                       app :x 100 :y 100
                           :background-pixel (xact:picker-pixel-bg app)
                           :event-mask (logior +event-mask-exposure+
                                               +event-mask-key-press+
                                               +event-mask-structure-notify+)))
                (quit (make-instance 'xact:quit-interactor :window win)))
           (xact:widget-add-interactor app (make-instance 'picker-mode-keys
                                                          :window win :picker app))
           (xact:widget-add-interactor app quit)
           ;; Last, so in resize mode it sees the arrows and Escape first.
           (xact:widget-add-interactor app (make-instance 'xact:key-resize-interactor
                                                          :window win :widget app
                                                          :min-width 240 :min-height 320))
           (xact:widget-add-interactor app (make-instance 'xact:key-move-interactor
                                                          :window win :widget app))
           (when position-p
             (xd:set-placement-hints app))
           (xact:show app)
           (format t "~&Colour Picker controls:~%")
           (format t "  Drag on SV square / Hue strip / 3 sliders to pick colour~%")
           (format t "  r: switch to RGB mode (R, G, B sliders)~%")
           (format t "  h: switch to HSV mode (H, S, V sliders)~%")
           (format t "  Click 'Pick' button to sample colour from anywhere on screen~%")
           (format t "  Ctrl+r: resize with the arrows, Return / Escape~%")
           (format t "  Ctrl+m: move with the arrows, Return / Escape~%")
           (format t "  q / Escape: exit~%")
           (xact:run-widget app win
                            :stop-when (lambda () (xact:quit-requested-p quit))))
      (xact:unrealize app))
    t))
