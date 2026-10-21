# Demo 1 — Quickstart

A one-shot, headless server introspection demo. It demonstrates how to connect to the X11 display server, queries all information about configuration and capabilities it can from it, and dumps info to the stdout. It also demonstrates atom interning and resource-ID generation, and how to cleanly close the connection.

## Loading in REPL

```lisp
;; Load the demos system
(asdf:load-system "clxcb-demos")

;; Run on a background thread and print report
(demo1:run)

;; Alternatively, start by keyword or number through the framework:
(xd:start :quickstart)
(xd:start 1)

;; Or run synchronously (blocking until finished):
(demo1:main)
```

Because this is a one-shot demo without an event loop, the worker thread automatically exits upon completion. Calling `(demo1:stop)` or `(xd:stop :quickstart)` is supported uniformly by the framework: if the worker thread is still executing, `stop` waits for it to complete and returns `t`; once the thread has exited, it returns `nil`.

## Running with Makefile

```bash
# Run Demo 1
make demo1

# Or using friendly aliases:
make quickstart
make demo
```

## Available Options

Demo 1 does not take any command-line or keyword options.

## Controls

Non-interactive: runs to completion, prints diagnostic output to standard output, and exits.
