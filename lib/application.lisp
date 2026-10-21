;;; application.lisp — the base class of every demo's application.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; A demo's application object is an xact TOPLEVEL, a widget whose KIND
;;; says how its window deals with the window manager (:MANAGED,
;;; :UNDECORATED, :OVERRIDE-REDIRECT, or :ROOT for drawing on the root);
;;; a demo class sets it with :DEFAULT-INITARGS.  MAKE-APPLICATION gives
;;; it its title and WM class.  The widget is the one place its
;;; connection and window are kept: WIDGET-CONNECTION and
;;; WIDGET-WINDOW.  Everything else about the screen is asked of the
;;; connection when it is needed -- APP-SCREEN, APP-ROOT, APP-DEPTH,
;;; APP-VISUAL -- rather than copied into slots of the demo, the widget
;;; and the application, where the copies could disagree.  A value the
;;; application chooses for itself, such as an ARGB visual, is its own.
;;;
;;; APPLICATION also has the placement options the windowed demos share
;;; (WIDTH, HEIGHT, X, Y, GEOMETRY), declared as slots so DEFINE-DEMO's
;;; :OPTIONS can name them.  A demo gives them defaults of its own with
;;; :DEFAULT-INITARGS, and RESOLVE-PLACEMENT applies the geometry string.

(in-package #:xcb-demos)

(defclass application (xact:toplevel)
  ((xact::width  :type (integer 1)
                 :documentation "Window width in pixels.")
   (xact::height :type (integer 1)
                 :documentation "Window height in pixels.")
   (x            :initarg :x :initform nil :type (or null integer)
                 :accessor app-x
                 :documentation "Window x position; NIL for the default placement.")
   (y            :initarg :y :initform nil :type (or null integer)
                 :accessor app-y
                 :documentation "Window y position; NIL for the default placement.")
   (geometry     :initarg :geometry :initform nil :type (or null string)
                 :reader app-geometry
                 :documentation "X11 geometry string, such as 400x400-10+10.")
   (gravity      :initform :north-west :accessor app-gravity
                 :documentation "The window gravity RESOLVE-PLACEMENT found."))
  (:default-initargs :width 1 :height 1))

(defun app-screen (app)
  "The screen APP runs on."
  (first (xcb:conn-roots (xact:widget-connection app))))

(defun app-root (app)
  "The root window of APP's screen."
  (xcb:root (app-screen app)))

(defun app-depth (app)
  "The depth of APP's screen's root window."
  (xcb:root-depth (app-screen app)))

(defun app-visual (app)
  "The visual id of APP's screen's root window."
  (xcb:root-visual (app-screen app)))

(defun resolve-placement (app &key (min-size 1))
  "Apply APP's GEOMETRY, if any, over its WIDTH, HEIGHT, X and Y,
   against the screen size; sizes are kept at MIN-SIZE or more.  Sets
   them and APP-GRAVITY, and returns true when a position was asked for."
  (let ((geometry (app-geometry app)))
    (when geometry
      (let* ((screen (app-screen app))
             (spec   (xcb:parse-geometry geometry)))
        (when (getf spec :width)
          (setf (xact:widget-width app) (max min-size (getf spec :width))))
        (when (getf spec :height)
          (setf (xact:widget-height app) (max min-size (getf spec :height))))
        (multiple-value-bind (gx gy grav)
            (xcb:geometry-position spec
                                   (xcb:width-in-pixels screen)
                                   (xcb:height-in-pixels screen)
                                   (xact:widget-width app)
                                   (xact:widget-height app))
          (when gx (setf (app-x app) (max 0 gx)))
          (when gy (setf (app-y app) (max 0 gy)))
          (setf (app-gravity app) grav))))
    (and (or (app-x app) (app-y app)) t)))

(defun realize-application (app &rest args &key x y &allow-other-keys)
  "XACT:REALIZE APP at its requested position, or at X, Y (default 0, 0)
   when it has none; ARGS are passed on.  Returns the window."
  (apply #'xact:realize app
         :x (or (app-x app) x 0) :y (or (app-y app) y 0)
         args))

(defun set-placement-hints (app)
  "Tell the WM about APP's requested position, if it has one, through
   WM_NORMAL_HINTS on its window."
  (when (or (app-x app) (app-y app))
    (xcb:set-wm-normal-hints (xact:widget-connection app) (xact:widget-window app)
                             :x (or (app-x app) 0) :y (or (app-y app) 0)
                             :width (xact:widget-width app)
                             :height (xact:widget-height app)
                             :gravity (app-gravity app))))

;;; application.lisp ends here
