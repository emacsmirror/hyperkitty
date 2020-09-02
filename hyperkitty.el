;; -*- lexical-binding: t -*-
;;; hyperkitty.el --- Emacs interface for Hyperkitty archives

;; Copyright 2020 Abhilash Raj

;; Author: Abhilash Raj <maxking@asynchronous.in>
;; URL: http://github.com/maxking/hyperkitty.el
;; Version: 0.0.1
;; Keywords: mail hyperkitty mailman
;; Package-Requires: ((request "0.3.2") (emacs "24.3"))
;; Prefix: hyperkitty
;; Separator: -

;;; Commentary
;; This package provides an Emacs interface for reading Mailman 3 archives
;; hosted via Hyperkitty.
;;
;; To use it, you need to set `hyperkitty-mlists' variable to a list of pairs
;; of Mailinglist and base url for the hyperkitty's hosted instance. For
;; example:
;;
;;     (setq
;;        hyperkitty-mlists
;;        ((cons \"test@mailman3.org\" \"https://lists.mailman3.org/archives\")))
;;
;; Then, you can simply use `M-x hyperkitty' to start using.

;;; Code:
(require 'cl-lib)
(require 'request)

(require 'hyperkitty-thread)
(require 'hyperkitty-urls)
(require 'hyperkitty-email)


(setf debug-on-error t)
(setf lexical-binding t)

(defvar hyperkitty-mlists nil
  "A list of MailingLists configured for the current instance.

Each entry in this list is a tuple, one the posting address for
the MailingList and other is the Base URL of the server.

For example:

    (setq
        hyperkitty-mlists
        ((\"test@mailman3.org\" . \"https://lists.mailman3.org/archives\")))
")


;;; HTTP fetch utilities.
(defun get-json (url success-func)
  "Call the given `url' and call provided call function on success.

We currently don't have a good error handling."
  (request
   url
   :parser 'json-read
   :success
   (cl-function (lambda (&key response &allow-other-keys)
                  (funcall success-func response)))))


(defun get-response-entries (response)
  (assoc-default 'results (request-response-data response)))


;;; Test function to print all the mailing list.
(defun print-mailinglist-response (response)
  "Print each element MailingLists from the response.

Handler for HTTP response for all the lists API. It simply prints
the list of MailingList."
  (with-current-buffer "*scratch*"
    (insert (format "URL: %s, Status: %s, Data: %s"
                    (request-response-url response)
                    (request-response-status-code response)
                    (mapcar 'print-mailinglist (get-response-entries response))))))


(defun print-mailinglist (mlist)
  "Get an association lists and prints the display name,
name and description of the list."
  (format "\nName: %s \nAddress: %s \nDescription: %s \n"
          (assoc-default 'display_name mlist)
          (assoc-default 'name mlist)
          (assoc-default 'description mlist)))


(defun choose-mailinglist ()
  "Ask user to choose a Mailinglist from the /lists API."
  (funcall
   completing-read-function
   "Select from list: "
   hyperkitty-mlists))


(defun choose-mailinglist-and-get-threads ()
  "Choose mailinglist and get their threads."
  (let* ((mlist (choose-mailinglist))
         (base-url (assoc-default mlist hyperkitty-mlists))
         (threads-url (hyperkitty-threads-url base-url mlist)))
    (get-json threads-url (apply-partially 'print-threads-table mlist base-url))))


(defun hyperkitty ()
  "This is the primary entrypoint to hyperkitty.el

It fetches the Hyperkitty API from the `hyperkitty-base-url'
variable and let's user choose one of the mailing list and then
opens a new buffer with a list of threads for that MailingList.
"
  (interactive)
  (choose-mailinglist-and-get-threads))

(provide 'hyperkitty)


;; threads related.

(defvar hyperkitty-page-size 25
  "Page size for Hyperkitty's pagination.

This affects how is this package able to recoginize if there are
more threads and print the [More Threads] button.
")

;; Keyboard map for threads-mode.
(defvar threads-mode-map nil "Keymap for 'threads-mode-map'")
(progn
  (setq threads-mode-map (make-sparse-keymap))
  (define-key threads-mode-map (kbd "<RET>") 'get-thread-emails)
  )


(define-derived-mode threads-mode tabulated-list-mode "threads-mode"
  "Major mode for MailingList threads.

It presents a list of threads in a tabular format with three
columns, Subject, Reply and Last Active date.
"
  (setq tabulated-list-format [("Subject" 80 nil)
							   ("Reply" 5 nil)
                               ("Last Active" 15 t)])
  (setq tabulated-list-sort-key (cons "Last Active" t))
  (tabulated-list-init-header))


(defun print-threads-table (mlist base-url response)
  "Print the whole threads table for a given MailingList.

Create a new buffer, named after the MailingList and switch to
threads-mode. Finally, display all the threads from the response.
"
  (interactive)
  (pop-to-buffer (format "*%s*" mlist) nil)
  (threads-mode)
  (make-local-variable 'page-num)
  (make-local-variable 'current-mlist)
  (make-local-variable 'hyperkitty-base-url)
  (setq page-num 1)
  (setq current-mlist mlist)
  (setq hyperkitty-base-url base-url)
  (setq tabulated-list-entries (get-threads-response-with-more-button response))
  (tabulated-list-print t))


(defun get-threads-response (response)
  "Given a HTTP response, return a list that tablulated-list-mode.

It expects data in the form of:
(<thread-url> [(<subject> <date>)
               (<subject2> <date2>)
               ...])

It also expects the list to be paginated with simple
PageNumberPagination from Django Rest Framework.
"
  (mapcar (lambda (arg) (list (assoc-default 'url arg)
                              (vector (assoc-default 'subject arg)
									  (number-to-string (assoc-default 'replies_count arg))
                                      (assoc-default 'date_active arg))))
          (get-response-entries response)))



(defun get-threads-response-with-more-button (response)
  "Get the list of threads from the response and add a
[More Threads] button.

This creates a new button.
"
  (let ((threads (get-threads-response response)))
    (message (format "Length of threads is: %s and page-size is: %s" (length threads) hyperkitty-page-size))
    (if (= (length threads) hyperkitty-page-size)
        (cons
         (list "more-threads"
               (vector
                (cons
                 "[More Threads]"
                 (list 'action 'button-fetch-more-threads
                       'type 'hyperkitty-more-threads-button )) "" ""))
         threads)
      threads)))


(defun button-fetch-more-threads (button)
  "Get more threads for the current thread."
  (setq page-num (+ page-num 1))
  (let ((threads-url (hyperkitty-threads-url hyperkitty-base-url current-mlist page-num)))
	(get-json threads-url 'update-threads)))


(defun update-threads (response)
  (setq tabulated-list-entries (append tabulated-list-entries (get-threads-response response)))
  (tabulated-list-print t))


(define-button-type 'hyperkitty-more-threads-button
  'action 'button-fetch-more-threads
  'follow-link t
  'help-echo "Fetch More threads"
  'help-args "Get more threads.")

;; message stuff.
(defun get-thread-emails ()
  "Get Emails for the thread of current line."
  (interactive)
  (get-json
   (hyperkitty-thread-emails-url (tabulated-list-get-id))
   (apply-partially 'print-emails-response (elt (tabulated-list-get-entry) 0))))


(defun print-emails-response (subject response)
  "Print all the Emails of a thread in a new Buffer.

Create a new buffer, named after the subject of the email and
print all the emails in that new buffer. Each Email's content is
fetched individual since the entries only contain the metadata
about the Email.
"
  (pop-to-buffer (format "*%s*" subject))
  (erase-buffer)
  (thread-emails-mode)
  (read-only-mode)
  (setq outline-regexp "From: ")
  (let ((inhibit-read-only t))
        (insert (propertize
                 (format "%s\n" subject)
                 'font-lock-face 'bold
                 'height 200)))
  (mapcar 'print-email (reverse (get-response-entries response))))


(defun print-email (email)
  "Fetch and print a single email to the current buffer.

Given a metadata object for Email, fetch the actual contents of
the Email and print it to the current buffer.
"
  (get-json
   (assoc-default 'url email)
   (lambda (response)
     (let ((anemail (request-response-data response))
           (inhibit-read-only t))
       (insert (print-email-headers anemail))
       (maybe-print-email-attachments anemail)
       (insert (format "\n%s\n\n" (assoc-default 'content anemail))))
     (outline-hide-entry))))


(defun print-email-headers (anemail)
  (format
   "From: %s <%s>\nMessage-ID: %s\nSubject: %s\nDate: %s:\n"
   (assoc-default 'sender_name anemail)
   (assoc-default 'address (assoc-default 'sender anemail))
   (assoc-default 'message_id anemail)
   (assoc-default 'subject anemail)
   (assoc-default 'date anemail)))

(defun maybe-print-email-attachments (anemail)
  (let ((attachments (assoc-default 'attachments anemail)))
    (if (> (length attachments) 0)
        (progn
          (insert "Attachments: ")
           (mapcar
            (lambda (arg)
              (insert-button
               (format "%s(%sKB)" (assoc-default 'name arg) (assoc-default 'size arg))
               'action (apply-partially 'hyperkitty-attachments (assoc-default 'download arg)))
              (insert " "))
            attachments)
          (insert "\n")))))


(defun hyperkitty-attachments (url button)
  "Hyperkitty fetch the attachments.

This exists as a separate function so that we can use
`apply-partially' to create a function that acts like a click
handler. Using this in a lambda function would evaluate it before
we want it to be evaluated.
"
  (browse-url url))


(define-derived-mode thread-emails-mode outline-mode "thread-emails-mode"
  "Minor mode to simulate buffer local keybindings."
  (setq font-lock-defaults '(email-highlights)))


(defun hyperkitty-outline-toggle ()
  "Show/Hide the current outline entry we are on."
  (interactive)
  (if (outline-invisible-p (line-end-position))
	  (outline-show-entry)
	(outline-hide-entry)))

(defun hyperkitty-kill-current-buffer ()
  "Kill the current buffer."
  (interactive)
  (kill-buffer (current-buffer)))


(defvar thread-emails-mode-map nil "Keymap for 'thread-emails-mode'")
(progn
  (setq thread-emails-mode-map (make-sparse-keymap))
  (define-key thread-emails-mode-map (kbd "<RET>") 'hyperkitty-outline-toggle)
  (define-key thread-emails-mode-map (kbd "TAB") 'hyperkitty-outline-toggle)
  (define-key thread-emails-mode-map (kbd "q") 'hyperkitty-kill-current-buffer))


(setq email-highlights
      '(("From:\\|Date:\\|Subject:\\|Message-ID:\\|Attachments:" . font-lock-keyword-face)
        (">.*" . font-lock-comment-face)))

;; url stuff.
(defun hyperkitty-lists-url (base-url)
  "Get a list of all MailingLists from API.

Currently, this does not handle pagination and simply returns the
default URL without pagination.
"
  (concat base-url "/api/lists/"))

(defun hyperkitty-threads-url (base-url mlist &optional page)
  "Get a list of all threads for a MailingList.

Currently, this does not handle pagination and simply returns the
default URL without pagination.
"
  (let ((thread-url (concat base-url "/api/list/" mlist "/threads")))
	(if page
		(concat thread-url (format "?page=%s" page))
	  thread-url)))

(defun hyperkitty-thread-emails-url (threads-url)
  "Get all emails for the given thread URL.

This does not handle pagination currently.
"
  (concat threads-url "/emails"))


(defun hyperkitty-get-base-url ()
  "Prompt User to get the base URL for hyperkitty."
  (read-string "Enter Hyperkitty URL:"))

;;; hyperkitty.el ends here
