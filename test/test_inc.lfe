(define-module test_inc
  (export (a 3)))

(include-file "test_rec_defs.lfe")

(define (a x y r)
  (let ((c (make-point x y)))
    (make-circle c r)))
