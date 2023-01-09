// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IGovernor} from "openzeppelin-contracts/governance/IGovernor.sol";
import {GitcoinGovernor, ICompoundTimelock} from "src/GitcoinGovernor.sol";
import {DeployInput, DeployScript} from "script/Deploy.s.sol";
import {IGovernorAlpha} from "src/interfaces/IGovernorAlpha.sol";
import {IGTC} from "src/interfaces/IGTC.sol";
import {ProposeScript} from "script/Propose.s.sol";

contract GitcoinGovernorTestHelper is Test, DeployInput {
  uint256 constant QUORUM = 2_500_000e18;
  address constant GTC_TOKEN = 0xDe30da39c46104798bB5aA3fe8B9e0e1F348163F;
  address constant TIMELOCK = 0x57a8865cfB1eCEf7253c27da6B4BC3dAEE5Be518;
  address constant PROPOSER = 0xc2E2B715d9e302947Ec7e312fd2384b5a1296099; // kbw.eth

  GitcoinGovernor governor;

  function setUp() public virtual {
    uint256 _forkBlock = 15_980_096; // The latest block when this test was written
    vm.createSelectFork(vm.rpcUrl("mainnet"), _forkBlock);

    DeployScript _deployScript = new DeployScript();
    _deployScript.setUp();
    governor = _deployScript.run();
  }
}

contract GitcoinGovernorDeployTest is GitcoinGovernorTestHelper {
  function testFuzz_deployment(uint256 _blockNumber) public {
    assertEq(governor.name(), "GTC Governor Bravo");
    assertEq(address(governor.token()), GTC_TOKEN);
    assertEq(governor.votingDelay(), INITIAL_VOTING_DELAY);
    assertEq(governor.votingPeriod(), INITIAL_VOTING_PERIOD);
    assertEq(governor.proposalThreshold(), INITIAL_PROPOSAL_THRESHOLD);
    assertEq(governor.quorum(_blockNumber), QUORUM);
    assertEq(governor.timelock(), TIMELOCK);
    assertEq(governor.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
  }
}

contract GitcoinGovernorProposalTestHelper is GitcoinGovernorTestHelper {
  //----------------- State and Setup ----------- //

  IGovernorAlpha governorAlpha = IGovernorAlpha(0xDbD27635A534A3d3169Ef0498beB56Fb9c937489);
  IGTC gtcToken = IGTC(GTC_TOKEN);
  ICompoundTimelock timelock = ICompoundTimelock(payable(TIMELOCK));
  uint256 initialProposalCount;
  uint256 upgradeProposalId;
  address[] delegates = [
    PROPOSER, // kbw.eth (~1.8M)
    0x2df9a188fBE231B0DC36D14AcEb65dEFbB049479, // janineleger.eth (~1.53M)
    0x4Be88f63f919324210ea3A2cCAD4ff0734425F91, // kevinolsen.eth (~1.35M)
    0x34aA3F359A9D614239015126635CE7732c18fDF3, // Austin Griffith (~1.05M)
    0x7E052Ef7B4bB7E5A45F331128AFadB1E589deaF1, // Kris Is (~1.05M)
    0x5e349eca2dc61aBCd9dD99Ce94d04136151a09Ee // Linda Xie (~1.02M)
  ];

  // As defined in the GovernorAlpha ProposalState Enum
  uint8 constant PENDING = 0;
  uint8 constant ACTIVE = 1;
  uint8 constant DEFEATED = 3;
  uint8 constant SUCCEEDED = 4;
  uint8 constant QUEUED = 5;
  uint8 constant EXECUTED = 7;

  function setUp() public virtual override {
    GitcoinGovernorTestHelper.setUp();

    initialProposalCount = governorAlpha.proposalCount();

    ProposeScript _proposeScript = new ProposeScript();
    upgradeProposalId = _proposeScript.run(governor);
  }

  //--------------- HELPERS ---------------//

  function upgradeProposalStartBlock() public view returns (uint256) {
    (,,, uint256 _startBlock,,,,,) = governorAlpha.proposals(upgradeProposalId);
    return _startBlock;
  }

  function upgradeProposalEndBlock() public view returns (uint256) {
    (,,,, uint256 _endBlock,,,,) = governorAlpha.proposals(upgradeProposalId);
    return _endBlock;
  }

  function upgradeProposalEta() public view returns (uint256) {
    (,, uint256 _eta,,,,,,) = governorAlpha.proposals(upgradeProposalId);
    return _eta;
  }

  function jumpToActiveUpgradeProposal() public {
    vm.roll(upgradeProposalStartBlock() + 1);
  }

  function jumpToUpgradeVoteComplete() public {
    vm.roll(upgradeProposalEndBlock() + 1);
  }

  function jumpPastProposalEta() public {
    vm.roll(block.number + 1); // move up one block so we're not in the same block as when queued
    vm.warp(upgradeProposalEta() + 1); // jump past the eta timestamp
  }

  function delegatesVoteOnUpgradeProposal(bool _support) public {
    for (uint256 _index = 0; _index < delegates.length; _index++) {
      vm.prank(delegates[_index]);
      governorAlpha.castVote(upgradeProposalId, _support);
    }
  }

  function passUpgradeProposal() public {
    jumpToActiveUpgradeProposal();
    delegatesVoteOnUpgradeProposal(true);
    jumpToUpgradeVoteComplete();
  }

  function defeatUpgradeProposal() public {
    jumpToActiveUpgradeProposal();
    delegatesVoteOnUpgradeProposal(false);
    jumpToUpgradeVoteComplete();
  }

  function passAndQueueUpgradeProposal() public {
    passUpgradeProposal();
    governorAlpha.queue(upgradeProposalId);
  }

  function passQueueAndExecuteUpgradeProposal() public {
    passAndQueueUpgradeProposal();
    jumpPastProposalEta();
    governorAlpha.execute(upgradeProposalId);
  }
}

contract GitcoinGovernorProposalTest is GitcoinGovernorProposalTestHelper {
  function test_Proposal() public {
    // Proposal has been recorded
    assertEq(governorAlpha.proposalCount(), initialProposalCount + 1);

    // Proposal is in the expected state
    uint8 _state = governorAlpha.state(upgradeProposalId);
    assertEq(_state, PENDING);

    // Proposal actions correspond to Governor upgrade
    (
      address[] memory _targets,
      uint256[] memory _values,
      string[] memory _signatures,
      bytes[] memory _calldatas
    ) = governorAlpha.getActions(upgradeProposalId);
    assertEq(_targets.length, 2);
    assertEq(_targets[0], TIMELOCK);
    assertEq(_targets[1], address(governor));
    assertEq(_values.length, 2);
    assertEq(_values[0], 0);
    assertEq(_values[1], 0);
    assertEq(_signatures.length, 2);
    assertEq(_signatures[0], "setPendingAdmin(address)");
    assertEq(_signatures[1], "__acceptAdmin()");
    assertEq(_calldatas.length, 2);
    assertEq(_calldatas[0], abi.encode(address(governor)));
    assertEq(_calldatas[1], "");
  }

  function test_proposalActiveAfterDelay() public {
    jumpToActiveUpgradeProposal();

    // Ensure proposal has become active the block after the voting delay
    uint8 _state = governorAlpha.state(upgradeProposalId);
    assertEq(_state, ACTIVE);
  }

  function testFuzz_ProposerCanCastVote(bool _willSupport) public {
    jumpToActiveUpgradeProposal();
    uint256 _proposerVotes = gtcToken.getPriorVotes(PROPOSER, upgradeProposalStartBlock());

    vm.prank(PROPOSER);
    governorAlpha.castVote(upgradeProposalId, _willSupport);

    IGovernorAlpha.Receipt memory _receipt = governorAlpha.getReceipt(upgradeProposalId, PROPOSER);
    assertEq(_receipt.hasVoted, true);
    assertEq(_receipt.support, _willSupport);
    assertEq(_receipt.votes, _proposerVotes);
  }

  function test_ProposalSucceedsWhenAllDelegatesVoteFor() public {
    passUpgradeProposal();

    // Ensure proposal state is now succeeded
    uint8 _state = governorAlpha.state(upgradeProposalId);
    assertEq(_state, SUCCEEDED);
  }

  function test_ProposalDefeatedWhenAllDelegatesVoteAgainst() public {
    defeatUpgradeProposal();

    // Ensure proposal state is now defeated
    uint8 _state = governorAlpha.state(upgradeProposalId);
    assertEq(_state, DEFEATED);
  }

  function test_ProposalCanBeQueuedAfterSucceeding() public {
    passUpgradeProposal();
    governorAlpha.queue(upgradeProposalId);

    // Ensure proposal can be queued after success
    uint8 _state = governorAlpha.state(upgradeProposalId);
    assertEq(_state, QUEUED);

    (
      address[] memory _targets,
      uint256[] memory _values,
      string[] memory _signatures,
      bytes[] memory _calldatas
    ) = governorAlpha.getActions(upgradeProposalId);

    uint256 _eta = block.timestamp + timelock.delay();

    for (uint256 _index = 0; _index < _targets.length; _index++) {
      // Calculate hash of transaction in Timelock
      bytes32 _txHash = keccak256(
        abi.encode(_targets[_index], _values[_index], _signatures[_index], _calldatas[_index], _eta)
      );

      // Ensure transaction is queued in Timelock
      bool _isQueued = timelock.queuedTransactions(_txHash);
      assertEq(_isQueued, true);
    }
  }

  function test_ProposalCanBeExecutedAfterDelay() public {
    passAndQueueUpgradeProposal();
    jumpPastProposalEta();

    // Execute the proposal
    governorAlpha.execute(upgradeProposalId);

    // Ensure the proposal is now executed
    uint8 _state = governorAlpha.state(upgradeProposalId);
    assertEq(_state, EXECUTED);

    // Ensure the governor is now the admin of the timelock
    assertEq(timelock.admin(), address(governor));
  }
}

contract GitcoinGovernorAlphaPostProposalTest is GitcoinGovernorProposalTestHelper {
  address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address constant RAD_ADDRESS = 0x31c8EAcBFFdD875c74b94b077895Bd78CF1E64A3;

  IERC20 usdcToken = IERC20(USDC_ADDRESS);
  IERC20 radToken = IERC20(RAD_ADDRESS);

  function setUp() public override {
    GitcoinGovernorProposalTestHelper.setUp();
    usdcToken = IERC20(USDC_ADDRESS);
    radToken = IERC20(RAD_ADDRESS);
  }

  function testFuzz_OldGovernorSendsGTCAfterProposalIsDefeated(
    uint256 _gtcAmount,
    address _gtcReceiver
  ) public {
    vm.assume(_gtcReceiver != TIMELOCK && _gtcReceiver != address(0x0));
    uint256 _timelockGtcBalance = gtcToken.balanceOf(TIMELOCK);
    // bound by the number of tokens the timelock currently controls
    _gtcAmount = bound(_gtcAmount, 0, _timelockGtcBalance);
    uint256 _initialGtcBalance = gtcToken.balanceOf(_gtcReceiver);

    // Defeat the proposal to upgrade the Governor
    defeatUpgradeProposal();

    // Craft a new proposal to send GTC
    address[] memory _targets = new address[](1);
    uint256[] memory _values = new uint256[](1);
    string[] memory _signatures = new string [](1);
    bytes[] memory _calldatas = new bytes[](1);

    _targets[0] = GTC_TOKEN;
    _values[0] = 0;
    _signatures[0] = "transfer(address,uint256)";
    _calldatas[0] = abi.encode(_gtcReceiver, _gtcAmount);

    // Submit the new proposal
    vm.prank(PROPOSER);
    uint256 _newProposalId = governorAlpha.propose(
      _targets, _values, _signatures, _calldatas, "Transfer some GTC from the old Governor"
    );

    // Pass and execute the new proposal
    (,,, uint256 _startBlock, uint256 _endBlock,,,,) = governorAlpha.proposals(_newProposalId);
    vm.roll(_startBlock + 1);
    for (uint256 _index = 0; _index < delegates.length; _index++) {
      vm.prank(delegates[_index]);
      governorAlpha.castVote(_newProposalId, true);
    }
    vm.roll(_endBlock + 1);
    governorAlpha.queue(_newProposalId);
    vm.roll(block.number + 1);
    (,, uint256 _eta,,,,,,) = governorAlpha.proposals(_newProposalId);
    vm.warp(_eta + 1);
    governorAlpha.execute(_newProposalId);

    // Ensure the new proposal is now executed
    uint8 _state = governorAlpha.state(_newProposalId);
    assertEq(_state, EXECUTED);

    // Ensure the tokens have been transferred from the timelock to the receiver
    assertEq(gtcToken.balanceOf(TIMELOCK), _timelockGtcBalance - _gtcAmount);
    assertEq(gtcToken.balanceOf(_gtcReceiver), _initialGtcBalance + _gtcAmount);
  }

  function testFuzz_OldGovernorSendsVariousTokensAfterProposalIsDefeated(
    uint256 _usdcAmount,
    address _usdcReceiver,
    uint256 _radAmount,
    address _radReceiver
  ) public {
    vm.assume(
      _usdcReceiver != TIMELOCK && _usdcReceiver != address(0x0) && _radReceiver != TIMELOCK
        && _radReceiver != address(0x0)
    );

    uint256 _timelockUsdcBalance = usdcToken.balanceOf(TIMELOCK);
    uint256 _timelockRadBalance = radToken.balanceOf(TIMELOCK);

    // bound by the number of tokens the timelock currently controls
    _usdcAmount = bound(_usdcAmount, 0, _timelockUsdcBalance);
    _radAmount = bound(_radAmount, 0, _timelockRadBalance);

    // record receivers initial balances
    uint256 _initialUsdcBalance = usdcToken.balanceOf(_usdcReceiver);
    uint256 _initialRadBalance = radToken.balanceOf(_radReceiver);

    // Defeat the proposal to upgrade the Governor
    defeatUpgradeProposal();

    // Craft a new proposal to send amounts of all three tokens
    address[] memory _targets = new address[](2);
    uint256[] memory _values = new uint256[](2);
    string[] memory _signatures = new string [](2);
    bytes[] memory _calldatas = new bytes[](2);

    _targets[0] = USDC_ADDRESS;
    _values[0] = 0;
    _signatures[0] = "transfer(address,uint256)";
    _calldatas[0] = abi.encode(_usdcReceiver, _usdcAmount);

    _targets[1] = RAD_ADDRESS;
    _values[1] = 0;
    _signatures[1] = "transfer(address,uint256)";
    _calldatas[1] = abi.encode(_radReceiver, _radAmount);

    // Submit the new proposal
    vm.prank(PROPOSER);
    uint256 _newProposalId = governorAlpha.propose(
      _targets, _values, _signatures, _calldatas, "Transfer some tokens from the old Governor"
    );

    // Pass and execute the new proposal
    {
      // separate scope to avoid stack to deep
      (,,, uint256 _startBlock, uint256 _endBlock,,,,) = governorAlpha.proposals(_newProposalId);
      vm.roll(_startBlock + 1);
      for (uint256 _index = 0; _index < delegates.length; _index++) {
        vm.prank(delegates[_index]);
        governorAlpha.castVote(_newProposalId, true);
      }
      vm.roll(_endBlock + 1);
      governorAlpha.queue(_newProposalId);
      vm.roll(block.number + 1);
      (,, uint256 _eta,,,,,,) = governorAlpha.proposals(_newProposalId);
      vm.warp(_eta + 1);
      governorAlpha.execute(_newProposalId);

      // Ensure the new proposal is now executed
      uint8 _state = governorAlpha.state(_newProposalId);
      assertEq(_state, EXECUTED);
    }

    // Ensure token balances have all been updated
    assertEq(usdcToken.balanceOf(TIMELOCK), _timelockUsdcBalance - _usdcAmount);
    assertEq(usdcToken.balanceOf(_usdcReceiver), _initialUsdcBalance + _usdcAmount);
    assertEq(radToken.balanceOf(TIMELOCK), _timelockRadBalance - _radAmount);
    assertEq(radToken.balanceOf(_radReceiver), _initialRadBalance + _radAmount);
  }

  function testFuzz_OldGovernorCanNotSendGTCAfterUpgradeCompletes(
    uint256 _gtcAmount,
    address _gtcReceiver
  ) public {
    vm.assume(_gtcReceiver != TIMELOCK && _gtcReceiver != address(0x0));
    uint256 _timelockGtcBalance = gtcToken.balanceOf(TIMELOCK);
    // bound by the number of tokens the timelock currently controls
    _gtcAmount = bound(_gtcAmount, 0, _timelockGtcBalance);

    // Pass and execute the proposal to upgrade the Governor
    passQueueAndExecuteUpgradeProposal();

    // Craft a new proposal to send GTC
    address[] memory _targets = new address[](1);
    uint256[] memory _values = new uint256[](1);
    string[] memory _signatures = new string [](1);
    bytes[] memory _calldatas = new bytes[](1);

    _targets[0] = GTC_TOKEN;
    _values[0] = 0;
    _signatures[0] = "transfer(address,uint256)";
    _calldatas[0] = abi.encode(_gtcReceiver, _gtcAmount);

    // Submit the new proposal to Governor ALPHA, which is now deprecated
    vm.prank(PROPOSER);
    uint256 _newProposalId = governorAlpha.propose(
      _targets, _values, _signatures, _calldatas, "Transfer some GTC from the old Governor"
    );

    // Pass the new proposal
    (,,, uint256 _startBlock, uint256 _endBlock,,,,) = governorAlpha.proposals(_newProposalId);
    vm.roll(_startBlock + 1);
    for (uint256 _index = 0; _index < delegates.length; _index++) {
      vm.prank(delegates[_index]);
      governorAlpha.castVote(_newProposalId, true);
    }
    vm.roll(_endBlock + 1);

    // Attempt to queue the new proposal, which should now fail
    vm.expectRevert("Timelock::queueTransaction: Call must come from admin.");
    governorAlpha.queue(_newProposalId);
  }
}

contract NewGitcoinGovernorProposalTest is GitcoinGovernorProposalTestHelper {
  // From GovernorCountingSimple
  uint8 constant AGAINST = 0;
  uint8 constant FOR = 1;
  uint8 constant ABSTAIN = 2;

  function assumeReceiver(address _receiver) public {
    vm.assume(_receiver != TIMELOCK && _receiver != address(0x0));
  }

  function buildProposalData(string memory _signature, bytes memory _calldata)
    public
    pure
    returns (bytes memory)
  {
    return abi.encodePacked(bytes4(keccak256(bytes(_signature))), _calldata);
  }

  function jumpToActiveProposal(uint256 _proposalId) public {
    uint256 _snapshot = governor.proposalSnapshot(_proposalId);
    vm.roll(_snapshot + 1);
  }

  function jumpToVotingComplete(uint256 _proposalId) public {
    // Jump one block past the proposal voting deadline
    uint256 _deadline = governor.proposalDeadline(_proposalId);
    vm.roll(_deadline + 1);
  }

  function jumpPastProposalEta(uint256 _proposalId) public {
    uint256 _eta = governor.proposalEta(_proposalId);
    vm.roll(block.number + 1);
    vm.warp(_eta + 1);
  }

  function delegatesVoteOnProposal(uint256 _proposalId, uint8 _support) public {
    assertLt(_support, 3, "Invalid value for support");

    for (uint256 _index = 0; _index < delegates.length; _index++) {
      vm.prank(delegates[_index]);
      governor.castVote(_proposalId, _support);
    }
  }

  function submitGtcSendProposal(uint256 _gtcAmount, address _gtcReceiver)
    public
    returns (uint256, address[] memory, uint256[] memory, bytes[] memory, string memory)
  {
    // Craft a new proposal to send GTC
    address[] memory _targets = new address[](1);
    uint256[] memory _values = new uint256[](1);
    bytes[] memory _calldatas = new bytes[](1);

    _targets[0] = GTC_TOKEN;
    _values[0] = 0;
    _calldatas[0] =
      buildProposalData("transfer(address,uint256)", abi.encode(_gtcReceiver, _gtcAmount));
    string memory _description = "Transfer some GTC from the old Governor";

    // Submit the new proposal
    vm.prank(PROPOSER);
    uint256 _newProposalId = governor.propose(_targets, _values, _calldatas, _description);

    return (_newProposalId, _targets, _values, _calldatas, _description);
  }

  function assertEq(IGovernor.ProposalState _actual, IGovernor.ProposalState _expected) public {
    assertEq(uint8(_actual), uint8(_expected));
  }

  function setUp() public override {
    GitcoinGovernorProposalTestHelper.setUp();
  }

  function testFuzz_NewGovernorCanReceiveNewProposal(uint256 _gtcAmount, address _gtcReceiver)
    public
  {
    assumeReceiver(_gtcReceiver);
    passQueueAndExecuteUpgradeProposal();
    (uint256 _newProposalId,,,,) = submitGtcSendProposal(_gtcAmount, _gtcReceiver);

    // Ensure proposal is in the expected state
    IGovernor.ProposalState _state = governor.state(_newProposalId);
    assertEq(_state, IGovernor.ProposalState.Pending);
  }

  function testFuzz_NewGovernorCanPassProposalAndSendGtc(uint256 _gtcAmount, address _gtcReceiver)
    public
  {
    assumeReceiver(_gtcReceiver);
    uint256 _timelockGtcBalance = gtcToken.balanceOf(TIMELOCK);

    // bound by the number of tokens the timelock currently controls
    _gtcAmount = bound(_gtcAmount, 0, _timelockGtcBalance);
    uint256 _initialGtcBalance = gtcToken.balanceOf(_gtcReceiver);

    passQueueAndExecuteUpgradeProposal();
    (
      uint256 _newProposalId,
      address[] memory _targets,
      uint256[] memory _values,
      bytes[] memory _calldatas,
      string memory _description
    ) = submitGtcSendProposal(_gtcAmount, _gtcReceiver);

    // Ensure proposal is in the expected state
    IGovernor.ProposalState _state = governor.state(_newProposalId);
    assertEq(_state, IGovernor.ProposalState.Pending);

    jumpToActiveProposal(_newProposalId);

    // Ensure the proposal is now Active
    _state = governor.state(_newProposalId);
    assertEq(_state, IGovernor.ProposalState.Active);

    delegatesVoteOnProposal(_newProposalId, FOR);
    jumpToVotingComplete(_newProposalId);

    // Ensure the proposal has succeeded
    _state = governor.state(_newProposalId);
    assertEq(_state, IGovernor.ProposalState.Succeeded);

    // Queue the proposal
    governor.queue(_targets, _values, _calldatas, keccak256(bytes(_description)));

    // Ensure the proposal is queued
    _state = governor.state(_newProposalId);
    assertEq(_state, IGovernor.ProposalState.Queued);

    jumpPastProposalEta(_newProposalId);

    // Execute the proposal
    governor.execute(_targets, _values, _calldatas, keccak256(bytes(_description)));

    // Ensure the proposal is executed
    _state = governor.state(_newProposalId);
    assertEq(_state, IGovernor.ProposalState.Executed);

    // Ensure the tokens have been transferred
    assertEq(gtcToken.balanceOf(_gtcReceiver), _initialGtcBalance + _gtcAmount);
    assertEq(gtcToken.balanceOf(TIMELOCK), _timelockGtcBalance - _gtcAmount);
  }
}
