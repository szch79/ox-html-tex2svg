;;; ox-html-tex2svg.el --- Async LaTeX to SVG for Org HTML export -*- lexical-binding: t; -*-

;; Copyright (C) 2025 MT Lin

;; Author: MT Lin <https://github.com/szch79>
;; Homepage: https://github.com/szch79/ox-html-tex2svg
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Provides a minor mode that hooks/advices the HTML export and converts LaTeX
;; fragments/environments that MathJax cannot render into SVG images
;; asynchronously.  Leverages Tecosaur & Karthink's `org-latex-preview' for
;; async SVG generation.
;;
;; For export backend authors that want to derive from ox-html, there's a set of
;; aliases for transcoders and filter functions.

;;; Code:

(require 'ox-html)

(declare-function org-latex-preview--environment-numbering-table "org-latex-preview" (&optional parse-tree))
(declare-function org-latex-preview--get-preamble "org-latex-preview" ())
(declare-function org-latex-preview--get-cached "org-latex-preview" (key &optional cache-location))
(declare-function org-latex-preview--hash "org-latex-preview" (processing-type preamble string imagetype fg bg &optional number))
(declare-function org-latex-preview--tex-styled "org-latex-preview" (processing-type value appearance-options))
(declare-function org-latex-preview--create-image-async "org-latex-preview" (processing-type fragments-info &rest args))
(declare-function org-async-wait-for "org-async" (&rest tasks))

(defvar org-latex-preview--svg-fg-standin)
(defvar org-latex-preview-process-alist)


;;; Customization
;;;

(defgroup ox-html-tex2svg nil
  "Async LaTeX to SVG conversion for Org HTML export."
  :group 'org-export-html
  :prefix "ox-html-tex2svg-")

;; NOTE: this `defvar' should be placed before `ox-html-tex2svg-environments',
;; as this is automatically set by its setter
(defvar ox-html-tex2svg--env-regexp nil
  "Regexp matching LaTeX environments that need SVG conversion.
Computed from `ox-html-tex2svg-environments'.")

(defcustom ox-html-tex2svg-environments
  '("tikzpicture" "tikzcd")
  "List of LaTeX environment names that trigger SVG conversion.

When a LaTeX fragment contains \\begin{NAME}...\\end{NAME} and NAME matches one
one of these strings, it will be rendered to SVG.  Note that NAME does not need
to be the outermost environment.

Use `setopt' to set this variable."
  :type '(repeat string)
  :set (lambda (sym val)
         (set-default sym val)
         (setq ox-html-tex2svg--env-regexp
               (let ((kw-opt (regexp-opt val)))
                 (rx-to-string
                  `(seq "\\begin{"
                        (regexp ,kw-opt)
                        "}"
                        (* anything)
                        "\\end{"
                        (regexp ,kw-opt)
                        "}")))))
  :initialize #'custom-initialize-reset
  :group 'ox-html-tex2svg)

(defcustom ox-html-tex2svg-process-default 'dvisvgm
  "The default process to convert LaTeX fragments to image files when export.
All available processes and theirs documents can be found in
`org-latex-preview-process-alist', which see.

The process must produce SVG output."
  :type 'symbol
  :set (lambda (sym val)
         (when (boundp 'org-latex-preview-process-alist)
           (let* ((process-info (alist-get val org-latex-preview-process-alist))
                  (output-type (plist-get process-info :image-output-type)))
             (unless (equal output-type "svg")
               (user-error "ox-html-tex2svg: process `%s' produces `%s', not SVG"
                           val (or output-type "unknown")))))
         (set-default sym val))
  :initialize #'custom-initialize-default
  :group 'ox-html-tex2svg)

(defcustom ox-html-tex2svg-html-template "<div[ID] style=\"text-align:center\">
  [SVG]
</div>"
  "HTML template for wrapping inline SVG content.
The template can contain two placeholders, \"[ID]\" for possible link ID, and
\"[SVG]\" for the SVG content to be inserted."
  :type 'string
  :group 'ox-html-tex2svg)

(defcustom ox-html-tex2svg-trigger-function #'ox-html-tex2svg--default-trigger
  "Predicate function to determine if SVG conversion should run.
Called with two arguments: the export backend and the export communication
channel.  Should return non-nil if SVG conversion should proceed.

Technically, this package is for HTML export only, so the default trigger checks
for whether the backend is derived from HTML and `:with-latex' is `mathjax'.
However, the user can customize this behavior if, for example, their derived
custom backend does not want the SVG conversion."
  :type 'function
  :group 'ox-html-tex2svg)

(defcustom ox-html-tex2svg-scale 1.0
  "Scale factor for exported SVG images."
  :type 'number
  :group 'ox-html-tex2svg)


;;; States
;;;

(defvar-local ox-html-tex2svg--numbering-table nil
  "Hash table mapping LaTeX elements to equation numbers.
Built by `org-latex-preview--environment-numbering-table' during export.")

(defvar-local ox-html-tex2svg--async-tasks nil
  "List of async task handles returned by `org-latex-preview--create-image-async'.
Used to await completion at export.")


;;; Async
;;;

(defun ox-html-tex2svg--needs-svg-p (body)
  "Return non-nil if BODY requires SVG conversion.
Matched against environments in `ox-html-tex2svg-environments'."
  (and ox-html-tex2svg--env-regexp
       (string-match-p ox-html-tex2svg--env-regexp body)))

(defun ox-html-tex2svg--default-trigger (backend info)
  "Return non-nil if BACKEND is derived from HTML and uses MathJax.
The MathJax check is done by checking the `:with-latex' property of INFO.

For BACKEND and INFO, check `ox-html-tex2svg-trigger-function'."
  (and (org-export-derived-backend-p backend 'html)
       (eq (plist-get info :with-latex) 'mathjax)))

(defun ox-html-tex2svg--compute-hash (body preamble number)
  "Compute cache hash for BODY with PREAMBLE and equation NUMBER.

Uses identical parameters to what `org-latex-preview--create-image-async' will
use to reuse its cache."
  (org-latex-preview--hash
   ox-html-tex2svg-process-default
   preamble
   body
   "svg"
   nil
   nil
   number))

(defun ox-html-tex2svg--load-svg-content (path)
  "Read SVG file at PATH and return the <svg>...</svg> element with scaling.
Return nil if PATH is nil or the file doesn't exist."
  (when (and path (file-exists-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (when (re-search-forward "<svg[^>]*>" nil t)
        (let ((svg-start (match-beginning 0))
              (svg-tag-end (match-end 0)))
          ;; Scale width/height attributes if present
          (unless (= ox-html-tex2svg-scale 1.0)
            (save-excursion
              (goto-char svg-start)
              (dolist (attr '("width" "height"))
                (when (re-search-forward
                       (rx-to-string
                        `(seq word-boundary
                              ,attr "="
                              (group (any "\"'"))
                              (group (+ (any "0-9.")))
                              (group (* (any "a-z")))
                              (backref 1)))
                       svg-tag-end t)
                  (let* ((quote-char (match-string 1))
                         (val (string-to-number (match-string 2)))
                         (unit (match-string 3))
                         (scaled (* val ox-html-tex2svg-scale)))
                    (replace-match
                     (format "%s=%s%g%s%s"
                             attr quote-char scaled unit quote-char)))))))
          (goto-char (point-max))
          (when (re-search-backward "</svg>" nil t)
            (buffer-substring-no-properties svg-start (match-end 0))))))))

(defun ox-html-tex2svg--format-html (svg-content &optional id)
  "Wrap SVG-CONTENT using `ox-html-tex2svg-html-template'.
ID, if non-nil, is used for the HTML id attribute.
Return nil if SVG-CONTENT is nil."
  (when svg-content
    (let ((id-attr (if id (format " id=\"%s\"" id) "")))
      (string-replace "[SVG]" svg-content
                      (string-replace "[ID]" id-attr
                                      ox-html-tex2svg-html-template)))))

(defun ox-html-tex2svg--start-async-generation (tree info)
  "Start async SVG generation for target LaTeX elements in TREE.

INFO is the export communication channel."
  (setq ox-html-tex2svg--async-tasks nil)
  (setq ox-html-tex2svg--numbering-table
        (org-latex-preview--environment-numbering-table tree))
  (let* ((preamble (org-latex-preview--get-preamble))
         (mapped
          (org-element-map tree '(latex-environment latex-fragment)
            (lambda (el)
              (let* ((body (org-element-property :value el))
                     (number (gethash el ox-html-tex2svg--numbering-table))
                     (hash (ox-html-tex2svg--compute-hash body preamble number)))
                (when (and (ox-html-tex2svg--needs-svg-p body)
                           (not (org-latex-preview--get-cached hash)))
                  `(:string ,(org-latex-preview--tex-styled
                              ox-html-tex2svg-process-default
                              body
                              `(:foreground ,org-latex-preview--svg-fg-standin
                                :background "Transparent"
                                :number ,number))
                    :key ,hash))))
            info))
         (fragment-info (delq nil mapped)))
    (when fragment-info
      (setq ox-html-tex2svg--async-tasks
            (org-latex-preview--create-image-async
             ox-html-tex2svg-process-default
             fragment-info
             :latex-preamble preamble
             :appearance-options
             `(:foreground ,org-latex-preview--svg-fg-standin
               :background "Transparent")
             :place-preview-p nil))))
  tree)

(defun ox-html-tex2svg--latex-to-svg (el info)
  "Return SVG for latex fragment EL if it matches target environments.
Return nil otherwise.  INFO is the export communication channel."
  (let ((body (org-element-property :value el)))
    (when (ox-html-tex2svg--needs-svg-p body)
      ;; Wait for async tasks if pending
      (when ox-html-tex2svg--async-tasks
        (apply #'org-async-wait-for ox-html-tex2svg--async-tasks)
        (setq ox-html-tex2svg--async-tasks nil))
      (let* ((preamble (org-latex-preview--get-preamble))
             (number (gethash el ox-html-tex2svg--numbering-table))
             (hash (ox-html-tex2svg--compute-hash body preamble number))
             (cached (org-latex-preview--get-cached hash))
             (svg-path (car cached))
             (svg-content (ox-html-tex2svg--load-svg-content svg-path))
             (id (org-html--reference el info t)))
        (ox-html-tex2svg--format-html svg-content id)))))


;;; Advice/hook for ox-html
;;;

(defun ox-html-tex2svg--org-html-latex-a (orig-fun el contents info)
  "Advice for HTML export of LaTeX fragments."
  (or (and (funcall ox-html-tex2svg-trigger-function
                    (org-export-backend-name (plist-get info :back-end))
                    info)
           (ox-html-tex2svg--latex-to-svg el info))
      (funcall orig-fun el contents info)))

(defun ox-html-tex2svg--parse-tree-filter (tree backend info)
  "Filter for `org-export-filter-parse-tree-functions'."
  (when (funcall ox-html-tex2svg-trigger-function backend info)
    (ox-html-tex2svg--start-async-generation tree info))
  tree)


;;; For derived export backend authors
;;;

(defun ox-html-tex2svg-extend-transcoder (base)
  "Return a transcoder that extends the BASE transcode to try tex2svg."
  (lambda (element contents info)
    (or (ox-html-tex2svg--latex-to-svg element info)
        (funcall base element contents info))))

(defalias 'ox-html-tex2svg-latex-environment
  (ox-html-tex2svg-extend-transcoder #'org-html-latex-environment)
  "Transcoder for `latex-environment' with tex2svg support.")

(defalias 'ox-html-tex2svg-latex-fragment
  (ox-html-tex2svg-extend-transcoder #'org-html-latex-fragment)
  "Transcoder for `latex-fragment' with tex2svg support.")

(defalias 'ox-html-tex2svg-filter-parse-tree
  #'ox-html-tex2svg--parse-tree-filter
  "Parse-tree filter for tex2svg support.
Must be added to `:filters-alist' alongside the transcoders.")


;;; Minor mode that injects to ox-html
;;;

(defun ox-html-tex2svg--check-dependencies ()
  "Check if required dependencies are available.
Signals an error if `org-latex-preview' is not available."
  (unless (require 'org-latex-preview nil t)
    (user-error (concat "ox-html-tex2svg requires `org-latex-preview', see: "
                        "https://abode.karthinks.com/org-latex-preview/"))))

;;;###autoload
(defun ox-html-tex2svg-enable ()
  "Enable async LaTeX to SVG conversion for Org HTML export."
  (interactive)
  (ox-html-tex2svg--check-dependencies)
  (add-hook 'org-export-filter-parse-tree-functions
            #'ox-html-tex2svg--parse-tree-filter)
  (advice-add 'org-html-latex-environment :around
              #'ox-html-tex2svg--org-html-latex-a)
  (advice-add 'org-html-latex-fragment :around
              #'ox-html-tex2svg--org-html-latex-a))

(defun ox-html-tex2svg-disable ()
  "Disable async LaTeX to SVG conversion for Org HTML export."
  (interactive)
  (remove-hook 'org-export-filter-parse-tree-functions
               #'ox-html-tex2svg--parse-tree-filter)
  (advice-remove 'org-html-latex-environment
                 #'ox-html-tex2svg--org-html-latex-a)
  (advice-remove 'org-html-latex-fragment
                 #'ox-html-tex2svg--org-html-latex-a))

;;;###autoload
(define-minor-mode ox-html-tex2svg-mode
  "Toggle async LaTeX to SVG conversion for Org HTML export.
When enabled, LaTeX environments matching `ox-html-tex2svg-environments' are
rendered to inline SVG during HTML export."
  :global t
  :group 'ox-html-tex2svg
  (if ox-html-tex2svg-mode
      (ox-html-tex2svg-enable)
    (ox-html-tex2svg-disable)))

(provide 'ox-html-tex2svg)

;;; ox-html-tex2svg.el ends here
