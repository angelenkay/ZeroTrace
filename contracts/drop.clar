;; ZeroTrace - Anonymous Whistleblowing Platform
;; Enables anonymous submission of sensitive information with cryptographic proof

;; Contract constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-invalid-submission (err u101))
(define-constant err-submission-not-found (err u102))
(define-constant err-already-verified (err u103))
(define-constant err-invalid-proof (err u104))
(define-constant err-unauthorized (err u105))

;; Data structures
(define-map submissions
  { submission-id: uint }
  {
    content-hash: (buff 32),           ;; SHA256 hash of the content
    commitment-hash: (buff 32),        ;; Hash of (content + nonce) for privacy
    timestamp: uint,
    category: (string-ascii 64),       ;; e.g., "corporate", "government", "healthcare"
    severity: uint,                    ;; 1-5 scale
    is-verified: bool,
    verifier: (optional principal),
    metadata-hash: (buff 32),          ;; Hash of additional metadata
    reward-claimed: bool
  }
)

;; Track verified journalists/organizations
(define-map verified-verifiers
  { verifier: principal }
  {
    organization: (string-ascii 128),
    verification-date: uint,
    reputation-score: uint
  }
)

;; Track submission statistics
(define-data-var total-submissions uint u0)
(define-data-var verified-submissions uint u0)

;; Reward pool for verified submissions
(define-data-var reward-pool uint u0)

;; Events for off-chain indexing
(define-map submission-events
  { event-id: uint }
  {
    event-type: (string-ascii 32),
    submission-id: uint,
    timestamp: uint,
    data-hash: (buff 32)
  }
)

(define-data-var event-counter uint u0)

;; Submit anonymous information
(define-public (submit-information 
  (content-hash (buff 32))
  (commitment-hash (buff 32))
  (category (string-ascii 64))
  (severity uint)
  (metadata-hash (buff 32)))
  
  (let ((submission-id (+ (var-get total-submissions) u1)))
    
    ;; Validate inputs
    (asserts! (and (> severity u0) (<= severity u5)) err-invalid-submission)
    (asserts! (> (len category) u0) err-invalid-submission)
    
    ;; Store submission
    (map-set submissions
      { submission-id: submission-id }
      {
        content-hash: content-hash,
        commitment-hash: commitment-hash,
        timestamp: block-height,
        category: category,
        severity: severity,
        is-verified: false,
        verifier: none,
        metadata-hash: metadata-hash,
        reward-claimed: false
      }
    )
    
    ;; Update counters
    (var-set total-submissions submission-id)
    
    ;; Emit event
    (log-submission-event "SUBMITTED" submission-id content-hash)
    
    (ok submission-id)
  )
)

;; Verify a submission (only by verified verifiers)
(define-public (verify-submission 
  (submission-id uint)
  (proof-hash (buff 32)))
  
  (let ((submission (unwrap! (map-get? submissions { submission-id: submission-id }) err-submission-not-found))
        (verifier-info (unwrap! (map-get? verified-verifiers { verifier: tx-sender }) err-unauthorized)))
    
    ;; Check if already verified
    (asserts! (not (get is-verified submission)) err-already-verified)
    
    ;; Update submission
    (map-set submissions
      { submission-id: submission-id }
      (merge submission {
        is-verified: true,
        verifier: (some tx-sender)
      })
    )
    
    ;; Update verified counter
    (var-set verified-submissions (+ (var-get verified-submissions) u1))
    
    ;; Update verifier reputation
    (map-set verified-verifiers
      { verifier: tx-sender }
      (merge verifier-info {
        reputation-score: (+ (get reputation-score verifier-info) u1)
      })
    )
    
    ;; Emit event
    (log-submission-event "VERIFIED" submission-id proof-hash)
    
    (ok true)
  )
)

;; Add verified verifier/journalist (owner only)
(define-public (add-verified-verifier 
  (verifier principal)
  (organization (string-ascii 128)))
  
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (map-set verified-verifiers
      { verifier: verifier }
      {
        organization: organization,
        verification-date: block-height,
        reputation-score: u0
      }
    )
    
    (ok true)
  )
)

;; Claim reward for verified submission
(define-public (claim-reward (submission-id uint) (reveal-nonce (buff 32)))
  (let ((submission (unwrap! (map-get? submissions { submission-id: submission-id }) err-submission-not-found))
        (reward-amount (calculate-reward (get severity submission))))
    
    ;; Verify the submission is verified and reward not claimed
    (asserts! (get is-verified submission) err-invalid-proof)
    (asserts! (not (get reward-claimed submission)) err-invalid-proof)
    
    ;; Verify commitment (simplified - in production would need more sophisticated proof)
    (asserts! (is-eq (get commitment-hash submission) 
                     (sha256 (concat (get content-hash submission) reveal-nonce))) 
              err-invalid-proof)
    
    ;; Mark reward as claimed
    (map-set submissions
      { submission-id: submission-id }
      (merge submission { reward-claimed: true })
    )
    
    ;; Transfer reward (if pool has funds)
    (if (>= (var-get reward-pool) reward-amount)
      (begin
        (var-set reward-pool (- (var-get reward-pool) reward-amount))
        (try! (stx-transfer? reward-amount (as-contract tx-sender) tx-sender))
        (ok reward-amount)
      )
      (ok u0)
    )
  )
)

;; Fund the reward pool
(define-public (fund-reward-pool (amount uint))
  (begin
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set reward-pool (+ (var-get reward-pool) amount))
    (ok true)
  )
)

;; Helper function to calculate reward based on severity
(define-private (calculate-reward (severity uint))
  (if (is-eq severity u5)
    u1000000  ;; 1 STX for highest severity
    (if (is-eq severity u4)
      u500000   ;; 0.5 STX
      (if (is-eq severity u3)
        u250000 ;; 0.25 STX
        u100000 ;; 0.1 STX for lower severity
      )
    )
  )
)

;; Log events for off-chain tracking
(define-private (log-submission-event 
  (event-type (string-ascii 32))
  (submission-id uint)
  (data-hash (buff 32)))
  
  (let ((event-id (+ (var-get event-counter) u1)))
    (map-set submission-events
      { event-id: event-id }
      {
        event-type: event-type,
        submission-id: submission-id,
        timestamp: block-height,
        data-hash: data-hash
      }
    )
    (var-set event-counter event-id)
    event-id
  )
)

;; Read-only functions

;; Get submission details (without revealing sensitive info)
(define-read-only (get-submission-info (submission-id uint))
  (match (map-get? submissions { submission-id: submission-id })
    submission (ok {
      timestamp: (get timestamp submission),
      category: (get category submission),
      severity: (get severity submission),
      is-verified: (get is-verified submission),
      verifier: (get verifier submission)
    })
    err-submission-not-found
  )
)

;; Get verifier information
(define-read-only (get-verifier-info (verifier principal))
  (map-get? verified-verifiers { verifier: verifier })
)

;; Get platform statistics
(define-read-only (get-platform-stats)
  (ok {
    total-submissions: (var-get total-submissions),
    verified-submissions: (var-get verified-submissions),
    reward-pool: (var-get reward-pool),
    verification-rate: (if (> (var-get total-submissions) u0)
                        (/ (* (var-get verified-submissions) u100) (var-get total-submissions))
                        u0)
  })
)

;; Check if user is verified verifier
(define-read-only (is-verified-verifier (verifier principal))
  (is-some (map-get? verified-verifiers { verifier: verifier }))
)

;; Get submission by category (for public browsing)
(define-read-only (get-submissions-by-category (category (string-ascii 64)))
  ;; This would need to be implemented with a more complex indexing system
  ;; For now, returns basic info
  (ok "Use off-chain indexing for category filtering")
)

;; Verify content hash matches commitment
(define-read-only (verify-commitment 
  (submission-id uint)
  (content (buff 1024))
  (nonce (buff 32)))
  
  (match (map-get? submissions { submission-id: submission-id })
    submission 
      (let ((computed-content-hash (sha256 content))
            (computed-commitment (sha256 (concat computed-content-hash nonce))))
        (and 
          (is-eq computed-content-hash (get content-hash submission))
          (is-eq computed-commitment (get commitment-hash submission))
        )
      )
    false
  )
)