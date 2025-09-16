;; Anti-Corruption Whistle DAO - Core Whistleblower Protection Contract
;; This contract handles anonymous report submissions, protection fund management,
;; and emergency response coordination for whistleblowers.

;; Contract constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_ALREADY_EXISTS (err u101))
(define-constant ERR_NOT_FOUND (err u102))
(define-constant ERR_INSUFFICIENT_FUNDS (err u103))
(define-constant ERR_INVALID_AMOUNT (err u104))
(define-constant ERR_REPORT_SEALED (err u105))
(define-constant ERR_ALREADY_VOTED (err u106))
(define-constant ERR_VOTING_ENDED (err u107))
(define-constant MIN_PROTECTION_AMOUNT u1000000) ;; 1 STX minimum
(define-constant EMERGENCY_THRESHOLD u3) ;; Emergency votes needed
(define-constant VOTING_DURATION u144) ;; ~24 hours in blocks

;; Data maps and variables
(define-map reports
  { report-id: uint }
  {
    reporter: principal,
    report-hash: (buff 32),
    category: (string-ascii 50),
    severity: uint,
    status: (string-ascii 20),
    protection-amount: uint,
    created-at: uint,
    vote-count: uint,
    emergency-votes: uint,
    sealed: bool
  }
)

(define-map protection-funds
  { recipient: principal }
  { total-allocated: uint, withdrawn: uint, active: bool }
)

(define-map emergency-responders
  { responder: principal }
  { active: bool, reputation: uint }
)

(define-map voting-records
  { report-id: uint, voter: principal }
  { vote-type: (string-ascii 20), timestamp: uint }
)

;; Contract variables
(define-data-var next-report-id uint u1)
(define-data-var total-protection-pool uint u0)
(define-data-var contract-active bool true)
(define-data-var emergency-mode bool false)

;; Read-only functions
(define-read-only (get-report (report-id uint))
  (map-get? reports { report-id: report-id })
)

(define-read-only (get-protection-fund (recipient principal))
  (map-get? protection-funds { recipient: recipient })
)

(define-read-only (get-emergency-responder (responder principal))
  (map-get? emergency-responders { responder: responder })
)

(define-read-only (get-total-protection-pool)
  (var-get total-protection-pool)
)

(define-read-only (is-contract-active)
  (var-get contract-active)
)

(define-read-only (is-emergency-mode)
  (var-get emergency-mode)
)

(define-read-only (has-voted (report-id uint) (voter principal))
  (is-some (map-get? voting-records { report-id: report-id, voter: voter }))
)

(define-read-only (get-next-report-id)
  (var-get next-report-id)
)

;; Private functions
(define-private (is-authorized (user principal))
  (or (is-eq user CONTRACT_OWNER)
      (is-some (map-get? emergency-responders { responder: user })))
)

(define-private (calculate-protection-amount (severity uint))
  (if (> severity u5)
      (* MIN_PROTECTION_AMOUNT u3)
      (if (> severity u3)
          (* MIN_PROTECTION_AMOUNT u2)
          MIN_PROTECTION_AMOUNT))
)

(define-private (update-protection-pool (amount uint) (increase bool))
  (if increase
      (var-set total-protection-pool (+ (var-get total-protection-pool) amount))
      (var-set total-protection-pool (- (var-get total-protection-pool) amount)))
)

;; Public functions
(define-public (submit-report 
    (report-hash (buff 32))
    (category (string-ascii 50))
    (severity uint))
  (let (
    (report-id (var-get next-report-id))
    (protection-amount (calculate-protection-amount severity))
  )
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (and (>= severity u1) (<= severity u10)) ERR_INVALID_AMOUNT)
    
    ;; Create the report
    (map-set reports
      { report-id: report-id }
      {
        reporter: tx-sender,
        report-hash: report-hash,
        category: category,
        severity: severity,
        status: "submitted",
        protection-amount: protection-amount,
        created-at: stacks-block-height,
        vote-count: u0,
        emergency-votes: u0,
        sealed: false
      }
    )
    
    ;; Initialize protection fund for reporter
    (map-set protection-funds
      { recipient: tx-sender }
      { total-allocated: protection-amount, withdrawn: u0, active: true }
    )
    
    ;; Update counters
    (var-set next-report-id (+ report-id u1))
    (update-protection-pool protection-amount true)
    
    (print {
      event: "report-submitted",
      report-id: report-id,
      reporter: tx-sender,
      category: category,
      severity: severity
    })
    
    (ok report-id)
  )
)

(define-public (vote-on-report (report-id uint) (vote-type (string-ascii 20)))
  (let (
    (report (unwrap! (map-get? reports { report-id: report-id }) ERR_NOT_FOUND))
    (voting-deadline (+ (get created-at report) VOTING_DURATION))
  )
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (not (get sealed report)) ERR_REPORT_SEALED)
    (asserts! (<= stacks-block-height voting-deadline) ERR_VOTING_ENDED)
    (asserts! (not (has-voted report-id tx-sender)) ERR_ALREADY_VOTED)
    
    ;; Record the vote
    (map-set voting-records
      { report-id: report-id, voter: tx-sender }
      { vote-type: vote-type, timestamp: stacks-block-height }
    )
    
    ;; Update report vote count
    (map-set reports
      { report-id: report-id }
      (merge report { vote-count: (+ (get vote-count report) u1) })
    )
    
    (print {
      event: "vote-cast",
      report-id: report-id,
      voter: tx-sender,
      vote-type: vote-type
    })
    
    (ok true)
  )
)

(define-public (trigger-emergency-response (report-id uint))
  (let (
    (report (unwrap! (map-get? reports { report-id: report-id }) ERR_NOT_FOUND))
    (responder-info (unwrap! (map-get? emergency-responders { responder: tx-sender }) ERR_UNAUTHORIZED))
  )
    (asserts! (get active responder-info) ERR_UNAUTHORIZED)
    (asserts! (not (get sealed report)) ERR_REPORT_SEALED)
    (asserts! (not (has-voted report-id tx-sender)) ERR_ALREADY_VOTED)
    
    ;; Record emergency vote
    (map-set voting-records
      { report-id: report-id, voter: tx-sender }
      { vote-type: "emergency", timestamp: stacks-block-height }
    )
    
    ;; Update emergency vote count
    (let ((new-emergency-votes (+ (get emergency-votes report) u1)))
      (map-set reports
        { report-id: report-id }
        (merge report { 
          emergency-votes: new-emergency-votes,
          status: (if (>= new-emergency-votes EMERGENCY_THRESHOLD) "emergency" "submitted")
        })
      )
      
      ;; Activate emergency mode if threshold reached
      (if (>= new-emergency-votes EMERGENCY_THRESHOLD)
          (var-set emergency-mode true)
          true)
    )
    
    (print {
      event: "emergency-response",
      report-id: report-id,
      responder: tx-sender,
      emergency-votes: (get emergency-votes report)
    })
    
    (ok true)
  )
)

(define-public (seal-report (report-id uint))
  (let (
    (report (unwrap! (map-get? reports { report-id: report-id }) ERR_NOT_FOUND))
  )
    (asserts! (is-authorized tx-sender) ERR_UNAUTHORIZED)
    (asserts! (not (get sealed report)) ERR_REPORT_SEALED)
    
    (map-set reports
      { report-id: report-id }
      (merge report { sealed: true, status: "sealed" })
    )
    
    (print {
      event: "report-sealed",
      report-id: report-id,
      sealer: tx-sender
    })
    
    (ok true)
  )
)

(define-public (add-emergency-responder (responder principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    
    (map-set emergency-responders
      { responder: responder }
      { active: true, reputation: u100 }
    )
    
    (print {
      event: "emergency-responder-added",
      responder: responder
    })
    
    (ok true)
  )
)

(define-public (remove-emergency-responder (responder principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    
    (map-set emergency-responders
      { responder: responder }
      { active: false, reputation: u0 }
    )
    
    (print {
      event: "emergency-responder-removed",
      responder: responder
    })
    
    (ok true)
  )
)

(define-public (withdraw-protection-funds (amount uint))
  (let (
    (fund-info (unwrap! (map-get? protection-funds { recipient: tx-sender }) ERR_NOT_FOUND))
    (available (- (get total-allocated fund-info) (get withdrawn fund-info)))
  )
    (asserts! (get active fund-info) ERR_UNAUTHORIZED)
    (asserts! (<= amount available) ERR_INSUFFICIENT_FUNDS)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    ;; Update withdrawal record
    (map-set protection-funds
      { recipient: tx-sender }
      (merge fund-info { withdrawn: (+ (get withdrawn fund-info) amount) })
    )
    
    ;; Update protection pool
    (update-protection-pool amount false)
    
    ;; Transfer funds (in production, this would transfer STX)
    (print {
      event: "protection-funds-withdrawn",
      recipient: tx-sender,
      amount: amount,
      remaining: (- available amount)
    })
    
    (ok true)
  )
)

(define-public (deactivate-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set contract-active false)
    
    (print { event: "contract-deactivated", owner: tx-sender })
    (ok true)
  )
)

(define-public (reactivate-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set contract-active true)
    (var-set emergency-mode false)
    
    (print { event: "contract-reactivated", owner: tx-sender })
    (ok true)
  )
)


