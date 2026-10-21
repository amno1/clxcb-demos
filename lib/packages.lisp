;;; packages.lisp — namespaces used in CLXCB demos.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; Three shared helper packages — SERVER-INFO (server introspection),
;;; IMAGE-DECODERS (pluggable image backends), and XBM (X bitmap
;;; parsing) — then XCB-DEMOS itself, the framework every demo file
;;; uses.  The helper packages do not depend on the framework and would
;;; work equally well in any X11 program; only XCB-DEMOS is about demos
;;; specifically.
;;;
;;; See framework.lisp for the design of the framework.  Moving and
;;; resizing undecorated windows, and the screen colour picker, are
;;; xact's (WINDOW-DRAG-INTERACTOR, WINDOW-RESIZE-INTERACTOR,
;;; PICK-COLOR-FROM-SCREEN).
;;;
;;; Prerequisites in CLXCB:
;;;
;;;   * WM.LISP — SET-WM-NAME, SET-WM-CLASS, SET-NET-WM-PID,
;;;     SET-NET-WM-WINDOW-TYPE, SET-WM-DELETE-PROTOCOL, SET-MOTIF-WM-HINTS.
;;;
;;;   * A FUNCTION-form of the connection macro:
;;;
;;;         (xcb:call-with-x-connection (lambda (conn) ...)
;;;                                       :display "..." :timeout 0.1)
;;;
;;;     WITH-X-CONNECTION becomes a two-line expansion over it.  No
;;;     behaviour change for existing callers; the framework just needs
;;;     to call it as a function, which a macro cannot be.
;;;
;;; A brief overview: a DEMO is a CLOS object with a lifecycle (START,
;;; STOP) and a body (DEMO-BODY).  The transport -- how the demo gets a
;;; live connection -- is a mixin (XCB-MIXIN) with one method,
;;; CALL-WITH-CONTEXT.  What the demo shows is its application, an
;;; XD:APPLICATION: an xact TOPLEVEL whose kind says how it deals with
;;; the window manager.  See framework.lisp and application.lisp.
;;;
;;; Adding a new demo means writing a file whose first form is
;;;
;;;     (xd:define-demo :my-demo (:wm-title "My Demo" :app my-app)
;;;       ...body...)
;;;
;;; and whose remaining top-level forms define the application class and
;;; whatever functions the body needs.  DEMO-BODY receives the demo
;;; instance and the live connection; there is no `*conn*` global to
;;; remember, and no boilerplate close-protocol setup to forget.

(in-package #:cl-user)


;;; Shared helper packages
;;;
;;; These three are the demos' own small libraries: server introspection,
;;; pluggable image decoding, and XBM parsing.  None of them depends on
;;; the framework below, and none of them is about being a demo; they
;;; are just tools that several demo files happen to share.

(defpackage #:xcb-demos.server-info
  (:use #:cl)
  (:nicknames #:xdi)
  (:export #:connection-order-name
           #:bit-order-name
           #:image-order-name
           #:query-server
           #:query-wire-format
           #:query-keycode-range
           #:query-pixmap-formats
           #:query-visual
           #:query-depth
           #:query-screen
           #:query-screens
           #:query-extension
           #:query-extension-names
           #:query-extensions
           #:query-all))

(defpackage #:xcb-demos.image-decoders
  (:use #:cl)
  (:export #:register-decoder
           #:register-all
           #:supported-extensions
           #:decode-image))

(defpackage #:xcb-demos.xbm
  (:use #:cl)
  (:export #:read-xbm
           #:xbm-files
           #:xbm-bytes->wire
           #:make-xbm-loader-gc
           #:xbm->pixmap))

(defpackage #:xcb-demos.sprites
  (:use #:cl)
  (:export #:sprite
           #:sprite-p
           #:sprite-pixmap
           #:sprite-mask
           #:sprite-width
           #:sprite-height
           #:with-xbm-loader
           #:load-xbm-sprite
           #:free-sprite
           #:make-sprite-gc
           #:draw-sprite
           #:make-xbm-cursor))

(defpackage #:xcb-demos.xpm
  (:use #:cl)
  (:export #:read-xpm-strings
           #:parse-xpm))

(defpackage #:xcb-demos
  (:nicknames #:xd)
  (:use #:cl #:xact)
  (:export
   ;; Demo registry and lifecycle
   #:find-demo
   #:list-demos
   #:start
   #:stop
   #:define-demo

   ;; Per-run options (options.lisp)
   #:demo-options
   #:demo-option-specs
   #:demo-option-keys
   #:demo-option
   #:demo-option-default
   #:demo-option-plist
   #:demo-option-help
   #:demo-option-resource
   #:demo-resource-name
   #:demo-resource-class
   #:demo-resource-database
   #:set-demo-options
   #:start-with-options
   #:normalize-demo-options
   #:parse-demo-options
   #:main

   ;; Application objects (application.lisp)
   #:application
   #:make-application
   #:demo-app-class
   #:app-screen
   #:app-root
   #:app-depth
   #:app-visual
   #:app-x
   #:app-y
   #:app-geometry
   #:app-gravity
   #:resolve-placement
   #:realize-application
   #:set-placement-hints

   ;; Demo introspection
   #:demo-name
   #:demo-number
   #:demo-thread
   #:demo-display
   #:demo-running-p
   #:demo-application
   #:demo-wm-title
   #:demo-wm-class
   #:virtual-root

   ;; Demo body, defined by each demo file
   #:demo-body

   ;; The demo base class, referenced from DEFINE-DEMO's expansion
   #:xcb-demo

   ;; REPL helpers
   #:with-repl-interrupt-handler
   #:ignoring-errors

   ;; Transform (transform.lisp)
   #:scene-transform
   #:fit-transform
   #:stretch-transform
   #:transform-x
   #:transform-y
   #:transform-point
   #:transform-segment
   #:transform-segments))
