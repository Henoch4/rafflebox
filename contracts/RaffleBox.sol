// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title RaffleBox — fair on-chain raffles without VRF.
/// Organizer escrows a prize; players buy one ticket each. Winner is drawn
/// from a FUTURE blockhash committed at creation (unpredictable at buy time).
/// If the draw window is missed (>256 blocks), players reclaim. No tickets →
/// organizer cancels. 5% fee on the pot.
contract RaffleBox is ReentrancyGuard, Ownable {
    struct Raffle {
        address organizer;
        uint256 prize;
        uint256 ticketPrice;
        uint256 maxTickets;
        uint64 closeBlock;
        uint64 settleBlock;
        address[] players;
        bool drawn;
        bool expired;
        address winner;
    }

    uint256 public constant FEE_BPS = 500; // 5%
    address public treasury;
    Raffle[] private _raffles;
    mapping(uint256 => mapping(address => bool)) public hasTicket;

    event Created(uint256 indexed id, address indexed organizer, uint256 prize, uint256 ticketPrice, uint256 maxTickets);
    event Entered(uint256 indexed id, address indexed player, uint256 count);
    event Drawn(uint256 indexed id, address indexed winner, uint256 payout, uint256 fee);
    event Expired(uint256 indexed id);
    event Reclaimed(uint256 indexed id, address indexed player, uint256 amount);
    event Cancelled(uint256 indexed id);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    constructor() Ownable(msg.sender) {
        treasury = msg.sender;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Zero treasury");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function create(uint256 ticketPrice, uint256 maxTickets, uint64 saleBlocks, uint64 settleDelay) external payable nonReentrant returns (uint256) {
        require(ticketPrice > 0, "Bad price");
        require(maxTickets > 1, "Bad max");
        require(saleBlocks > 0 && settleDelay > 0 && settleDelay <= 200, "Bad window");
        _raffles.push();
        Raffle storage r = _raffles[_raffles.length - 1];
        r.organizer = msg.sender;
        r.prize = msg.value;
        r.ticketPrice = ticketPrice;
        r.maxTickets = maxTickets;
        r.closeBlock = uint64(block.number) + saleBlocks;
        r.settleBlock = uint64(block.number) + saleBlocks + settleDelay;
        uint256 id = _raffles.length - 1;
        emit Created(id, msg.sender, msg.value, ticketPrice, maxTickets);
        return id;
    }

    function buy(uint256 id) external payable nonReentrant {
        Raffle storage r = _raffles[id];
        require(!r.drawn && !r.expired, "Over");
        require(block.number < r.closeBlock, "Sales closed");
        require(r.players.length < r.maxTickets, "Sold out");
        require(!hasTicket[id][msg.sender], "One ticket each");
        require(msg.value == r.ticketPrice, "Exact price");
        hasTicket[id][msg.sender] = true;
        r.players.push(msg.sender);
        emit Entered(id, msg.sender, r.players.length);
    }

    function potOf(uint256 id) public view returns (uint256) {
        Raffle storage r = _raffles[id];
        return r.prize + r.ticketPrice * r.players.length;
    }

    function draw(uint256 id) external nonReentrant {
        Raffle storage r = _raffles[id];
        require(!r.drawn && !r.expired, "Over");
        require(r.players.length > 0, "No players");
        require(block.number >= r.settleBlock, "Too early");
        bytes32 h = blockhash(r.settleBlock);
        if (h == bytes32(0)) {
            r.expired = true;
            emit Expired(id);
            return;
        }
        r.drawn = true;
        uint256 idx = uint256(h) % r.players.length;
        address winner = r.players[idx];
        r.winner = winner;
        uint256 pot = potOf(id);
        uint256 fee = (pot * FEE_BPS) / 10000;
        uint256 payout = pot - fee;
        if (fee > 0) {
            (bool okF, ) = treasury.call{value: fee}("");
            require(okF, "Fee pay failed");
        }
        (bool ok, ) = winner.call{value: payout}("");
        require(ok, "Pay failed");
        emit Drawn(id, winner, payout, fee);
    }

    function reclaim(uint256 id) external nonReentrant {
        Raffle storage r = _raffles[id];
        require(r.expired && !r.drawn, "Not expired");
        require(hasTicket[id][msg.sender], "No ticket");
        hasTicket[id][msg.sender] = false;
        (bool ok, ) = msg.sender.call{value: r.ticketPrice}("");
        require(ok, "Pay failed");
        emit Reclaimed(id, msg.sender, r.ticketPrice);
    }

    function cancel(uint256 id) external nonReentrant {
        Raffle storage r = _raffles[id];
        require(msg.sender == r.organizer, "Not organizer");
        require(!r.drawn && !r.expired, "Over");
        require(r.players.length == 0, "Has players");
        r.expired = true;
        if (r.prize > 0) {
            (bool ok, ) = r.organizer.call{value: r.prize}("");
            require(ok, "Pay failed");
        }
        emit Cancelled(id);
    }

    function totalRaffles() external view returns (uint256) {
        return _raffles.length;
    }

    function getRaffle(uint256 id)
        external
        view
        returns (address organizer, uint256 prize, uint256 ticketPrice, uint256 maxTickets, uint64 closeBlock, uint64 settleBlock, uint256 players, bool drawn, bool expired, address winner)
    {
        Raffle storage r = _raffles[id];
        return (r.organizer, r.prize, r.ticketPrice, r.maxTickets, r.closeBlock, r.settleBlock, r.players.length, r.drawn, r.expired, r.winner);
    }

    function playerAt(uint256 id, uint256 i) external view returns (address) {
        return _raffles[id].players[i];
    }
}
