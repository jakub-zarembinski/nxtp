// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./MintableToken.sol";
import "./interfaces/ITransactionManager.sol";
import "./lib/LibAsset.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract RouterY is Ownable {
  address public immutable routerFactory;

  MintableToken public token;

  ITransactionManager public transactionManager;

  uint256 private chainId;

  uint256 private tokenChainId;

  address public recipient;

  address public routerSigner;

  struct SignedPrepareData {
    ITransactionManager.PrepareArgs args;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  struct SignedFulfillData {
    ITransactionManager.FulfillArgs args;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  struct SignedCancelData {
    ITransactionManager.CancelArgs args;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  struct SignedRemoveLiquidityData {
    uint256 amount;
    address assetId;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  event RelayerFeeAdded(address assetId, uint256 amount, address caller);
  event RelayerFeeRemoved(address assetId, uint256 amount, address caller);
  event RemoveLiquidity(
    uint256 amount, 
    address assetId,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee, 
    address caller
  );
  event Prepare(
    ITransactionManager.InvariantTransactionData invariantData,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    address caller
  );
  event Fulfill(
    ITransactionManager.TransactionData txData,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    address caller
  );
  event Cancel(
    ITransactionManager.TransactionData txData,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    address caller
  );

  constructor(address _routerFactory) {
    routerFactory = _routerFactory;
  }

  // Prevents from calling methods other than routerFactory contract
  modifier onlyViaFactory() {
    require(msg.sender == routerFactory, "ONLY_VIA_FACTORY");
    _;
  }

  function init(
    address _transactionManager,
    uint256 _chainId,
    address _routerSigner,
    address _recipient,
    address _owner
  ) external onlyViaFactory {
    transactionManager = ITransactionManager(_transactionManager);
    chainId = _chainId;
    routerSigner = _routerSigner;
    recipient = _recipient;
    transferOwnership(_owner);
  }

  function initToken(
    string memory _name,
    string memory _symbol,
    uint256 _amount,
    uint256 _chainId
  ) external onlyOwner {
    require(address(token) == address(0x0), "TOKEN_ALREADY_INITIALIZED");
    token = new MintableToken(_name, _symbol, _amount);
    token.approve(address(transactionManager), _amount);
    transactionManager.addLiquidity(_amount, address(token));
    tokenChainId = _chainId;
  }

  function setRecipient(address _recipient) external onlyOwner {
    recipient = _recipient;
  }

  function setSigner(address _routerSigner) external onlyOwner {
    routerSigner = _routerSigner;
  }

  function addRelayerFee(uint256 amount, address assetId) external payable {
    // Sanity check: nonzero amounts
    require(amount > 0, "#RC_ARF:002");

    // Transfer funds to contract
    // Validate correct amounts are transferred
    if (LibAsset.isNativeAsset(assetId)) {
      require(msg.value == amount, "#RC_ARF:005");
    } else {
      require(msg.value == 0, "#RC_ARF:006");
      LibAsset.transferFromERC20(assetId, msg.sender, address(this), amount);
    }

    // Emit event
    emit RelayerFeeAdded(assetId, amount, msg.sender);
  }

  function removeRelayerFee(uint256 amount, address assetId) external onlyOwner {
    // Sanity check: nonzero amounts
    require(amount > 0, "#RC_RRF:002");

    // Transfer funds from contract
    LibAsset.transferAsset(assetId, payable(recipient), amount);

    // Emit event
    emit RelayerFeeRemoved(assetId, amount, msg.sender);
  }

  function removeLiquidity(
    uint256 amount,
    address assetId,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) external {
    if (msg.sender != routerSigner) {
      SignedRemoveLiquidityData memory payload = SignedRemoveLiquidityData({
        amount: amount,
        assetId: assetId,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_RL:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }

    emit RemoveLiquidity(amount, assetId, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    return transactionManager.removeLiquidity(amount, assetId, payable(recipient));
  }

  function prepare(
    ITransactionManager.PrepareArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) external payable returns (ITransactionManager.TransactionData memory) {
    if (msg.sender != routerSigner) {
      SignedPrepareData memory payload = SignedPrepareData({
        args: args,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_P:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }

    emit Prepare(args.invariantData, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    ITransactionManager.TransactionData memory txData = transactionManager.prepare(args);
    if (args.invariantData.sendingChainId == tokenChainId && args.invariantData.receivingAssetId == address(token)) {
      token.mint(args.amount);
      token.approve(address(transactionManager), args.amount);
      transactionManager.addLiquidity(args.amount, address(token));
    }
    return txData;
  }

  function fulfill(
    ITransactionManager.FulfillArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) external returns (ITransactionManager.TransactionData memory) {
    if (msg.sender != routerSigner) {
      SignedFulfillData memory payload = SignedFulfillData({
        args: args,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_F:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }
    emit Fulfill(args.txData, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    ITransactionManager.TransactionData memory txData = transactionManager.fulfill(args);
    if (args.txData.receivingChainId == tokenChainId && args.txData.sendingAssetId == address(token)) {
      transactionManager.removeLiquidity(args.txData.amount, address(token), payable(this));
      token.burn(args.txData.amount);
    }
    return txData;
  }

  function cancel(
    ITransactionManager.CancelArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) external returns (ITransactionManager.TransactionData memory) {
    if (msg.sender != routerSigner) {
      SignedCancelData memory payload = SignedCancelData({
        args: args,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_C:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }
    emit Cancel(args.txData, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    ITransactionManager.TransactionData memory txData = transactionManager.cancel(args);
    if (args.txData.sendingChainId == tokenChainId && args.txData.receivingAssetId == address(token)) {
      transactionManager.removeLiquidity(args.txData.amount, address(token), payable(this));
      token.burn(args.txData.amount);
    }
    return txData;
  }

  /**
   * @notice Holds the logic to recover the routerSigner from an encoded payload.
   *         Will hash and convert to an eth signed message.
   * @param encodedPayload The payload that was signed
   * @param signature The signature you are recovering the routerSigner from
   */
  function recoverSignature(bytes memory encodedPayload, bytes calldata signature) internal pure returns (address) {
    // Recover
    return ECDSA.recover(ECDSA.toEthSignedMessageHash(keccak256(encodedPayload)), signature);
  }

  receive() external payable {}
}
