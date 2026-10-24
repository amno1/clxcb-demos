# Makefile for clxcb-demos.
#
#   make load              load the clxcb-demos system (sanity check)
#   make demo1 .. demo12   run the numbered demo
#   make demo3 ARGS="--file demo-3/drawing.lisp"
#                          pass options to demos 3..12 (ARGS="--help" lists them)
#   make demo              alias for demo1
#   make clean             remove compiled fasls
#
# The demos depend on libraries that are not in Quicklisp yet: clxcb,
# clxau, clxrm, runes and xact (see the README).  Any of
# them checked out next to this directory (../clxcb, ../xact, ...) is put on
# the ASDF source registry; the rest must already be there, e.g. cloned or
# symlinked into ~/quicklisp/local-projects/.  Set DEPS_DIRS to use other
# checkouts, or DEPS_DIRS= (empty) to use only the source registry.

LISP       := sbcl
LISPFLAGS  := --noinform --no-userinit --non-interactive

DEPS_DIRS ?= ../clxcb ../clxau ../clXau ../clxrm ../clXrm \
             ../runes ../xact
DEPS_FOUND := $(abspath $(wildcard $(DEPS_DIRS)))

LISP_BOOT := \
    --eval '(require :asdf)' \
    --eval '(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))' \
    $(if $(DEPS_FOUND),--eval '(asdf:initialize-source-registry (quote (:source-registry $(foreach d,$(DEPS_FOUND),(:directory "$(d)/")) :inherit-configuration)))') \
    --eval '(asdf:load-asd (merge-pathnames "clxcb-demos.asd" (uiop:getcwd)))'

LOAD := --eval '(asdf:load-system "clxcb-demos")'

.PHONY: all load demo \
        demo1 demo2 demo3 demo4 demo5 demo6 demo7 demo8 demo9 demo10 demo11 demo12 \
        quickstart basic-window turtle turtle-viewer color-picker slideshow \
        xeyes xclock xsnow xroach xneko xviewer image-viewer thermometer \
        clean help

all: load
demo: demo1

# --- sanity check ----------------------------------------------------------

load:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD)

# --- numbered targets ------------------------------------------------------

demo1:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 1)'
demo2:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 2)'
demo3:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 3)' --end-toplevel-options -- $(ARGS)
demo4:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 4)' --end-toplevel-options -- $(ARGS)
demo5:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 5)' --end-toplevel-options -- $(ARGS)
demo6:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 6)' --end-toplevel-options -- $(ARGS)
demo7:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 7)' --end-toplevel-options -- $(ARGS)
demo8:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 8)' --end-toplevel-options -- $(ARGS)
demo9:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 9)' --end-toplevel-options -- $(ARGS)
demo10:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 10)' --end-toplevel-options -- $(ARGS)
demo11:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 11)' --end-toplevel-options -- $(ARGS)
demo12:
	$(LISP) $(LISPFLAGS) $(LISP_BOOT) $(LOAD) --eval '(xd:main 12)' --end-toplevel-options -- $(ARGS)

# --- friendly aliases ------------------------------------------------------

quickstart:   demo1
basic-window: demo2
turtle:        demo3
turtle-viewer: demo3
slideshow:    demo4
xeyes:        demo5
xclock:       demo6
xsnow:        demo7
xroach:       demo8
xneko:        demo9
color-picker: demo10
xviewer:      demo11
image-viewer: demo11
thermometer:  demo12

# --- housekeeping ----------------------------------------------------------

clean:
	find . -name '*.fasl' -delete

help:
	@echo "clxcb-demos"
	@echo ""
	@echo "  1. quickstart     7. xsnow"
	@echo "  2. basic-window   8. xroach"
	@echo "  3. turtle         9. xneko"
	@echo "  4. slideshow     10. color-picker"
	@echo "  5. xeyes         11. xviewer"
	@echo "  6. xclock        12. thermometer"
	@echo ""
	@echo "Targets:"
	@echo "  make load                  load the clxcb-demos system"
	@echo "  make demo1 .. demo12       run the numbered demo"
	@echo "  make demo7 ARGS=\"--help\"   list a demo's options (demos 3..12)"
	@echo "  make xeyes / xclock / ...  friendly aliases"
	@echo "  make clean                 remove source-tree fasls"
	@echo ""
	@echo "Variables:"
	@echo "  DEPS_DIRS    checkouts of the dependencies to use, if present"
	@echo "  ARGS         options for the demo, e.g. ARGS=\"--width 300\""
