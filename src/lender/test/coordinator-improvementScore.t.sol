// Copyright (C) 2020 Centrifuge

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.15 <0.6.0;
pragma experimental ABIEncoderV2;

import "./coordinator-base.t.sol";

contract CoordinatorImprovementScoreTest is CoordinatorTest, DataTypes {
    function setUp() public {
        super.setUp();

    }

    function testImprovement() public {
        LenderModel memory model = getDefaultModel();
        initTestConfig(model);
        hevm.warp(now + 1 days);
        coordinator.closeEpoch();

    }

    function testScoreImprovement() public {
        LenderModel memory model = getDefaultModel();
        initTestConfig(model);

        //  0.75 >= seniorRatio <= 0.85
        emit log_named_uint("maxSeniorRatio", model.maxSeniorRatio);
        emit log_named_uint("maxSeniorRatio", model.minSeniorRatio);

        Fixed27 memory newSeniorRatio = Fixed27(92 * 10**25);
        Fixed27 memory currentSeniorRatio = Fixed27(95 * 10**25);

        uint score = coordinator.scoreImprovement(newSeniorRatio, currentSeniorRatio, model.reserve);

        newSeniorRatio = Fixed27(83 * 10**25);
        uint betterScore = coordinator.scoreImprovement(newSeniorRatio, currentSeniorRatio, model.reserve);

        assertTrue(betterScore > score);

        newSeniorRatio = Fixed27(80 * 10**25);
        uint maxRatioScore = coordinator.scoreImprovement(newSeniorRatio, currentSeniorRatio, model.reserve);

        assertTrue(maxRatioScore >  betterScore);
    }
}

