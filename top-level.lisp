;;; cl-typesetting copyright 2003-2004 Marc Battyani see license.txt for the details
;;; You can reach me at marc.battyani@fractalconcept.com or marc@battyani.net
;;; The homepage of cl-typesetting is here: http://www.fractalconcept.com/asp/html/cl-typesetting.html

;;; Toplevel document and page layout, auto splitting
;;; Thanks to Dmitri Ivanov for this!

(in-package typeset)

(defconstant +paper-sizes+	; In portrait orientation: (width . height) 
  '((:A3 . (841 . 1190))	; (841.89 . 1190.55)
    (:A4 . (595 . 841))		; (595.28 . 841.89)
    (:A5 . (420 . 595))		; (420.94 . 595.28)
    (:Letter . (612 . 792))
    (:Legal . (612 . 1008))))

(defvar *default-page-size* :A4)
(defvar *default-page-orientation* :portrait)		; :portrait or :landscape
(defvar *default-page-header-footer-margin* 30)

(defun compute-page-bounds (&optional (size *default-page-size*)
                                      (orientation *default-page-orientation*))
 ;;; Compute media box size
  ;; Args: size  Size identifier or (width . height)
  (let* ((pair (unless (consp size) (cdr (assoc size +paper-sizes+))))
         (width (cond ((consp size) (car size))
                      ((eq orientation :landscape) (or (cdr pair) 841))
                      ((or (car pair) 595))))
         (height (cond ((consp size) (cdr size))
                       ((eq orientation :landscape) (or (car pair) 595))
                       ((or (cdr pair) 841)))))
    (vector 0 0 width height)))

(defclass document (pdf::document)
 ((page-class :reader page-class :initform 'page)
  ;(page-number :initarg page-number :accessor page-number)
))

(defmethod pages ((doc document))
  (declare (ignore doc))
  (and pdf::*root-page* (pdf::pages pdf::*root-page*)))

(defclass page (pdf::page)
 ((margins :accessor margins :initarg :margins :initform nil)	; :type quad
  (header :accessor header :initarg :header :initform nil)
  (footer :accessor footer :initarg :footer :initform nil)
  (header-top :initarg :header-top :initform nil)
  (footer-bottom :initarg :footer-bottom :initform nil)
  (finalize-fn :initarg :finalize-fn :initform nil)		; signature: page
  ;; dy left unallocated on this page
  (room-left :accessor room-left :initarg :room-left :initform 0)
))

(defun draw-pages (content &rest args
                   &key (size *default-page-size*)
                        (orientation *default-page-orientation*)
                        bounds margins
                        (header-top *default-page-header-footer-margin*)
                        (footer-bottom *default-page-header-footer-margin*)
                        break
                        &allow-other-keys)
 ;;; Args:
  ;;	content		Text content, multi-page-table, or other content.
  ;;	bounds  	Media box; overwrites size and orientation when specified.
  ;;	margins		Quad of distances between media edges and page body area.
  ;;			(independent from header and footer sizes for now).
  ;;	header, footer	Content or function of ftype (function (page) content)
  ;;	header-top	Distance between the top media edge and the header.
  ;;	footer-bottom	Distance between the bottom media edge and the footer.
  ;;	break   	Force new page ::= :before | :after | :always (both ends)
  (with-quad (left-margin top-margin right-margin bottom-margin) margins
   (let* ((bounds (or bounds (compute-page-bounds size orientation)))
          (height (aref bounds 3)))
    (flet ((add-page ()
             (setq pdf:*page* (apply #'make-instance (page-class pdf:*document*)
                                     :bounds bounds
                                     :header-top header-top
                                     :footer-bottom footer-bottom
                                     ;; Move room-left into initialize-instance :after?
                                     :room-left (- height top-margin bottom-margin)
                                     (sys::remove-properties args
                                       '(:size :orientation :bounds
                                         :header-top :footer-bottom :break))))))
      (when (and pdf:*page* (member break '(:before :always)))
        (finalize-page pdf:*page*)
        (setq pdf:*page* nil))
      (loop with width = (aref bounds 2)
            with dx = (- width left-margin right-margin)
            and x = left-margin
            with dy and y
            while (boxes-left content)
            unless pdf:*page* 
              do (add-page)
            do (setq dy (room-left pdf:*page*)
                     y  (+ dy bottom-margin))
            when (<= dy +epsilon+)
              do (finalize-page pdf:*page*)
                 (add-page)
                 (setq dy (room-left pdf:*page*)
                       y  (+ dy bottom-margin))
            do
            (handler-bind
                ((end-of-page
                  #'(lambda (c &aux restart)
                      (cond ((setq restart (find-restart 'continue-with-next-page c))
                             (finalize-page pdf:*page*)
                             (add-page)
                             (setq dy (room-left pdf:*page*)
                                   y  (+ dy bottom-margin))
                             (invoke-restart restart))
                            ((loop-finish))))))
              (multiple-value-bind (boxes boxes-left dy-left) (v-split content dx dy :top)
                (cond (boxes
                       (let ((vbox (make-instance 'vbox  :boxes boxes  :dx dx  :dy dy 
                                                  :fixed-size t)))
                         (do-layout vbox)
                         (setf (boxes-left content) boxes-left
                               (room-left pdf:*page*) dy-left)
                         (stroke vbox x y)))
                      ;; As no new lines can fit, check whether the page was just started
                      ((> (abs (- dy (- height top-margin bottom-margin))) +epsilon+)
                       (finalize-page pdf:*page*)
                       (setq pdf:*page* nil))
                      ;; Cannot fit even on a comletely fresh page
                      (t (error 'cannot-fit-on-page :box (first (boxes-left content))))
      )    ) ) )
      (when (and pdf:*page* (member break '(:after :always)))
        (finalize-page pdf:*page*)
        (setq pdf:*page* nil))
) )))

(defun finalize-page (pdf:*page* &optional (get-content t))
 ;;; Draw header and footer without advancing their content,
  ;; then obtain the entire page content stream.
  (with-slots (margins header header-top footer footer-bottom finalize-fn) pdf:*page*
    (with-quad (left-margin top-margin right-margin bottom-margin) margins
      (let* ((width (aref (pdf::bounds pdf:*page*) 2))
             (height (aref (pdf::bounds pdf:*page*) 3))
             (dx (- width left-margin right-margin)))
             ;(x left-margin)
             ;(y (- height top-margin))
             ;(dy (- height top-margin bottom-margin)))     
         (when header
           (let ((content (if (functionp header) (funcall header pdf:*page*) header)))
             (pdf:with-saved-state
               (stroke (typecase content
                         (box content)
                         (t (make-filled-vbox content dx (- top-margin header-top)
                                              :top nil)))
                       left-margin (- height header-top)))))
         (when footer
           (let ((content (if (functionp footer) (funcall footer pdf:*page*) footer)))
             (pdf:with-saved-state
               (stroke (typecase content
                         (box content)
                         (t (make-filled-vbox content dx (- bottom-margin footer-bottom)
                                              :bottom nil)))
                       left-margin bottom-margin))))))
    (when finalize-fn
      (funcall finalize-fn pdf:*page*))
    (when get-content
      (setf (pdf::content (pdf::content-stream pdf:*page*))
             (get-output-stream-string pdf::*page-stream*))))
  pdf:*page*)

(defmethod draw-block (content x y dx dy 
                       &key border (padding 5) rotation (v-align :top) special-fn)
 ;;; On the current *page*
  (pdf:with-saved-state
    (pdf:translate x y)
    (when rotation
      (pdf:rotate rotation))
    (when border
      (with-quad (left top right bottom) padding
        (pdf:set-line-width border)
        (pdf:set-gray-stroke 0)
        (pdf:set-gray-fill 1)
        (pdf:basic-rect (- left) top (+ dx left right) (- (+ dy top bottom)))
        (pdf:fill-and-stroke)
        (pdf:set-gray-fill 0)
    ) )
    (let ((vbox (make-filled-vbox content dx dy v-align)))
      ;(push vbox *boxes*)
      (when special-fn
        (funcall special-fn vbox 0 0))
      (stroke vbox 0 0))))

(defmacro with-document ((&rest args) &body body)
  `(let* ((pdf:*document* (make-instance 'document ,@args))
	  (pdf::*outlines-stack* (list (pdf::outline-root pdf:*document*)))
	  (pdf::*root-page* (pdf::root-page pdf:*document*))
          (pdf:*page* nil)
          (pdf::*page-stream* (make-string-output-stream)))
    (declare (dynamic-extent pdf::*page-stream*))
    (with-standard-io-syntax
      ,@body)))

#|
(defun show-lines (lines)
   (dolist (line lines)
     (incf *line-number*)
     (when (and *page-height* (zerop (mod *line-number* *page-height*)))
       (restart-case (signal 'end-of-page)
         ;; Continue on the next page after it has been feeded
         (continue-with-next-page ())
         ;; Continue on the next column after it has been feeded
         (continue-with-next-column ())
 	 ;; Limit ourselves with the representation that fits on this page
         (truncate-output ())))))


(defun draw-page (content &key (size *default-page-size*)
                               (orientation *default-page-orientation*)
                               bounds margins
                               header (header-height (if header 12 0))
                               footer (footer-height (if footer 12 0)))
 ;;; Args: content  Text or other content
  ;;       header, footer 
  ;;       margins
  (with-quad (margin-left margin-top margin-right margin-bottom) margins
    (let* ((bounds (or bounds (compute-page-bounds size)))
           (width (aref bounds 2))
           (height (aref bounds 3))
           (x margin-left)
           (y (- height margin-top))
           (dx (- width margin-left margin-right))
           (dy (- height margin-top margin-bottom)))
      (pdf:with-page (:bounds bounds)
       ;(pdf:with-outline-level ("Three arial samples" (pdf:register-page-reference))
        (when header
          (pdf:with-saved-state
            (typeset::stroke (typeset:make-filled-vbox header dx header-height :top)
                             x y)))
        (typeset::stroke (typeset:make-filled-vbox content
                                                   dx (- dy header-height footer-height)
                                                   :top)
                         x (- y header-height))
        (when footer
          (pdf:with-saved-state
            (typeset::stroke (typeset:make-filled-vbox footer dx footer-height :top)
                             x (- y header-height footer-height))))
) ) ) )
 |#
