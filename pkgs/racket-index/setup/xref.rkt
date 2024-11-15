#lang racket/base

(require scribble/xref
         racket/fasl
         racket/path
         racket/promise
         racket/contract
         setup/dirs
         setup/getinfo
         "private/doc-path.rkt"
         setup/doc-db
         pkg/path)

(provide load-collections-xref
         make-collections-xref
         get-rendered-doc-directories)

(define cached-xref #f)

(define (get-rendered-doc-directories no-user? no-main?)
  (append (get-dests 'scribblings no-user? no-main? #f #f)
          (get-dests 'rendered-scribblings no-user? no-main? #f #f)))

(struct dest+pkg (dest pkg))

(define (get-dests tag no-user? no-main? sxrefs? pkg-cache)
  (define main-dirs
    (for/hash ([k (in-list (find-relevant-directories (list tag) 'no-user))])
      (values k #t)))
  (apply
   append
   (for*/list ([dir (find-relevant-directories (list tag) 'all-available)]
               [d (let ([info-proc (get-info/full dir)])
                    (if info-proc
                        (info-proc tag (λ () '()))
                        '()))])
     (unless (and (list? d) (pair? d))
       (error 'xref "bad scribblings entry: ~e" d))
     (let* ([len   (length d)]
            [flags (if (len . >= . 2) (cadr d) '())]
            [name  (if (len . >= . 4)
                       (cadddr d)
                       (path->string
                        (path-replace-suffix (file-name-from-path (car d))
                                             #"")))]
            [out-count (if (len . >= . 5)
                           (list-ref d 4)
                           1)])
       (if (not (and (len . >= . 3) (memq 'omit (caddr d))))
           (let ([d (doc-path dir name flags (hash-ref main-dirs dir #f) 
                              (if no-user? 'never 'false-if-missing)
                              #:main? (not no-main?))])
             (if d
                 (cond
                   [sxrefs?
                    (define pkg (and pkg-cache (path->pkg dir #:cache pkg-cache)))
                    (for*/list ([i (in-range (add1 out-count))]
                                [p (in-value (build-path d (format "out~a.sxref" i)))]
                                #:when (file-exists? p))
                      (dest+pkg p pkg))]
                   [else
                    (list d)])
                 null))
           null)))))

(define ((dest->source done-ht quiet-fail?) dest-and-pkg)
  (define dest (dest+pkg-dest dest-and-pkg))
  (if (hash-ref done-ht dest #f)
      (lambda () #f)
      (lambda ()
        (hash-set! done-ht dest #t)
        (with-handlers ([exn:fail? (lambda (exn)
                                     (unless quiet-fail?
                                       (log-warning
                                        "warning: ~a"
                                        (if (exn? exn)
                                            (exn-message exn)
                                            (format "~e" exn))))
                                     #f)])
          (make-data+root+doc-id+pkg
           ;; data to deserialize:
           (cadr (call-with-input-file* dest fasl->s-exp))
           ;; provide a root for deserialization:
           (path-only dest)
           ;; Use the destination directory's name as an identifier,
           ;; which allows a faster and more compact indirection
           ;; for installation-scoped documentation:
           (let-values ([(base name dir?) (split-path dest)])
             (and (path? base)
                  (let-values ([(base name dir?) (split-path base)])
                    (and (path? name)
                         (path->string name)))))
           ;; Package containing the document source
           (dest+pkg-pkg dest-and-pkg))))))

(define (make-key->source db-path no-user? no-main? quiet-fail? register-shutdown!)
  (define main-db (and (not no-main?)
                       (cons (or db-path
                                 (build-path (find-doc-dir) "docindex.sqlite"))
                             ;; cache for a connection:
                             (box #f))))
  (define user-db (and (not no-user?)
                       (cons (build-path (find-user-doc-dir) "docindex.sqlite")
                             ;; cache for a connection:
                             (box #f))))
  (register-shutdown! (lambda ()
                        (define (close p)
                          (define c (unbox (cdr p)))
                          (when c
                            (if (box-cas! (cdr p) c #f)
                                (doc-db-disconnect c)
                                (close p))))
                        (when main-db (close main-db))
                        (when user-db (close user-db))))
  (define done-hts (make-hasheq)) ; tracks already-loaded documents per ci
  (define (get-done-ht use-id)
    (or (hash-ref done-hts use-id #f)
        (let ([ht (make-hash)])
          (hash-set! done-hts use-id ht)
          ht)))
  (define forced-all?s (make-hasheq)) ; per ci: whether forced all
  (define (force-all use-id)
    ;; force all documents
    (define thunks (get-reader-thunks no-user? no-main? quiet-fail? (get-done-ht use-id)))
    (hash-set! forced-all?s use-id #t)
    (lambda () 
      ;; return a procedure so we can produce a list of results:
      (lambda () 
        (for/list ([thunk (in-list thunks)])
          (thunk)))))
  (lambda (key use-id)
    (cond
     [(hash-ref forced-all?s use-id #f) #f]
     [key
      (define (try p)
        (and p
             (let* ([maybe-db (unbox (cdr p))]
                    [db 
                     ;; Use a cached connection, or...
                     (or (and (box-cas! (cdr p) maybe-db #f)
                              maybe-db)
                         ;; ... create a new one
                         (and (file-exists? (car p))
                              (doc-db-file->connection (car p))))])
               (and 
                db
                (let ()
                  ;; The db query:
                  (begin0
                    (let-values ([(path pkg) (doc-db-key->path+pkg db key)])
                      (and path
                           (dest+pkg path pkg)))
                    ;; cache the connection, if none is already cached:
                    (or (box-cas! (cdr p) #f db)
                        (doc-db-disconnect db))))))))
      (define dest-and-pkg (or (try main-db) (try user-db)))
      (and dest-and-pkg
           (if (eq? dest-and-pkg #t)
               (force-all use-id)
               ((dest->source (get-done-ht use-id) quiet-fail?) dest-and-pkg)))]
     [else
      (unless (hash-ref forced-all?s use-id #f)
        (force-all use-id))])))

(define (get-reader-thunks no-user? no-main? quiet-fail? done-ht)
  (define pkg-cache (make-hash))
  (map (dest->source done-ht quiet-fail?)
       (filter values (append (get-dests 'scribblings no-user? no-main? #t pkg-cache)
                              (get-dests 'rendered-scribblings no-user? no-main? #t pkg-cache)))))

(define (load-collections-xref [report-loading void])
  (or cached-xref
      (begin (report-loading)
             (set! cached-xref 
                   (make-collections-xref))
             cached-xref)))

(define (make-collections-xref #:no-user? [no-user? #f]
                               #:no-main? [no-main? #f]
                               #:doc-db [db-path #f]
                               #:quiet-fail? [quiet-fail? #f]
                               #:register-shutdown! [register-shutdown! void])
  (if (doc-db-available?)
      (load-xref null
                 #:demand-source-for-use
                 (make-key->source db-path no-user? no-main? quiet-fail?
                                   register-shutdown!))
      (load-xref (get-reader-thunks no-user? no-main? quiet-fail? (make-hash)))))



(provide
 (contract-out
  [get-current-doc-state (-> doc-state?)]
  [doc-state-changed? (-> doc-state? boolean?)]
  [doc-state? (-> any/c boolean?)]))

(define docindex.sqlite "docindex.sqlite")

(struct doc-state (table))
(define (get-current-doc-state)
  (doc-state
   (for/hash ([dir (in-list (get-doc-search-dirs))])
     (define pth (build-path dir docindex.sqlite))
     (values dir
             (and (file-exists? pth)
                  (file-or-directory-modify-seconds pth))))))
(define (doc-state-changed? a-doc-state)
  (define ht (doc-state-table a-doc-state))
  (define dirs (get-doc-search-dirs))
  (cond
    [(same-as-sets? dirs (hash-keys ht))
     (for/or ([dir (in-list dirs)])
       (define old (hash-ref ht dir))
       (define pth (build-path dir docindex.sqlite))
       (define new (and (file-exists? pth)
                        (file-or-directory-modify-seconds pth)))
       (not (equal? old new)))]
    [else #t]))

(define (same-as-sets? l1 l2)
  (and (andmap (λ (x1) (member x1 l2)) l1)
       (andmap (λ (x2) (member x2 l1)) l2)))
