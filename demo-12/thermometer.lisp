;;; thermometer.lisp — a temperature unit converter: one slider, three scales.
;;; Copyright (C) 2026  Arthur Miller <arthur.miller@live.com>
;;; License: GPLv3+
;;;
;;; Three boxes, Kelvin, Celsius and Fahrenheit, over one slider that runs
;;; from absolute zero to the boiling point of water, deep blue to deep
;;; red, with 0 C in the middle.  Drag the slider, or click a box and type
;;; a temperature: the other boxes and the slider follow as you type.
;;;
;;; The temperature is three cells of the widget's state, :K :C and :F,
;;; tied by one relation (XACT:RELATE) with three methods, each computing
;;; the other two scales from one.  The slider writes :C, each box its own
;;; cell; the relation runs the method for the cell written, and never
;;; overwrites that cell, so nothing loops and there are no callbacks
;;; between the controls.  Values are exact rationals: 36.6 C is 183/5.
;;;
;;; The size of everything follows the text, in the same model:
;;;
;;;   :SCALE <-> :FONT-SIZE   a relation: Ctrl-+ and Ctrl-- write the
;;;                           scale, the --font-size option the size.
;;;   :FONT, :LINE-H, ...     one-way formulas over :FONT-SIZE: the font,
;;;                           its metrics, widths measured from the text,
;;;                           the track height and the margins.
;;;   :LAYOUT                 a formula building the window's layout
;;;                           (XACT:ROW, XACT:COLUMN, XACT:BOX).
;;;
;;; What is edited from several sides is a relation; what is only derived
;;; -- the boxes' text, the water's state -- stays a formula.
;;;
;;; Controls:
;;;   drag the slider   set the temperature
;;;   click a box       type a temperature in that scale; Return, Tab or
;;;                     a click elsewhere finishes, Escape takes it back
;;;   + / -             one degree Celsius warmer / colder
;;;   Ctrl-+ / Ctrl--   bigger / smaller;  Ctrl-0  normal size
;;;   Ctrl-drag         move the window
;;;   Alt- or Super-drag  scale it: right or up bigger, left or down
;;;                     smaller (Super where the WM takes Alt-drag)
;;;   q / Escape        exit

(xd:define-demo :thermometer
    (:wm-title "Temperature Unit Converter"
     :resource-class "Thermometer"
     :app thermometer
     :options (:x :y :geometry :celsius :font-size))
  (format t "~&========================================~%")
  (format t "   CLXCB Temperature Unit Converter    ~%")
  (format t "   (demo12)                            ~%")
  (format t "========================================~%")
  (run-thermometer d conn))

(defconstant +absolute-zero-c+ -27315/100
  "0 K in degrees Celsius.")
(defconstant +c-max+ 100
  "The slider's right end, in degrees Celsius.")

(defconstant +base-font-size+ 15
  "The font size at scale 1.")

(defparameter *units*
  '((:k "Kelvin"     "K")
    (:c "Celsius"    "°C")
    (:f "Fahrenheit" "°F"))
  "The scales: cell, name, and the unit shown in its box.")

(defclass thermometer (xd:application)
  ;; The state cells are the widget's (XACT:WIDGET-STATE); see SETUP-CELLS.
  ((celsius   :initarg :celsius :initform 20 :type real
              :documentation "Starting temperature in degrees Celsius.")
   (font-size :initarg :font-size :initform +base-font-size+ :type (integer 6 96)
              :documentation "Starting font size in pixels; everything scales with it.")
   (gc        :initform nil)
   (pixmap    :initform nil :documentation "The back buffer drawn into.")
   (pixmap-size :initform nil)
   (drawable  :initform nil :documentation "The xcb-truetype wrapper of PIXMAP.")
   (fonts     :initform (make-hash-table) :documentation "Fonts made, by size.")
   (before-edit :initform nil
                :documentation "The temperature in Celsius when a box was
                clicked, for Escape to put back.")))

(defun cell (w name) (xact:cref (xact:widget-state w) name))

(defun (setf cell) (value w name)
  (setf (xact:cref (xact:widget-state w) name) value
        (xact:widget-dirty-p w) t)
  value)

;;; Numbers

(defun parse-temperature (string)
  "The rational STRING writes as a decimal number (\"-36.6\", \"12,5\"),
   or NIL."
  (let* ((s (substitute #\. #\, (string-trim " " string)))
         (neg (and (plusp (length s)) (char= (char s 0) #\-)))
         (body (if (and (plusp (length s)) (find (char s 0) "+-")) (subseq s 1) s))
         (dot (position #\. body))
         (int (subseq body 0 dot))
         (frac (if dot (subseq body (1+ dot)) "")))
    (when (and (plusp (+ (length int) (length frac)))
               (every #'digit-char-p int)
               (every #'digit-char-p frac))
      (let ((v (+ (if (plusp (length int)) (parse-integer int) 0)
                  (if (plusp (length frac))
                      (/ (parse-integer frac) (expt 10 (length frac)))
                      0))))
        (if neg (- v) v)))))

(defun format-temperature (value)
  "VALUE to two decimals, without trailing zeros: 20, 293.15, 98.6."
  (let ((s (format nil "~,2F" (/ (round (* 100 value)) 100.0d0))))
    (string-right-trim "." (string-right-trim "0" s))))

(defun valid-kelvin-p (unit value)
  "True if VALUE in UNIT is not below absolute zero."
  (>= (ecase unit
        (:k value)
        (:c (- value +absolute-zero-c+))
        (:f (- (* 5/9 (- value 32)) +absolute-zero-c+)))
      0))

;;; Cells

(defun font-of-size (w size)
  (or (gethash size (slot-value w 'fonts))
      (setf (gethash size (slot-value w 'fonts))
            (progn
              (unless (xcb-truetype:get-font-families)
                (xcb-truetype:cache-fonts))
              (let* ((families (xcb-truetype:get-font-families))
                     (fam (or (find-if (lambda (f) (member f families :test #'string-equal))
                                       '("DejaVu Sans" "Noto Sans" "Liberation Sans" "FreeSans"))
                              (first families))))
                (make-instance 'xcb-truetype:font :family fam :subfamily nil :size size))))))

(defun setup-cells (w)
  (let ((st (xact:widget-state w))
        (screen (xd:app-screen w)))
    (flet ((formula (name fn) (xact:install-formula st name fn))
           (text-w (string) (xcb-truetype:text-width screen (xact:cref st :font) string)))
      ;; The temperature: three editable scales, one relation.
      (let ((c (slot-value w 'celsius)))
        (setf (xact:cref st :c) c
              (xact:cref st :k) (- c +absolute-zero-c+)
              (xact:cref st :f) (+ 32 (* 9/5 c))))
      (xact:relate st
                   '(:c) '(:k :f) (lambda (c) (values (- c +absolute-zero-c+) (+ 32 (* 9/5 c))))
                   '(:k) '(:c :f) (lambda (k)
                                    (let ((c (+ k +absolute-zero-c+)))
                                      (values c (+ 32 (* 9/5 c)))))
                   '(:f) '(:c :k) (lambda (f)
                                    (let ((c (* 5/9 (- f 32))))
                                      (values c (- c +absolute-zero-c+)))))
      ;; Editing a box: which one, and what has been typed.
      (setf (xact:cref st :editing) nil
            (xact:cref st :buffer) "")
      (dolist (u *units*)
        (let ((unit (first u)))
          (formula (intern (format nil "~A-TEXT" unit) :keyword)
                   (lambda ()
                     (if (eq (xact:cref st :editing) unit)
                         (xact:cref st :buffer)
                         (format-temperature (xact:cref st unit)))))))
      (formula :buffer-valid
               (lambda ()
                 (let ((v (parse-temperature (xact:cref st :buffer)))
                       (unit (xact:cref st :editing)))
                   (and v unit (valid-kelvin-p unit v)))))
      (formula :water (lambda ()
                        (let ((c (xact:cref st :c)))
                          (cond ((<= c 0) "frozen") ((< c 100) "liquid") (t "boiling")))))
      ;; The size: scale and font size, both editable.
      (setf (xact:cref st :font-size) (slot-value w 'font-size)
            (xact:cref st :scale) (/ (slot-value w 'font-size) +base-font-size+))
      (xact:relate st
                   '(:scale) '(:font-size) (lambda (s) (max 6 (round (* s +base-font-size+))))
                   '(:font-size) '(:scale) (lambda (fs) (/ fs +base-font-size+)))
      ;; Everything else follows the font size, one way.
      (formula :font    (lambda () (font-of-size w (xact:cref st :font-size))))
      (formula :ascent  (lambda () (xcb-truetype:font-ascent screen (xact:cref st :font))))
      ;; FONT-DESCENT is negative: the distance below the baseline.
      (formula :line-h  (lambda () (+ (xact:cref st :ascent)
                                      (abs (xcb-truetype:font-descent screen (xact:cref st :font))))))
      (formula :gap     (lambda () (round (xact:cref st :font-size) 2)))
      (formula :margin  (lambda () (round (* 4/3 (xact:cref st :font-size)))))
      (formula :track-h (lambda () (round (* 8/5 (xact:cref st :font-size)))))
      (formula :field-w (lambda () (+ (text-w "-459.67 °F") (* 2 (xact:cref st :gap)))))
      (formula :title-w (lambda () (text-w "Temperature")))
      ;; The help line at its widest wording, so the layout does not
      ;; change -- and the slider move under the pointer -- when the
      ;; water freezes or boils.
      (formula :help-w  (lambda ()
                          (reduce #'max '("frozen" "liquid" "boiling")
                                  :key (lambda (state) (text-w (help-text w state))))))
      (formula :layout  (lambda () (build-layout st))))))

(defun help-text (w &optional (state (cell w :water)))
  (format nil "Water is ~A.   Click a box to type.   Ctrl-+/- size   q quit" state))

(defun build-layout (st)
  "The window's layout, from the size cells of ST: the three boxes, each
   under its name, then the slider, its ticks, the word Temperature, and
   a line of help."
  (let ((line  (xact:cref st :line-h))
        (gap   (xact:cref st :gap))
        (fs    (xact:cref st :font-size)))
    (flet ((unit-column (unit)
             (xact:column (:spacing (round gap 3) :stretch-x 1)
               (xact:box :name (intern (format nil "~A-NAME" unit) :keyword)
                         :min-width (xact:cref st :field-w) :min-height line)
               (xact:box :name (intern (format nil "~A-FIELD" unit) :keyword)
                         :min-width (xact:cref st :field-w)
                         :min-height (+ line gap) :stretch-x 1))))
      (xact:column (:margin (xact:cref st :margin) :spacing gap)
        (xact:row (:spacing (* 2 gap))
          (unit-column :k) (unit-column :c) (unit-column :f))
        (xact:box :name :spacer :min-height (round gap 2))
        (xact:box :name :track :min-width (* 24 fs) :min-height (xact:cref st :track-h)
                  :stretch-x 1)
        (xact:box :name :ticks :min-height line)
        (xact:box :name :title :min-width (xact:cref st :title-w) :min-height line
                  :align :center)
        (xact:box :name :help :min-width (xact:cref st :help-w) :min-height line)))))

(defun part (w name)
  (xact:layout-find (xact:widget-layout w) name))

(defun field (unit) (intern (format nil "~A-FIELD" unit) :keyword))

;;; The slider: 0 K at the left end, 0 C in the middle, 100 C at the right.

(defun c->fraction (c)
  "Where C (Celsius) lies along the slider, from 0 to 1."
  (if (< c 0)
      (* 1/2 (/ (- (max c +absolute-zero-c+) +absolute-zero-c+) (- +absolute-zero-c+)))
      (+ 1/2 (* 1/2 (/ (min c +c-max+) +c-max+)))))

(defun fraction->c (f)
  (if (< f 1/2)
      (+ +absolute-zero-c+ (* 2 f (- +absolute-zero-c+)))
      (* 2 (- f 1/2) +c-max+)))

;;; Positions span the track's first to last pixel, so that on a track of
;;; odd width the middle pixel is exactly 0 C.

(defun track-x (w fraction)
  (let ((tr (part w :track)))
    (round (+ (xact:node-x tr) (* fraction (1- (xact:node-width tr)))))))

(defun x->c (w x)
  (let* ((tr (part w :track))
         (last (+ (xact:node-x tr) (1- (xact:node-width tr))))
         (f (/ (- (max (xact:node-x tr) (min last x)) (xact:node-x tr))
               (max 1 (1- (xact:node-width tr))))))
    ;; Whole tenths of a degree, but never below absolute zero, which
    ;; the left end is exactly.
    (if (zerop f)
        +absolute-zero-c+
        (max +absolute-zero-c+ (/ (round (* 10 (fraction->c f))) 10)))))

(defun inside-p (box ev &optional (pad 0))
  (and box
       (<= (- (xact:node-x box) pad) (xact:event-x ev) (+ (xact:node-x box) (xact:node-width box) pad))
       (<= (- (xact:node-y box) pad) (xact:event-y ev) (+ (xact:node-y box) (xact:node-height box) pad))))

(defun slider-interactor (w win)
  (make-instance 'xact:drag-interactor
                 :window win
                 ;; A drag starts on the track, then follows the pointer
                 ;; anywhere, clamped to the ends, as a slider should.
                 :hit-test (lambda (i ev)
                             (or (not (eq (xact:interactor-state i) :idle))
                                 (inside-p (part w :track) ev (round (cell w :gap) 2))))
                 :on-drag (lambda (i ev)
                            (declare (ignore i))
                            (finish-editing w)
                            (setf (cell w :c) (x->c w (xact:event-x ev))))))

;;; Typing in a box

(defun start-editing (w unit)
  (unless (eq (cell w :editing) unit)
    (finish-editing w)
    (setf (slot-value w 'before-edit) (cell w :c)
          (cell w :buffer) (format-temperature (cell w unit))
          (cell w :editing) unit)))

(defun finish-editing (w)
  (when (cell w :editing)
    (setf (cell w :editing) nil
          (cell w :buffer) "")))

(defun cancel-editing (w)
  (when (cell w :editing)
    (setf (cell w :c) (slot-value w 'before-edit))
    (finish-editing w)))

(defun edit (w new-buffer)
  "Make NEW-BUFFER what has been typed; when it is a temperature, write
   it, and the relation updates the other scales."
  (setf (cell w :buffer) new-buffer)
  (when (cell w :buffer-valid)
    (setf (cell w (cell w :editing)) (parse-temperature new-buffer))))

(defclass field-input (xact:interactor)
  ((app :initarg :app :reader input-app))
  (:documentation "Clicks on the boxes, and the keys typed into one."))

(defmethod xact:handle-event ((i field-input) (ev xact:button-press))
  (let* ((w (input-app i))
         (unit (find-if (lambda (u) (inside-p (part w (field u)) ev)) '(:k :c :f))))
    (cond (unit (start-editing w unit) t)
          ;; A click elsewhere finishes; the slider may still take it.
          (t (finish-editing w) nil))))

(defmethod xact:handle-event ((i field-input) (ev xact:key-press))
  (let* ((w (input-app i))
         (unit (cell w :editing))
         (ks (xact:event-keysym ev))
         (buffer (cell w :buffer)))
    (cond
      ((null unit) nil)                  ; not editing: the keymap's keys
      ((logtest #x4 (xact:event-modifiers ev)) nil) ; Ctrl-: the keymap's too
      ((member ks '(:return)) (finish-editing w) t)
      ((eq ks :tab)
       (let ((units '(:k :c :f)))
         (start-editing w (or (second (member unit units)) (first units))))
       t)
      ((eq ks :escape) (cancel-editing w) t)
      ((eq ks :backspace)
       (when (plusp (length buffer)) (edit w (subseq buffer 0 (1- (length buffer)))))
       t)
      ((and (characterp ks) (find ks "0123456789.,-+"))
       (edit w (concatenate 'string buffer (string ks)))
       t)
      ;; Any other key is swallowed while typing, so q does not quit.
      (t t))))

;;; Scaling with the mouse: XACT:SCALE-DRAG-INTERACTOR, on Alt- or
;;; Super-drag.  It writes :SCALE, like Ctrl-+ and Ctrl--, and the rest
;;; follows; the window takes its new natural size whenever the text
;;; changes size.

(defun set-scale (w scale)
  (let ((size (cell w :font-size)))
    (setf (cell w :scale) scale)
    (unless (eql size (cell w :font-size))
      (fit-window w))))

;;; Drawing: into a back buffer, copied to the window in one go.

(defun pixel (w r g b)
  (xcb:rgb->pixel (xcb:find-root-visual (xd:app-screen w)) r g b))

(defun ensure-back-buffer (w)
  (let ((size (list (xact:widget-width w) (xact:widget-height w)))
        (conn (xact:widget-connection w)))
    (unless (equal size (slot-value w 'pixmap-size))
      (free-back-buffer w)
      (let ((pm (xcb:generate-id conn)))
        (xcb::create-pixmap conn (xd:app-depth w) pm (xact:widget-window w)
                            (first size) (second size))
        (setf (slot-value w 'pixmap) pm
              (slot-value w 'pixmap-size) size
              (slot-value w 'drawable)
              (make-instance 'xcb-truetype:pixmap :owned t :connection conn :id pm
                                                  :visual (xcb:find-root-visual (xd:app-screen w))
                                                  :screen (xd:app-screen w)))
        (trivial-garbage:cancel-finalization (slot-value w 'drawable))))))

(defun free-back-buffer (w)
  (let ((conn (xact:widget-connection w)))
    ;; DESTROY-DRAWABLE frees the wrapper's RENDER picture and the
    ;; pixmap itself.
    (if (slot-value w 'drawable)
        (ignore-errors (xcb-truetype:destroy-drawable (slot-value w 'drawable)))
        (when (slot-value w 'pixmap)
          (ignore-errors (xcb::free-pixmap conn (slot-value w 'pixmap)))))
    (setf (slot-value w 'drawable) nil (slot-value w 'pixmap) nil
          (slot-value w 'pixmap-size) nil)))

(defun fill-rect (w x y width height pixel)
  (let ((conn (xact:widget-connection w))
        (gc (slot-value w 'gc)))
    (xcb::change-gc conn gc +gc-foreground+ :foreground pixel)
    (xcb::poly-fill-rectangle conn (slot-value w 'pixmap) gc
                              (list (make-instance 'xcb::rectangle :x x :y y
                                                                   :width (max 1 width)
                                                                   :height (max 1 height))))))

(defun outline-rect (w x y width height pixel)
  (fill-rect w x y width 1 pixel)
  (fill-rect w x (+ y height -1) width 1 pixel)
  (fill-rect w x y 1 height pixel)
  (fill-rect w (+ x width -1) y 1 height pixel))

(defun text-width (w string)
  (xcb-truetype:text-width (xd:app-screen w) (cell w :font) string))

(defun draw-text-at (w x box string colour)
  "STRING at X, centred vertically in BOX."
  (xcb-truetype:draw-text (slot-value w 'drawable) (cell w :font) string
                          x
                          (+ (xact:node-y box)
                             (floor (- (xact:node-height box) (cell w :line-h)) 2)
                             (cell w :ascent))
                          :colour colour))

(defun gradient-pixel (w fraction)
  "Deep blue at 0, deep red at 1."
  (pixel w (round (* 170 fraction)) 0 (round (* 170 (- 1 fraction)))))

(defun draw-field (w unit name label)
  (let* ((box (part w (field unit)))
         (x (xact:node-x box)) (y (xact:node-y box))
         (bw (xact:node-width box)) (bh (xact:node-height box))
         (pad (cell w :gap))
         (editing (eq (cell w :editing) unit))
         (text (cell w (intern (format nil "~A-TEXT" unit) :keyword)))
         (colour (if (and editing (not (cell w :buffer-valid))) #xC00000 #x202020)))
    (draw-text-at w (xact:node-x (part w (intern (format nil "~A-NAME" unit) :keyword)))
                  (part w (intern (format nil "~A-NAME" unit) :keyword)) name #x505050)
    (fill-rect w x y bw bh (if editing (pixel w 255 255 240) (pixel w 248 248 250)))
    (outline-rect w x y bw bh (if editing (pixel w 60 110 220) (pixel w 190 190 196)))
    (draw-text-at w (+ x pad) box text colour)
    (draw-text-at w (- (+ x bw) pad (text-width w label)) box label #x808080)
    (when editing
      ;; The caret, after the text.
      (fill-rect w (+ x pad (text-width w text) 1) (+ y (floor pad 2))
                 (max 1 (round (cell w :font-size) 10)) (- bh pad) (pixel w 20 20 20)))))

(defun draw-slider (w)
  (let* ((tr (part w :track))
         (x0 (xact:node-x tr)) (y (xact:node-y tr))
         (tw (xact:node-width tr)) (th (xact:node-height tr))
         (strip (max 2 (round tw 120))))
    ;; The gradient, in narrow strips.
    (loop for x from 0 below tw by strip
          do (fill-rect w (+ x0 x) y (min strip (- tw x)) th
                        (gradient-pixel w (/ (+ x (/ strip 2)) tw))))
    ;; Ticks under it: 0 K, 0 C, 100 C.
    (let ((ticks (part w :ticks)))
      (loop for (fraction text) in '((0 "0 K") (1/2 "0 °C") (1 "100 °C"))
            for tx = (track-x w fraction)
            for text-w = (text-width w text)
            do (fill-rect w (min tx (+ x0 tw -1)) (+ y th) 1 (round (cell w :gap) 2)
                          (pixel w 100 100 100))
               (draw-text-at w (max x0 (min (- (+ x0 tw) text-w) (- tx (floor text-w 2))))
                             ticks text #x606060)))
    ;; The knob: a dark bar with a white rim, over the track.
    (let* ((kx (track-x w (c->fraction (cell w :c))))
           (kw (max 6 (round (cell w :font-size) 2)))
           (over (round th 4)))
      (fill-rect w (- kx (floor kw 2) 1) (- y over 1) (+ kw 2) (+ th (* 2 over) 2) (pixel w 255 255 255))
      (fill-rect w (- kx (floor kw 2)) (- y over) kw (+ th (* 2 over)) (pixel w 30 30 30)))))

(defmethod xact:draw ((w thermometer) surface)
  (declare (ignore surface))
  (setf (xact:widget-layout w) (cell w :layout))
  (xact:relayout w)
  (ensure-back-buffer w)
  (let ((width (xact:widget-width w))
        (height (xact:widget-height w)))
    (fill-rect w 0 0 width height (pixel w 255 255 255))
    (loop for (unit name label) in *units*
          do (draw-field w unit name label))
    (draw-slider w)
    (let ((title (part w :title)))
      (draw-text-at w (xact:node-x title) title "Temperature" #x202020))
    (let ((help (part w :help)))
      (draw-text-at w (xact:node-x help) help (help-text w) #x808080))
    (xcb::copy-area (xact:widget-connection w) (slot-value w 'pixmap) (xact:widget-window w)
                    (slot-value w 'gc) 0 0 0 0 width height)))

;;; Keys: commands in a keymap.

(defun fit-window (w)
  "Give W's window its layout's natural size."
  (let ((layout (cell w :layout)))
    (xact:layout-measure layout)
    (xcb::configure-window (xact:widget-connection w) (xact:widget-window w)
                           (logior +config-window-width+ +config-window-height+)
                           :width (xact:node-min-width layout)
                           :height (xact:node-min-height layout))))

(defun rescale (w factor)
  (let ((new (if factor (* factor (cell w :scale)) 1)))
    (when (<= 1/2 new 4)
      (setf (cell w :scale) new)
      (format t "~&Scale ~,2F, font size ~D~%" (float (cell w :scale)) (cell w :font-size))
      (fit-window w))))

(xact:defcommand warmer ()
  "One degree Celsius warmer."
  (interactive)
  (incf (cell xact:*widget* :c)))

(xact:defcommand colder ()
  "One degree Celsius colder, not below absolute zero."
  (interactive)
  (setf (cell xact:*widget* :c) (max +absolute-zero-c+ (1- (cell xact:*widget* :c)))))

(xact:defcommand bigger ()
  "Scale text and slider up."
  (interactive)
  (rescale xact:*widget* 6/5))

(xact:defcommand smaller ()
  "Scale text and slider down."
  (interactive)
  (rescale xact:*widget* 5/6))

(xact:defcommand normal-size ()
  "Back to scale 1."
  (interactive)
  (rescale xact:*widget* nil))

(defvar *thermometer-keymap*
  (let ((map (xact:make-keymap)))
    (xact:define-key map #\+ 'warmer)
    (xact:define-key map #\= 'warmer)          ; + without Shift on most layouts
    (xact:define-key map #\- 'colder)
    (xact:define-key map (xact:kbd "C-+") 'bigger)
    (xact:define-key map (xact:kbd "C-=") 'bigger)
    (xact:define-key map (xact:kbd "C--") 'smaller)
    (xact:define-key map (xact:kbd "C-0") 'normal-size)
    map))

;;; Setting up and running

(defun run-thermometer (d conn)
  (let* ((w (xd:make-application d conn :keymaps (list *thermometer-keymap*)))
         (screen (xd:app-screen w)))
    (setup-cells w)
    ;; The window starts at the layout's natural size; a geometry string
    ;; can still ask for another.
    (let ((layout (cell w :layout)))
      (xact:layout-measure layout)
      (setf (xact:widget-width w) (xact:node-min-width layout)
            (xact:widget-height w) (xact:node-min-height layout)
            (xact:widget-layout w) layout))
    (xd:resolve-placement w)
    (xact:relayout w)
    (unwind-protect
         (let* ((win (xd:realize-application
                      w :x 100 :y 100
                        :background-pixel (xcb:white-pixel screen)
                        :event-mask (logior +event-mask-exposure+
                                            +event-mask-key-press+
                                            +event-mask-button-press+
                                            +event-mask-button-release+
                                            +event-mask-button1-motion+
                                            +event-mask-structure-notify+)))
                (quit (make-instance 'xact:quit-interactor :window win)))
           (xd:set-placement-hints w)
           (setf (slot-value w 'gc) (xcb:generate-id conn))
           (xcb::create-gc conn (slot-value w 'gc) win +gc-foreground+ :foreground 0)
           ;; Newest first: the boxes see keys before QUIT, so typing q
           ;; or Escape in a box does not quit.
           (dolist (i (list (make-instance 'xact:resize-interactor :window win :widget w)
                            (slider-interactor w win)
                            quit
                            (make-instance 'field-input :window win :app w)
                            ;; Last, so they see a Ctrl- or Alt-press before
                            ;; the slider and the boxes do.
                            (make-instance 'xact:window-drag-interactor
                                           :window win :widget w
                                           :start-event '(:and :leftdown :control))
                            (make-instance 'xact:scale-drag-interactor
                                           :window win
                                           :get (lambda () (cell w :scale))
                                           :set (lambda (scale) (set-scale w scale)))))
             (xact:widget-add-interactor w i))
           (xact:show w)
           (format t "~&Controls:~%  drag the slider   set the temperature~%")
           (format t "  click a box       type a temperature; Return/Tab finish, Escape undo~%")
           (format t "  + / -             one degree Celsius warmer / colder~%")
           (format t "  Ctrl-+ / Ctrl--   bigger / smaller    Ctrl-0  normal size~%")
           (format t "  Ctrl-drag         move the window~%")
           (format t "  Alt-/Super-drag   scale it: right/up bigger, left/down smaller~%")
           (format t "  q / Escape        exit~%")
           (xact:run-widget w win :stop-when (lambda () (xact:quit-requested-p quit))))
      (free-back-buffer w)
      (when (slot-value w 'gc)
        (ignore-errors (xcb::free-gc conn (slot-value w 'gc))))
      (xact:unrealize w)))
  t)

;;; thermometer.lisp ends here
