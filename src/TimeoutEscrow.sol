// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";

/// @title TimeoutEscrow
/// @notice A buyer escrows SHAKE for a seller with a deadline. The buyer may release the whole
///         amount to the seller at any time. If the buyer neither releases nor disputes by the
///         deadline, the seller claims the whole amount. A dispute raised by the buyer before the
///         deadline settles the escrow by splitting it evenly between the two parties.
/// @dev Design constraints held deliberately:
///      - one constructor argument, the token, stored immutable: no fee, owner, admin, pause,
///        upgrade path, or any privileged role whatsoever. Nothing about a live escrow can be
///        changed by anyone other than its own buyer and seller;
///      - the only external calls are `transfer`/`transferFrom` on that one immutable token;
///      - every state change emits an event;
///      - checks-effects-interactions everywhere. `release`, `dispute` and `claim` write the
///        escrow's terminal status before they move any tokens, so a re-entrant call from a hostile
///        token sees a settled escrow and reverts with {EscrowNotOpen}. `open` is the mirror image:
///        it pulls the tokens *before* it records the escrow, so a re-entrant call cannot settle an
///        escrow that is not funded yet;
///      - amounts are per-escrow. The contract never consults its own balance, so a stray token
///        transfer to this address cannot be withdrawn by anyone and cannot affect any payout.
contract TimeoutEscrow {
    /// @notice Lifecycle of a single escrow. `None` means "no such escrow".
    /// @dev `Released`, `Claimed` and `Disputed` are all terminal: an escrow is settled exactly once.
    enum Status {
        None,
        Open,
        Released,
        Claimed,
        Disputed
    }

    /// @param buyer The account that funded the escrow and may release or dispute it.
    /// @param deadline Unix seconds. Disputing is allowed strictly before it; claiming at or after it.
    /// @param status Current lifecycle position.
    /// @param seller The account the escrow is held for.
    /// @param amount The token amount held, in minor units. Never mutated after {open}.
    struct Escrow {
        address buyer;
        uint64 deadline;
        Status status;
        address seller;
        uint256 amount;
    }

    /// @notice Thrown when the token address given to the constructor is the zero address.
    error ZeroToken();
    /// @notice Thrown when the seller is the zero address or the buyer itself.
    error InvalidSeller();
    /// @notice Thrown when an escrow is opened for zero tokens.
    error ZeroAmount();
    /// @notice Thrown when the deadline is not strictly in the future at {open}.
    error DeadlineNotInFuture(uint64 deadline, uint256 nowTimestamp);
    /// @notice Thrown when the escrow does not exist or has already been settled.
    error EscrowNotOpen(uint256 id);
    /// @notice Thrown when someone other than the escrow's buyer calls a buyer-only function.
    error NotBuyer(uint256 id, address caller);
    /// @notice Thrown when someone other than the escrow's seller calls a seller-only function.
    error NotSeller(uint256 id, address caller);
    /// @notice Thrown when a dispute is raised at or after the deadline.
    error DeadlinePassed(uint256 id, uint64 deadline);
    /// @notice Thrown when a claim is attempted before the deadline.
    error DeadlineNotReached(uint256 id, uint64 deadline);
    /// @notice Thrown when the token reverts, returns false, or is not a contract.
    error TokenTransferFailed();
    /// @notice Thrown when a paged view is asked for a range outside the escrow list.
    error InvalidRange(uint256 start, uint256 count);

    /// @notice Escrow funded and now open.
    event EscrowOpened(
        uint256 indexed id, address indexed buyer, address indexed seller, uint256 amount, uint64 deadline
    );
    /// @notice The buyer released the full amount to the seller before settlement was forced.
    event EscrowReleased(uint256 indexed id, address indexed buyer, address indexed seller, uint256 amount);
    /// @notice The seller claimed the full amount after the deadline passed unanswered.
    event EscrowClaimed(uint256 indexed id, address indexed buyer, address indexed seller, uint256 amount);
    /// @notice The buyer disputed before the deadline; the escrow was split between both parties.
    event EscrowDisputed(
        uint256 indexed id, address indexed buyer, address indexed seller, uint256 buyerAmount, uint256 sellerAmount
    );

    /// @notice The one token this escrow ever touches. Fixed at deployment.
    IERC20 public immutable token;

    /// @notice Number of escrows ever opened. Ids are `0 .. escrowCount() - 1`.
    uint256 public escrowCount;

    mapping(uint256 id => Escrow) private _escrows;

    /// @param token_ The ERC-20 held in escrow. On the Handshake launch this is SHAKE.
    constructor(address token_) {
        if (token_ == address(0)) revert ZeroToken();
        token = IERC20(token_);
    }

    /// @notice Escrow `amount` of the token for `seller` until `deadline`.
    /// @dev Pulls `amount` from the caller, who must have approved this contract first. The escrow
    ///      is recorded only after the pull succeeds, so a token that calls back during the transfer
    ///      finds no escrow to act on — the reason the id, the storage write and the event all come
    ///      after the transfer here, unlike everywhere else in this contract. A fee-on-transfer
    ///      token would make the recorded amount larger
    ///      than what arrived; SHAKE takes no fee, and pairing this contract with a fee-on-transfer
    ///      token is out of scope.
    /// @param seller The counterparty. Must not be the zero address or the caller.
    /// @param amount Minor units to escrow. Must be non-zero.
    /// @param deadline Unix seconds, strictly in the future.
    /// @return id The new escrow's id.
    function open(address seller, uint256 amount, uint64 deadline) external returns (uint256 id) {
        if (seller == address(0) || seller == msg.sender) revert InvalidSeller();
        if (amount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert DeadlineNotInFuture(deadline, block.timestamp);

        _pull(msg.sender, amount);

        id = escrowCount;
        escrowCount = id + 1;
        _escrows[id] =
            Escrow({buyer: msg.sender, deadline: deadline, status: Status.Open, seller: seller, amount: amount});

        emit EscrowOpened(id, msg.sender, seller, amount, deadline);
    }

    /// @notice Buyer pays the seller in full. Allowed at any time while the escrow is open,
    ///         including after the deadline as long as the seller has not claimed yet.
    function release(uint256 id) external {
        Escrow storage escrow = _escrows[id];
        if (escrow.status != Status.Open) revert EscrowNotOpen(id);
        if (msg.sender != escrow.buyer) revert NotBuyer(id, msg.sender);

        (address seller, uint256 amount) = (escrow.seller, escrow.amount);
        escrow.status = Status.Released;

        emit EscrowReleased(id, msg.sender, seller, amount);
        _push(seller, amount);
    }

    /// @notice Buyer disputes, splitting the escrow evenly. Allowed strictly before the deadline.
    /// @dev Only the buyer may dispute: the rule this implements is "if the buyer neither releases
    ///      nor disputes by the deadline the seller claims", so the dispute is the buyer's half of
    ///      that choice. A seller who wants less than the full amount has no on-chain lever here and
    ///      must settle off-chain.
    ///      With an odd amount the extra minor unit goes to the seller, so the party that chose to
    ///      dispute never rounds in its own favour.
    function dispute(uint256 id) external {
        Escrow storage escrow = _escrows[id];
        if (escrow.status != Status.Open) revert EscrowNotOpen(id);
        if (msg.sender != escrow.buyer) revert NotBuyer(id, msg.sender);
        uint64 deadline = escrow.deadline;
        if (block.timestamp >= deadline) revert DeadlinePassed(id, deadline);

        (address seller, uint256 amount) = (escrow.seller, escrow.amount);
        escrow.status = Status.Disputed;

        uint256 buyerAmount = amount / 2;
        uint256 sellerAmount = amount - buyerAmount;

        emit EscrowDisputed(id, msg.sender, seller, buyerAmount, sellerAmount);
        _push(msg.sender, buyerAmount);
        _push(seller, sellerAmount);
    }

    /// @notice Seller takes the full amount once the deadline has passed unanswered.
    /// @dev Allowed at `block.timestamp >= deadline`, the exact complement of {dispute}: at the
    ///      deadline second itself the buyer's window is over and the seller's has begun.
    function claim(uint256 id) external {
        Escrow storage escrow = _escrows[id];
        if (escrow.status != Status.Open) revert EscrowNotOpen(id);
        if (msg.sender != escrow.seller) revert NotSeller(id, msg.sender);
        uint64 deadline = escrow.deadline;
        if (block.timestamp < deadline) revert DeadlineNotReached(id, deadline);

        (address buyer, uint256 amount) = (escrow.buyer, escrow.amount);
        escrow.status = Status.Claimed;

        emit EscrowClaimed(id, buyer, msg.sender, amount);
        _push(msg.sender, amount);
    }

    /// @notice Read a single escrow. An unknown id reads back as an all-zero escrow with
    ///         `status == Status.None`.
    function getEscrow(uint256 id) external view returns (Escrow memory) {
        return _escrows[id];
    }

    /// @notice Read `count` escrows starting at `start`, so a front end can list escrows without
    ///         an indexer or a log query.
    function getEscrows(uint256 start, uint256 count) external view returns (Escrow[] memory page) {
        uint256 total = escrowCount;
        if (count > total || start > total - count) revert InvalidRange(start, count);
        page = new Escrow[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _escrows[start + i];
        }
    }

    /// @dev Accepts both a `true` return and an empty return, and rejects everything else, so a
    ///      failed transfer can never be mistaken for a settled escrow.
    function _pull(address from, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        _check(ok, data);
    }

    function _push(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        _check(ok, data);
    }

    /// @dev An empty return is only accepted from an address that actually has code, so a call to a
    ///      token that does not exist cannot be read as a silent success.
    function _check(bool ok, bytes memory data) private view {
        if (!ok) revert TokenTransferFailed();
        if (data.length == 0) {
            if (address(token).code.length == 0) revert TokenTransferFailed();
            return;
        }
        if (data.length < 32 || !abi.decode(data, (bool))) revert TokenTransferFailed();
    }
}
