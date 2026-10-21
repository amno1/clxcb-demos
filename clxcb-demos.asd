(cl:in-package #:asdf-user)

(defsystem "clxcb-demos"
  :description "Demo applications for CLXCB."
  :author "Arthur Miller <arthur.miller@live.com>"
  :license "GPLv3+"
  :version "0.5.0"
  :if-feature :sbcl
  :depends-on ("clxcb" "clxcb/all" "cffi" "with-user-abort"
               "closer-mop" "bordeaux-threads" "file-select"
               "clxcb-truetype" "clxrm/xcb"
               "xact" "xact/color-picker" "alexandria"
               "trivial-garbage")
  :serial t
  :components ((:module "lib"
                :serial t
                :components ((:file "packages")
                             (:file "framework")
                             (:file "virtual-root")
                             (:file "options")
                             (:file "application")
                             (:file "transform")
                             (:file "xbm")
                             (:file "xpm")
                             (:file "sprites")
                             (:file "server-info")
                             (:file "image-decoders")))
               (:module "demo-1"
                :components ((:file "quickstart")))
               (:module "demo-2"
                :components ((:file "basic-window")))
               (:module "demo-3"
                :components ((:file "turtle")))
               (:module "demo-4"
                :components ((:file "slideshow")))
               (:module "demo-5"
                :components ((:file "xeyes")))
               (:module "demo-6"
                :components ((:file "xclock")))
               (:module "demo-7"
                :components ((:file "xsnow")))
               (:module "demo-8"
                :components ((:file "xroach")))
               (:module "demo-9"
                :components ((:file "xneko")))
               (:module "demo-10"
                :components ((:file "color-picker")))
               (:module "demo-11"
                :components ((:file "xviewer")))
               (:module "demo-12"
                :components ((:file "thermometer")))))
