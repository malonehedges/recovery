// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import "../src/Recovery.sol";

contract Token is ERC721 {
    constructor(string memory name, string memory symbol)
        ERC721(name, symbol)
    {}

    function mint(address holder, uint256 tokenId) public {
        _mint(holder, tokenId);
    }

    function tokenURI(uint256)
        public
        view
        virtual
        override
        returns (string memory)
    {
        revert("unimplemented");
    }
}

contract RecoveryTest is Test {
    RecoveryVoting rv;

    Token mainCollection;
    Token governanceCollection;

    function setUp() public {
        mainCollection = new Token("main", "MAIN");
        governanceCollection = new Token("governance", "GOV");

        rv = new RecoveryVoting(address(governanceCollection));
    }

    function testDeployRecovery() public {
        mainCollection.mint(address(1), 420);

        Recovery r1 = Recovery(
            rv.deployRecovery(address(mainCollection), 420, "420 token")
        );
        assertEq(rv.recoverys(address(mainCollection), 420), address(r1));

        vm.expectRevert("recovery already deployed");
        rv.deployRecovery(address(mainCollection), 420, "420 token again");

        vm.expectRevert("unauthorized");
        r1.mint(address(2), "ipfs://hash-here");

        Token anotherMainCollection = new Token("another one", "ANTHR");
        anotherMainCollection.mint(address(2), 420420);

        Recovery r2 = Recovery(
            rv.deployRecovery(
                address(anotherMainCollection),
                420420,
                "420420 token"
            )
        );
        assertEq(
            rv.recoverys(address(anotherMainCollection), 420420),
            address(r2)
        );
    }
}
