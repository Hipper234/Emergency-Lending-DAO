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

(define-data-var next-loan-id uint u1)
(define-data-var total-pool-balance uint u0)
(define-data-var min-reputation-score uint u50)
(define-data-var max-loan-amount uint u10000)
(define-data-var loan-duration-blocks uint u1440)

(define-map dao-members principal {
    reputation-score: uint,
    total-borrowed: uint,
    total-repaid: uint,
    active-loans: uint,
    join-block: uint
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
                    join-block: stacks-block-height
                })
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
    )
        (asserts! (>= (get reputation-score member-data) (var-get min-reputation-score)) ERR_INSUFFICIENT_REPUTATION)
        (asserts! (<= amount (var-get max-loan-amount)) ERR_INVALID_AMOUNT)
        (asserts! (>= (var-get total-pool-balance) amount) ERR_INSUFFICIENT_BALANCE)
        (asserts! (< (get active-loans member-data) u3) ERR_NOT_AUTHORIZED)
        
        (map-set loans loan-id {
            borrower: caller,
            amount: amount,
            due-block: (+ stacks-block-height (var-get loan-duration-blocks)),
            repaid: false,
            created-block: stacks-block-height,
            interest-rate: u5
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

(define-read-only (get-contract-info)
    {
        total-pool-balance: (var-get total-pool-balance),
        next-loan-id: (var-get next-loan-id),
        min-reputation-score: (var-get min-reputation-score),
        max-loan-amount: (var-get max-loan-amount),
        loan-duration-blocks: (var-get loan-duration-blocks)
    }
)

