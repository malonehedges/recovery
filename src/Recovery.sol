// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC721} from "solmate/tokens/ERC721.sol";

contract Recovery is ERC721 {
    event TokenURIUpdated(uint256 indexed tokenId, string indexed tokenURI);

    address immutable votingContract;

    address public immutable parentTokenContract;
    uint256 public immutable parentTokenId;

    uint256 currentTokenId;
    mapping(uint256 => string) public tokenURIs;

    modifier onlyVotingContract() {
        require(msg.sender == votingContract, "unauthorized");
        _;
    }

    constructor(
        address _parentTokenContract,
        uint256 _parentTokenId,
        string memory _tokenName
    ) ERC721(_tokenName, "RCVR") {
        votingContract = msg.sender;

        parentTokenContract = _parentTokenContract;
        parentTokenId = _parentTokenId;
    }

    function mint(address _recoverer, string memory _tokenURI)
        public
        onlyVotingContract
        returns (uint256)
    {
        uint256 tokenId = ++currentTokenId;
        tokenURIs[tokenId] = _tokenURI;
        _mint(_recoverer, tokenId);
        emit TokenURIUpdated(tokenId, _tokenURI);
        return tokenId;
    }

    function updateTokenURI(uint256 _tokenId, string memory _tokenURI)
        public
        onlyVotingContract
    {
        tokenURIs[_tokenId] = _tokenURI;
        emit TokenURIUpdated(_tokenId, _tokenURI);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(_ownerOf[tokenId] != address(0), "not minted");
        return tokenURIs[tokenId];
    }
}

import "solmate/auth/Owned.sol";

contract RecoveryVoting is Owned {
    address public immutable governanceContract;

    mapping(address => mapping(uint256 => address)) public recoverys;

    constructor(address _governanceContract) Owned(msg.sender) {
        governanceContract = _governanceContract;
    }

    // admin - deploying

    function deployRecovery(
        address _contract,
        uint256 _tokenId,
        string calldata _tokenName
    ) external onlyOwner returns (address) {
        require(
            recoverys[_contract][_tokenId] == address(0),
            "recovery already deployed"
        );

        Recovery recovery = new Recovery(_contract, _tokenId, _tokenName);
        recoverys[_contract][_tokenId] = address(recovery);
        return address(recovery);
    }

    // admin - config

    struct Config {
        uint256 proposalDuration;
        uint256 voteDuration;
        uint256 voteThreshold;
        uint256 tokenHolderVoteWeight;
    }

    Config public config;

    event ConfigUpdated(Config indexed config);

    function updateConfig(Config calldata _config) external onlyOwner {
        config = _config;
        emit ConfigUpdated(_config);
    }

    // proposals

    event RoundStarted(uint256 indexed round);

    uint256 currentRoundStartTime;
    uint256 currentRound;

    function startRound() external onlyOwner {
        require(currentRoundStartTime == 0, "round currently in progress");

        currentRoundStartTime = block.timestamp;
        emit RoundStarted(currentRound++);
    }

    struct Proposal {
        uint256 id;
        uint256 round;
        uint256 proposerTokenId;
        address tokenContract;
        uint256 tokenId;
        string tokenURI;
        uint256 voteCount;
        bool vetoed;
        bool passed;
        bool recovered;
    }

    mapping(uint256 => mapping(uint256 => bool)) tokenProposedThisRound;
    mapping(uint256 => Proposal) proposals;

    uint256 currentProposalId;

    event NewProposal(Proposal indexed proposal);

    function proposeRecovery(
        uint256 governanceTokenId,
        address tokenContract,
        uint256 tokenId,
        string calldata tokenURI
    ) external {
        require(
            ERC721(governanceContract).ownerOf(governanceTokenId) == msg.sender,
            "you don't own this token"
        );
        require(currentRoundStartTime != 0, "no round active");
        require(
            currentRoundStartTime + config.proposalDuration < block.timestamp,
            "proposal period has passed"
        );
        require(
            recoverys[tokenContract][tokenId] != address(0),
            "this recovery doesn't exist"
        );
        require(
            !tokenProposedThisRound[currentRound][governanceTokenId],
            "this token has already proposed this round"
        );

        tokenProposedThisRound[currentRound][governanceTokenId] = true;
        uint256 proposalId = ++currentProposalId;
        Proposal memory proposal = Proposal(
            proposalId,
            currentRound,
            governanceTokenId,
            tokenContract,
            tokenId,
            tokenURI,
            0,
            false,
            false,
            false
        );
        proposals[proposalId] = proposal;
        emit NewProposal(proposal);
    }

    event ProposalVote(
        uint256 indexed governanceTokenId,
        uint256 indexed proposalId
    );

    mapping(uint256 => mapping(uint256 => bool)) votes;

    modifier voteIsActive(uint256 proposalId) {
        require(currentRoundStartTime != 0, "no round active");
        require(proposals[proposalId].round == currentRound, "wrong round");
        require(
            block.timestamp > currentRoundStartTime + config.proposalDuration &&
                currentRoundStartTime +
                    config.proposalDuration +
                    config.voteDuration <
                block.timestamp,
            "you can't vote for this right now"
        );
        _;
    }

    function vote(uint256 governanceTokenId, uint256 proposalId)
        external
        voteIsActive(proposalId)
    {
        require(
            ERC721(governanceContract).ownerOf(governanceTokenId) == msg.sender,
            "you don't own this token"
        );
        require(!votes[proposalId][governanceTokenId], "token already voted");

        unchecked {
            ++proposals[proposalId].voteCount;
        }
        votes[proposalId][governanceTokenId] = true;
        emit ProposalVote(governanceTokenId, proposalId);

        _checkVotePassed(proposalId);
    }

    event TokenHolderProposalVote(uint256 indexed proposalId);

    mapping(uint256 => mapping(address => mapping(uint256 => bool))) tokenHolderVoted;

    function tokenHolderVote(uint256 proposalId)
        external
        voteIsActive(proposalId)
    {
        address tokenContract = proposals[proposalId].tokenContract;
        uint256 tokenId = proposals[proposalId].tokenId;

        require(
            ERC721(tokenContract).ownerOf(tokenId) == msg.sender,
            "you don't own the token"
        );
        require(
            !tokenHolderVoted[proposalId][tokenContract][tokenId],
            "token already voted"
        );

        tokenHolderVoted[proposalId][tokenContract][tokenId] = true;
        proposals[proposalId].voteCount += config.tokenHolderVoteWeight;
        emit TokenHolderProposalVote(proposalId);

        _checkVotePassed(proposalId);
    }

    event ProposalVetoed(uint256 indexed proposalId);

    function tokenHolderVeto(uint256 proposalId)
        external
        voteIsActive(proposalId)
    {
        address tokenContract = proposals[proposalId].tokenContract;
        uint256 tokenId = proposals[proposalId].tokenId;

        require(
            ERC721(tokenContract).ownerOf(tokenId) == msg.sender,
            "you don't own the token"
        );
        require(!proposals[proposalId].vetoed, "token already voted");

        proposals[proposalId].vetoed = true;
        proposals[proposalId].passed = false;
        emit ProposalVetoed(proposalId);
    }

    event VotePassed(uint256 indexed proposalId);

    function _checkVotePassed(uint256 proposalId) internal {
        if (
            proposals[proposalId].voteCount >= config.voteThreshold &&
            !proposals[proposalId].vetoed
        ) {
            proposals[proposalId].passed = true;
            emit VotePassed(proposalId);
        }
    }

    event RoundCompleted(uint256 indexed roundId);

    function endRound() external {
        require(currentRoundStartTime != 0, "no round active");
        require(
            currentRoundStartTime +
                config.proposalDuration +
                config.voteDuration >
                block.timestamp,
            "the round isn't over yet"
        );

        currentRoundStartTime = 0;
        emit RoundCompleted(currentRound);
    }

    // recovery

    event TokenRecovered(
        uint256 indexed proposalId,
        address indexed recoveryAddress,
        uint256 indexed tokenId
    );

    function recover(uint256 proposalId) external {
        Proposal memory proposal = proposals[proposalId];

        require(proposal.passed, "proposal didn't pass");
        require(
            currentRound > proposal.round ||
                currentRoundStartTime +
                    config.proposalDuration +
                    config.voteDuration >
                block.timestamp,
            "the round isn't over yet"
        );

        address tokenHolder = ERC721(governanceContract).ownerOf(
            proposal.proposerTokenId
        );
        address recoveryAddress = recoverys[proposal.tokenContract][
            proposal.tokenId
        ];
        uint256 mintedTokenId = Recovery(recoveryAddress).mint(
            tokenHolder,
            proposal.tokenURI
        );
        proposals[proposalId].recovered = true;
        emit TokenRecovered(proposalId, recoveryAddress, mintedTokenId);
    }
}
