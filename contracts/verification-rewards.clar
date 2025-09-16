;; Anti-Corruption Whistle DAO - Verification & Rewards Contract
;; This contract manages community validation, verification processes,
;; reward distribution, and validator reputation systems.

;; Contract constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_ALREADY_EXISTS (err u201))
(define-constant ERR_NOT_FOUND (err u202))
(define-constant ERR_INSUFFICIENT_FUNDS (err u203))
(define-constant ERR_INVALID_AMOUNT (err u204))
(define-constant ERR_ALREADY_VERIFIED (err u205))
(define-constant ERR_ALREADY_STAKED (err u206))
(define-constant ERR_INSUFFICIENT_STAKE (err u207))
(define-constant ERR_VALIDATION_ENDED (err u208))
(define-constant MIN_VALIDATOR_STAKE u500000) ;; 0.5 STX minimum
(define-constant VALIDATION_THRESHOLD u3) ;; Minimum validators needed
(define-constant REWARD_MULTIPLIER u10) ;; 10x severity as base reward
(define-constant MAX_VALIDATOR_REWARD u100000) ;; Maximum validator reward
(define-constant VALIDATION_PERIOD u288) ;; ~48 hours in blocks

;; Data maps and variables
(define-map validators
  { validator: principal }
  {
    stake-amount: uint,
    reputation-score: uint,
    total-validations: uint,
    correct-validations: uint,
    last-activity: uint,
    active: bool
  }
)

(define-map validation-sessions
  { session-id: uint }
  {
    report-id: uint,
    initiator: principal,
    status: (string-ascii 20),
    validator-count: uint,
    approval-count: uint,
    rejection-count: uint,
    total-stake: uint,
    reward-pool: uint,
    created-at: uint,
    deadline: uint,
    finalized: bool
  }
)

(define-map validator-votes
  { session-id: uint, validator: principal }
  {
    vote: (string-ascii 10),
    stake-amount: uint,
    timestamp: uint,
    rewarded: bool
  }
)

(define-map evidence-submissions
  { evidence-id: uint }
  {
    session-id: uint,
    submitter: principal,
    evidence-hash: (buff 32),
    evidence-type: (string-ascii 30),
    credibility-score: uint,
    verified: bool,
    timestamp: uint
  }
)

(define-map reward-claims
  { claimant: principal, session-id: uint }
  { amount: uint, claimed: bool, claim-type: (string-ascii 20) }
)

;; Contract variables
(define-data-var next-session-id uint u1)
(define-data-var next-evidence-id uint u1)
(define-data-var total-validator-pool uint u0)
(define-data-var total-reward-pool uint u0)
(define-data-var active-validators uint u0)
(define-data-var contract-paused bool false)

;; Read-only functions
(define-read-only (get-validator (validator principal))
  (map-get? validators { validator: validator })
)

(define-read-only (get-validation-session (session-id uint))
  (map-get? validation-sessions { session-id: session-id })
)

(define-read-only (get-validator-vote (session-id uint) (validator principal))
  (map-get? validator-votes { session-id: session-id, validator: validator })
)

(define-read-only (get-evidence (evidence-id uint))
  (map-get? evidence-submissions { evidence-id: evidence-id })
)

(define-read-only (get-reward-claim (claimant principal) (session-id uint))
  (map-get? reward-claims { claimant: claimant, session-id: session-id })
)

(define-read-only (get-total-validator-pool)
  (var-get total-validator-pool)
)

(define-read-only (get-total-reward-pool)
  (var-get total-reward-pool)
)

(define-read-only (get-active-validators)
  (var-get active-validators)
)

(define-read-only (is-contract-paused)
  (var-get contract-paused)
)

(define-read-only (calculate-validator-reputation (correct-validations uint) (total-validations uint))
  (if (is-eq total-validations u0)
      u100
      (/ (* correct-validations u100) total-validations))
)

;; Private functions
(define-private (is-qualified-validator (validator principal))
  (match (map-get? validators { validator: validator })
    validator-info
      (and (get active validator-info)
           (>= (get stake-amount validator-info) MIN_VALIDATOR_STAKE)
           (>= (get reputation-score validator-info) u60))
    false
  )
)

(define-private (calculate-reward-amount (severity uint) (validator-count uint))
  (let ((base-reward (* severity REWARD_MULTIPLIER))
        (divided-reward (/ base-reward validator-count)))
    (if (< divided-reward MAX_VALIDATOR_REWARD)
        divided-reward
        MAX_VALIDATOR_REWARD))
)

(define-private (update-validator-reputation (validator principal) (correct bool))
  (match (map-get? validators { validator: validator })
    validator-info
      (let (
        (new-total (+ (get total-validations validator-info) u1))
        (new-correct (if correct 
                        (+ (get correct-validations validator-info) u1)
                        (get correct-validations validator-info)))
        (new-reputation (calculate-validator-reputation new-correct new-total))
      )
        (map-set validators
          { validator: validator }
          (merge validator-info {
            total-validations: new-total,
            correct-validations: new-correct,
            reputation-score: new-reputation,
            last-activity: stacks-block-height
          })
        )
        true
      )
    false
  )
)

;; Public functions
(define-public (register-as-validator (stake-amount uint))
  (begin
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (>= stake-amount MIN_VALIDATOR_STAKE) ERR_INSUFFICIENT_STAKE)
    (asserts! (is-none (map-get? validators { validator: tx-sender })) ERR_ALREADY_EXISTS)
    
    ;; Register validator
    (map-set validators
      { validator: tx-sender }
      {
        stake-amount: stake-amount,
        reputation-score: u100,
        total-validations: u0,
        correct-validations: u0,
        last-activity: stacks-block-height,
        active: true
      }
    )
    
    ;; Update counters
    (var-set total-validator-pool (+ (var-get total-validator-pool) stake-amount))
    (var-set active-validators (+ (var-get active-validators) u1))
    
    (print {
      event: "validator-registered",
      validator: tx-sender,
      stake-amount: stake-amount
    })
    
    (ok true)
  )
)

(define-public (increase-stake (additional-amount uint))
  (let (
    (validator-info (unwrap! (map-get? validators { validator: tx-sender }) ERR_NOT_FOUND))
  )
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (get active validator-info) ERR_UNAUTHORIZED)
    (asserts! (> additional-amount u0) ERR_INVALID_AMOUNT)
    
    ;; Update stake
    (map-set validators
      { validator: tx-sender }
      (merge validator-info { 
        stake-amount: (+ (get stake-amount validator-info) additional-amount),
        last-activity: stacks-block-height
      })
    )
    
    ;; Update total pool
    (var-set total-validator-pool (+ (var-get total-validator-pool) additional-amount))
    
    (print {
      event: "stake-increased",
      validator: tx-sender,
      additional-amount: additional-amount,
      new-total: (+ (get stake-amount validator-info) additional-amount)
    })
    
    (ok true)
  )
)

(define-public (initiate-validation (report-id uint) (estimated-severity uint))
  (let (
    (session-id (var-get next-session-id))
    (reward-pool (* estimated-severity REWARD_MULTIPLIER))
  )
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (>= (var-get active-validators) VALIDATION_THRESHOLD) ERR_INSUFFICIENT_STAKE)
    
    ;; Create validation session
    (map-set validation-sessions
      { session-id: session-id }
      {
        report-id: report-id,
        initiator: tx-sender,
        status: "active",
        validator-count: u0,
        approval-count: u0,
        rejection-count: u0,
        total-stake: u0,
        reward-pool: reward-pool,
        created-at: stacks-block-height,
        deadline: (+ stacks-block-height VALIDATION_PERIOD),
        finalized: false
      }
    )
    
    ;; Update counters
    (var-set next-session-id (+ session-id u1))
    (var-set total-reward-pool (+ (var-get total-reward-pool) reward-pool))
    
    (print {
      event: "validation-initiated",
      session-id: session-id,
      report-id: report-id,
      initiator: tx-sender,
      reward-pool: reward-pool
    })
    
    (ok session-id)
  )
)

(define-public (submit-validation (session-id uint) (vote (string-ascii 10)))
  (let (
    (session (unwrap! (map-get? validation-sessions { session-id: session-id }) ERR_NOT_FOUND))
    (validator-info (unwrap! (map-get? validators { validator: tx-sender }) ERR_UNAUTHORIZED))
  )
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (is-qualified-validator tx-sender) ERR_UNAUTHORIZED)
    (asserts! (not (get finalized session)) ERR_ALREADY_VERIFIED)
    (asserts! (<= stacks-block-height (get deadline session)) ERR_VALIDATION_ENDED)
    (asserts! (is-none (map-get? validator-votes { session-id: session-id, validator: tx-sender })) ERR_ALREADY_EXISTS)
    (asserts! (or (is-eq vote "approve") (is-eq vote "reject")) ERR_INVALID_AMOUNT)
    
    ;; Record vote
    (map-set validator-votes
      { session-id: session-id, validator: tx-sender }
      {
        vote: vote,
        stake-amount: (get stake-amount validator-info),
        timestamp: stacks-block-height,
        rewarded: false
      }
    )
    
    ;; Update session counts
    (map-set validation-sessions
      { session-id: session-id }
      (merge session {
        validator-count: (+ (get validator-count session) u1),
        approval-count: (if (is-eq vote "approve") 
                           (+ (get approval-count session) u1)
                           (get approval-count session)),
        rejection-count: (if (is-eq vote "reject") 
                            (+ (get rejection-count session) u1)
                            (get rejection-count session)),
        total-stake: (+ (get total-stake session) (get stake-amount validator-info))
      })
    )
    
    ;; Update validator activity
    (map-set validators
      { validator: tx-sender }
      (merge validator-info { last-activity: stacks-block-height })
    )
    
    (print {
      event: "validation-submitted",
      session-id: session-id,
      validator: tx-sender,
      vote: vote,
      stake-amount: (get stake-amount validator-info)
    })
    
    (ok true)
  )
)

(define-public (submit-evidence 
    (session-id uint) 
    (evidence-hash (buff 32)) 
    (evidence-type (string-ascii 30)))
  (let (
    (evidence-id (var-get next-evidence-id))
    (session (unwrap! (map-get? validation-sessions { session-id: session-id }) ERR_NOT_FOUND))
  )
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (not (get finalized session)) ERR_ALREADY_VERIFIED)
    (asserts! (<= stacks-block-height (get deadline session)) ERR_VALIDATION_ENDED)
    
    ;; Record evidence
    (map-set evidence-submissions
      { evidence-id: evidence-id }
      {
        session-id: session-id,
        submitter: tx-sender,
        evidence-hash: evidence-hash,
        evidence-type: evidence-type,
        credibility-score: u100,
        verified: false,
        timestamp: stacks-block-height
      }
    )
    
    ;; Update counter
    (var-set next-evidence-id (+ evidence-id u1))
    
    (print {
      event: "evidence-submitted",
      evidence-id: evidence-id,
      session-id: session-id,
      submitter: tx-sender,
      evidence-type: evidence-type
    })
    
    (ok evidence-id)
  )
)

(define-public (finalize-validation (session-id uint))
  (let (
    (session (unwrap! (map-get? validation-sessions { session-id: session-id }) ERR_NOT_FOUND))
  )
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (not (get finalized session)) ERR_ALREADY_VERIFIED)
    (asserts! (or (> stacks-block-height (get deadline session))
                  (>= (get validator-count session) VALIDATION_THRESHOLD)) ERR_VALIDATION_ENDED)
    
    ;; Determine result
    (let (
      (approved (> (get approval-count session) (get rejection-count session)))
      (final-status (if approved "approved" "rejected"))
    )
      ;; Update session
      (map-set validation-sessions
        { session-id: session-id }
        (merge session { 
          status: final-status,
          finalized: true
        })
      )
      
      (print {
        event: "validation-finalized",
        session-id: session-id,
        status: final-status,
        approval-count: (get approval-count session),
        rejection-count: (get rejection-count session)
      })
      
      (ok final-status)
    )
  )
)

(define-public (claim-validator-reward (session-id uint))
  (let (
    (session (unwrap! (map-get? validation-sessions { session-id: session-id }) ERR_NOT_FOUND))
    (vote-info (unwrap! (map-get? validator-votes { session-id: session-id, validator: tx-sender }) ERR_NOT_FOUND))
    (validator-info (unwrap! (map-get? validators { validator: tx-sender }) ERR_NOT_FOUND))
  )
    (asserts! (get finalized session) ERR_VALIDATION_ENDED)
    (asserts! (not (get rewarded vote-info)) ERR_ALREADY_EXISTS)
    
    ;; Calculate reward based on correctness
    (let (
      (was-correct (is-eq (get vote vote-info) (get status session)))
      (base-reward (calculate-reward-amount u5 (get validator-count session)))
      (final-reward (if was-correct base-reward u0))
    )
      (begin
        ;; Update validator reputation first
        (update-validator-reputation tx-sender was-correct)
        
        ;; Handle reward distribution
        (if (> final-reward u0)
            (begin
              ;; Mark as rewarded
              (map-set validator-votes
                { session-id: session-id, validator: tx-sender }
                (merge vote-info { rewarded: true })
              )
              
              ;; Record reward claim
              (map-set reward-claims
                { claimant: tx-sender, session-id: session-id }
                { amount: final-reward, claimed: true, claim-type: "validator" }
              )
              
              (print {
                event: "validator-reward-claimed",
                validator: tx-sender,
                session-id: session-id,
                reward-amount: final-reward
              })
              true
            )
            (begin
              (print {
                event: "validator-no-reward",
                validator: tx-sender,
                session-id: session-id,
                reason: "incorrect-vote"
              })
              true
            )
        )
      )
      
      (ok final-reward)
    )
  )
)

(define-public (deactivate-validator)
  (let (
    (validator-info (unwrap! (map-get? validators { validator: tx-sender }) ERR_NOT_FOUND))
  )
    (asserts! (get active validator-info) ERR_UNAUTHORIZED)
    
    ;; Deactivate validator
    (map-set validators
      { validator: tx-sender }
      (merge validator-info { active: false, last-activity: stacks-block-height })
    )
    
    ;; Update counters
    (var-set total-validator-pool (- (var-get total-validator-pool) (get stake-amount validator-info)))
    (var-set active-validators (- (var-get active-validators) u1))
    
    (print {
      event: "validator-deactivated",
      validator: tx-sender,
      stake-returned: (get stake-amount validator-info)
    })
    
    (ok true)
  )
)

(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set contract-paused true)
    
    (print { event: "contract-paused", owner: tx-sender })
    (ok true)
  )
)

(define-public (resume-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set contract-paused false)
    
    (print { event: "contract-resumed", owner: tx-sender })
    (ok true)
  )
)

