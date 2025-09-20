(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_LOAN_NOT_FOUND (err u102))
(define-constant ERR_LOAN_ALREADY_REPAID (err u103))
(define-constant ERR_LOAN_NOT_DUE (err u104))
(define-constant ERR_INVALID_AMOUNT (err u105))
(define-constant ERR_MEMBER_NOT_FOUND (err u106))
(define-constant ERR_ALREADY_MEMBER (err u107))
(define-constant ERR_INSUFFICIENT_REPUTATION (err u108))
(define-constant ERR_LOAN_OVERDUE (err u109))
(define-constant ERR_PROPOSAL_NOT_FOUND (err u110))
(define-constant ERR_PROPOSAL_EXPIRED (err u111))
(define-constant ERR_PROPOSAL_ALREADY_EXECUTED (err u112))
(define-constant ERR_ALREADY_VOTED_ON_PROPOSAL (err u113))
(define-constant ERR_PROPOSAL_NOT_READY (err u114))
(define-constant ERR_INVALID_REFERRER (err u115))
(define-constant ERR_SELF_REFERRAL (err u116))
(define-constant ERR_CRISIS_MODE_ACTIVE (err u117))

(define-constant CRISIS_THRESHOLD_HIGH u80)
(define-constant CRISIS_THRESHOLD_MEDIUM u60)
(define-constant CRISIS_MULTIPLIER_HIGH u150)
(define-constant CRISIS_MULTIPLIER_MEDIUM u125)

(define-data-var next-loan-id uint u1)
(define-data-var next-proposal-id uint u1)
(define-data-var proposal-duration-blocks uint u1008)
(define-data-var governance-quorum uint u5)
(define-data-var total-pool-balance uint u0)
(define-data-var min-reputation-score uint u50)
(define-data-var max-loan-amount uint u10000)
(define-data-var loan-duration-blocks uint u1440)
(define-data-var crisis-mode-active bool false)
(define-data-var crisis-detection-block uint u0)

(define-map dao-members principal {
    reputation-score: uint,
    total-borrowed: uint,
    total-repaid: uint,
    active-loans: uint,
    join-block: uint,
    referrer: (optional principal),
    referral-count: uint
})

(define-map loans uint {
    borrower: principal,
    amount: uint,
    due-block: uint,
    repaid: bool,
    created-block: uint,
    interest-rate: uint
})

(define-map member-contributions principal uint)
(define-map loan-votes {loan-id: uint, voter: principal} bool)
(define-map loan-approval-count uint uint)

(define-map governance-proposals uint {
    proposer: principal,
    parameter: (string-ascii 32),
    new-value: uint,
    start-block: uint,
    end-block: uint,
    executed: bool,
    description: (string-ascii 256)
})

(define-map proposal-votes {proposal-id: uint, voter: principal} bool)
(define-map proposal-vote-count uint {yes: uint, no: uint})

(define-public (join-dao)
    (let ((caller tx-sender))
        (match (map-get? dao-members caller)
            existing-member ERR_ALREADY_MEMBER
            (begin
                (map-set dao-members caller {
                    reputation-score: u100,
                    total-borrowed: u0,
                    total-repaid: u0,
                    active-loans: u0,
                    join-block: stacks-block-height,
                    referrer: none,
                    referral-count: u0
                })
                (ok true)
            )
        )
    )
)

(define-public (join-dao-with-referral (referrer-address principal))
    (let ((caller tx-sender))
        (asserts! (not (is-eq caller referrer-address)) ERR_SELF_REFERRAL)
        (asserts! (is-some (map-get? dao-members referrer-address)) ERR_INVALID_REFERRER)
        
        (match (map-get? dao-members caller)
            existing-member ERR_ALREADY_MEMBER
            (begin
                (map-set dao-members caller {
                    reputation-score: u110,
                    total-borrowed: u0,
                    total-repaid: u0,
                    active-loans: u0,
                    join-block: stacks-block-height,
                    referrer: (some referrer-address),
                    referral-count: u0
                })
                (update-referrer-count referrer-address)
                (update-member-reputation referrer-address 25)
                (ok true)
            )
        )
    )
)

(define-public (contribute-to-pool (amount uint))
    (let ((caller tx-sender))
        (if (> amount u0)
            (begin
                (try! (stx-transfer? amount caller (as-contract tx-sender)))
                (var-set total-pool-balance (+ (var-get total-pool-balance) amount))
                (map-set member-contributions caller 
                    (+ (default-to u0 (map-get? member-contributions caller)) amount))
                (update-member-reputation caller (to-int u10))
                (ok true)
            )
            ERR_INVALID_AMOUNT
        )
    )
)

(define-public (request-loan (amount uint))
    (let (
        (caller tx-sender)
        (loan-id (var-get next-loan-id))
        (member-data (unwrap! (map-get? dao-members caller) ERR_MEMBER_NOT_FOUND))
        (crisis-adjusted-limits (get-crisis-adjusted-limits))
    )
        (check-and-update-crisis-mode)
        (asserts! (>= (get reputation-score member-data) (get min-reputation crisis-adjusted-limits)) ERR_INSUFFICIENT_REPUTATION)
        (asserts! (<= amount (get max-loan crisis-adjusted-limits)) ERR_INVALID_AMOUNT)
        (asserts! (>= (var-get total-pool-balance) amount) ERR_INSUFFICIENT_BALANCE)
        (asserts! (< (get active-loans member-data) u3) ERR_NOT_AUTHORIZED)
        
        (map-set loans loan-id {
            borrower: caller,
            amount: amount,
            due-block: (+ stacks-block-height (var-get loan-duration-blocks)),
            repaid: false,
            created-block: stacks-block-height,
            interest-rate: (get-crisis-interest-rate)
        })
        
        (map-set loan-approval-count loan-id u0)
        (var-set next-loan-id (+ loan-id u1))
        (ok loan-id)
    )
)

(define-public (vote-on-loan (loan-id uint) (approve bool))
    (let (
        (caller tx-sender)
        (member-data (unwrap! (map-get? dao-members caller) ERR_MEMBER_NOT_FOUND))
        (loan-data (unwrap! (map-get? loans loan-id) ERR_LOAN_NOT_FOUND))
    )
        (asserts! (>= (get reputation-score member-data) u75) ERR_INSUFFICIENT_REPUTATION)
        (asserts! (not (get repaid loan-data)) ERR_LOAN_ALREADY_REPAID)
        (asserts! (is-none (map-get? loan-votes {loan-id: loan-id, voter: caller})) ERR_NOT_AUTHORIZED)
        
        (map-set loan-votes {loan-id: loan-id, voter: caller} approve)
        
        (if approve
            (map-set loan-approval-count loan-id 
                (+ (default-to u0 (map-get? loan-approval-count loan-id)) u1))
            true
        )
        (ok true)
    )
)

(define-public (approve-loan (loan-id uint))
    (let (
        (loan-data (unwrap! (map-get? loans loan-id) ERR_LOAN_NOT_FOUND))
        (approval-count (default-to u0 (map-get? loan-approval-count loan-id)))
        (borrower (get borrower loan-data))
        (amount (get amount loan-data))
    )
        (asserts! (>= approval-count u3) ERR_NOT_AUTHORIZED)
        (asserts! (>= (var-get total-pool-balance) amount) ERR_INSUFFICIENT_BALANCE)
        
        (try! (as-contract (stx-transfer? amount tx-sender borrower)))
        (var-set total-pool-balance (- (var-get total-pool-balance) amount))
        
        (update-member-active-loans borrower 1)
        (update-member-total-borrowed borrower amount)
        (ok true)
    )
)

(define-public (repay-loan (loan-id uint))
    (let (
        (caller tx-sender)
        (loan-data (unwrap! (map-get? loans loan-id) ERR_LOAN_NOT_FOUND))
        (amount (get amount loan-data))
        (interest (/ (* amount (get interest-rate loan-data)) u100))
        (total-repayment (+ amount interest))
    )
        (asserts! (is-eq caller (get borrower loan-data)) ERR_NOT_AUTHORIZED)
        (asserts! (not (get repaid loan-data)) ERR_LOAN_ALREADY_REPAID)
        
        (try! (stx-transfer? total-repayment caller (as-contract tx-sender)))
        
        (map-set loans loan-id (merge loan-data {repaid: true}))
        (var-set total-pool-balance (+ (var-get total-pool-balance) total-repayment))
        
        (update-member-active-loans caller -1)
        (update-member-total-repaid caller total-repayment)
        
        (if (<= stacks-block-height (get due-block loan-data))
            (update-member-reputation caller 20)
            (update-member-reputation caller -10)
        )
        (ok true)
    )
)

(define-public (liquidate-overdue-loan (loan-id uint))
    (let (
        (loan-data (unwrap! (map-get? loans loan-id) ERR_LOAN_NOT_FOUND))
        (borrower (get borrower loan-data))
    )
        (asserts! (> stacks-block-height (get due-block loan-data)) ERR_LOAN_NOT_DUE)
        (asserts! (not (get repaid loan-data)) ERR_LOAN_ALREADY_REPAID)
        
        (update-member-reputation borrower -50)
        (update-member-active-loans borrower -1)
        (map-set loans loan-id (merge loan-data {repaid: true}))
        (ok true)
    )
)

(define-public (withdraw-contribution (amount uint))
    (let (
        (caller tx-sender)
        (contribution (default-to u0 (map-get? member-contributions caller)))
    )
        (asserts! (>= contribution amount) ERR_INSUFFICIENT_BALANCE)
        (asserts! (>= (var-get total-pool-balance) amount) ERR_INSUFFICIENT_BALANCE)
        
        (try! (as-contract (stx-transfer? amount tx-sender caller)))
        (var-set total-pool-balance (- (var-get total-pool-balance) amount))
        (map-set member-contributions caller (- contribution amount))
        (ok true)
    )
)

(define-private (update-member-reputation (member principal) (change int))
    (match (map-get? dao-members member)
        member-data 
        (let ((current-rep (get reputation-score member-data)))
            (map-set dao-members member 
                (merge member-data {
                    reputation-score: (if (< change 0)
                        (if (> (to-uint (- change)) current-rep) u0 (- current-rep (to-uint (- change))))
                        (+ current-rep (to-uint change))
                    )
                })
            )
        )
        false
    )
)

(define-private (update-member-active-loans (member principal) (change int))
    (match (map-get? dao-members member)
        member-data 
        (let ((current-loans (get active-loans member-data)))
            (map-set dao-members member 
                (merge member-data {
                    active-loans: (if (< change 0)
                        (if (> (to-uint (- change)) current-loans) u0 (- current-loans (to-uint (- change))))
                        (+ current-loans (to-uint change))
                    )
                })
            )
        )
        false
    )
)

(define-private (update-member-total-borrowed (member principal) (amount uint))
    (match (map-get? dao-members member)
        member-data 
        (map-set dao-members member 
            (merge member-data {total-borrowed: (+ (get total-borrowed member-data) amount)})
        )
        false
    )
)

(define-private (update-member-total-repaid (member principal) (amount uint))
    (match (map-get? dao-members member)
        member-data 
        (map-set dao-members member 
            (merge member-data {total-repaid: (+ (get total-repaid member-data) amount)})
        )
        false
    )
)

(define-private (update-referrer-count (referrer principal))
    (match (map-get? dao-members referrer)
        member-data 
        (map-set dao-members referrer 
            (merge member-data {referral-count: (+ (get referral-count member-data) u1)})
        )
        false
    )
)

(define-private (calculate-pool-utilization)
    (let (
        (total-balance (var-get total-pool-balance))
        (total-contributions (fold + (map get-member-contribution-for-calc (list tx-sender)) u0))
    )
        (if (> total-contributions u0)
            (/ (* (- total-contributions total-balance) u100) total-contributions)
            u0
        )
    )
)

(define-private (get-member-contribution-for-calc (member principal))
    (default-to u0 (map-get? member-contributions member))
)

(define-private (check-and-update-crisis-mode)
    (let ((utilization (calculate-pool-utilization)))
        (if (>= utilization CRISIS_THRESHOLD_HIGH)
            (begin
                (var-set crisis-mode-active true)
                (var-set crisis-detection-block stacks-block-height)
                true
            )
            (if (and (var-get crisis-mode-active) 
                     (< utilization u30) 
                     (> stacks-block-height (+ (var-get crisis-detection-block) u144)))
                (begin
                    (var-set crisis-mode-active false)
                    (var-set crisis-detection-block u0)
                    true
                )
                true
            )
        )
    )
)

(define-private (get-crisis-adjusted-limits)
    (let ((utilization (calculate-pool-utilization)))
        (if (var-get crisis-mode-active)
            (if (>= utilization CRISIS_THRESHOLD_HIGH)
                {
                    min-reputation: (/ (* (var-get min-reputation-score) CRISIS_MULTIPLIER_HIGH) u100),
                    max-loan: (/ (* (var-get max-loan-amount) u100) CRISIS_MULTIPLIER_HIGH)
                }
                {
                    min-reputation: (/ (* (var-get min-reputation-score) CRISIS_MULTIPLIER_MEDIUM) u100),
                    max-loan: (/ (* (var-get max-loan-amount) u100) CRISIS_MULTIPLIER_MEDIUM)
                }
            )
            {
                min-reputation: (var-get min-reputation-score),
                max-loan: (var-get max-loan-amount)
            }
        )
    )
)

(define-private (get-crisis-interest-rate)
    (let ((utilization (calculate-pool-utilization)))
        (if (var-get crisis-mode-active)
            (if (>= utilization CRISIS_THRESHOLD_HIGH)
                u15
                u10
            )
            u5
        )
    )
)

(define-read-only (get-member-info (member principal))
    (map-get? dao-members member)
)

(define-read-only (get-loan-info (loan-id uint))
    (map-get? loans loan-id)
)

(define-read-only (get-pool-balance)
    (var-get total-pool-balance)
)

(define-read-only (get-member-contribution (member principal))
    (default-to u0 (map-get? member-contributions member))
)

(define-read-only (get-loan-approval-count (loan-id uint))
    (default-to u0 (map-get? loan-approval-count loan-id))
)

(define-read-only (has-voted (loan-id uint) (voter principal))
    (is-some (map-get? loan-votes {loan-id: loan-id, voter: voter}))
)

(define-public (create-governance-proposal (parameter (string-ascii 32)) (new-value uint) (description (string-ascii 256)))
    (let (
        (caller tx-sender)
        (proposal-id (var-get next-proposal-id))
        (member-data (unwrap! (map-get? dao-members caller) ERR_MEMBER_NOT_FOUND))
    )
        (asserts! (>= (get reputation-score member-data) u150) ERR_INSUFFICIENT_REPUTATION)
        
        (map-set governance-proposals proposal-id {
            proposer: caller,
            parameter: parameter,
            new-value: new-value,
            start-block: stacks-block-height,
            end-block: (+ stacks-block-height (var-get proposal-duration-blocks)),
            executed: false,
            description: description
        })
        
        (map-set proposal-vote-count proposal-id {yes: u0, no: u0})
        (var-set next-proposal-id (+ proposal-id u1))
        (ok proposal-id)
    )
)

(define-public (vote-on-proposal (proposal-id uint) (support bool))
    (let (
        (caller tx-sender)
        (member-data (unwrap! (map-get? dao-members caller) ERR_MEMBER_NOT_FOUND))
        (proposal-data (unwrap! (map-get? governance-proposals proposal-id) ERR_PROPOSAL_NOT_FOUND))
        (current-votes (unwrap! (map-get? proposal-vote-count proposal-id) ERR_PROPOSAL_NOT_FOUND))
    )
        (asserts! (>= (get reputation-score member-data) u100) ERR_INSUFFICIENT_REPUTATION)
        (asserts! (<= stacks-block-height (get end-block proposal-data)) ERR_PROPOSAL_EXPIRED)
        (asserts! (is-none (map-get? proposal-votes {proposal-id: proposal-id, voter: caller})) ERR_ALREADY_VOTED_ON_PROPOSAL)
        
        (map-set proposal-votes {proposal-id: proposal-id, voter: caller} support)
        
        (if support
            (map-set proposal-vote-count proposal-id 
                (merge current-votes {yes: (+ (get yes current-votes) u1)}))
            (map-set proposal-vote-count proposal-id 
                (merge current-votes {no: (+ (get no current-votes) u1)}))
        )
        (ok true)
    )
)

(define-public (execute-proposal (proposal-id uint))
    (let (
        (proposal-data (unwrap! (map-get? governance-proposals proposal-id) ERR_PROPOSAL_NOT_FOUND))
        (vote-count (unwrap! (map-get? proposal-vote-count proposal-id) ERR_PROPOSAL_NOT_FOUND))
        (yes-votes (get yes vote-count))
        (no-votes (get no vote-count))
        (total-votes (+ yes-votes no-votes))
    )
        (asserts! (> stacks-block-height (get end-block proposal-data)) ERR_PROPOSAL_NOT_READY)
        (asserts! (not (get executed proposal-data)) ERR_PROPOSAL_ALREADY_EXECUTED)
        (asserts! (>= total-votes (var-get governance-quorum)) ERR_NOT_AUTHORIZED)
        (asserts! (> yes-votes no-votes) ERR_NOT_AUTHORIZED)
        
        (map-set governance-proposals proposal-id 
            (merge proposal-data {executed: true}))
        
        (let ((parameter (get parameter proposal-data))
              (new-value (get new-value proposal-data)))
            (if (is-eq parameter "min-reputation-score")
                (var-set min-reputation-score new-value)
                (if (is-eq parameter "max-loan-amount")
                    (var-set max-loan-amount new-value)
                    (if (is-eq parameter "loan-duration-blocks")
                        (var-set loan-duration-blocks new-value)
                        (if (is-eq parameter "governance-quorum")
                            (var-set governance-quorum new-value)
                            (if (is-eq parameter "proposal-duration-blocks")
                                (var-set proposal-duration-blocks new-value)
                                false
                            )
                        )
                    )
                )
            )
        )
        (ok true)
    )
)

(define-read-only (get-proposal-info (proposal-id uint))
    (map-get? governance-proposals proposal-id)
)

(define-read-only (get-proposal-votes (proposal-id uint))
    (map-get? proposal-vote-count proposal-id)
)

(define-read-only (has-voted-on-proposal (proposal-id uint) (voter principal))
    (is-some (map-get? proposal-votes {proposal-id: proposal-id, voter: voter}))
)

(define-read-only (get-member-referrals (member principal))
    (match (map-get? dao-members member)
        member-data (some (get referral-count member-data))
        none
    )
)

(define-read-only (get-member-referrer (member principal))
    (match (map-get? dao-members member)
        member-data (get referrer member-data)
        none
    )
)

(define-read-only (get-contract-info)
    {
        total-pool-balance: (var-get total-pool-balance),
        next-loan-id: (var-get next-loan-id),
        next-proposal-id: (var-get next-proposal-id),
        min-reputation-score: (var-get min-reputation-score),
        max-loan-amount: (var-get max-loan-amount),
        loan-duration-blocks: (var-get loan-duration-blocks),
        proposal-duration-blocks: (var-get proposal-duration-blocks),
        governance-quorum: (var-get governance-quorum)
    }
)

(define-read-only (get-crisis-status)
    {
        crisis-active: (var-get crisis-mode-active),
        pool-utilization: (calculate-pool-utilization),
        crisis-detection-block: (var-get crisis-detection-block),
        current-interest-rate: (get-crisis-interest-rate),
        adjusted-limits: (get-crisis-adjusted-limits)
    }
)

